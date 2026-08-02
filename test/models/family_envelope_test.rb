require "test_helper"

class FamilyEnvelopeTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "envelope_mode? and cap_mode? reflect budget_mode" do
    assert @family.cap_mode?
    refute @family.envelope_mode?

    @family.activate_envelope_mode!

    assert @family.envelope_mode?
    refute @family.cap_mode?
  end

  test "activate_envelope_mode! stamps envelope_activated_on once, idempotent on re-activation" do
    travel_to Date.new(2026, 1, 1) do
      @family.activate_envelope_mode!
    end

    assert_equal Date.new(2026, 1, 1), @family.envelope_activated_on

    travel_to Date.new(2026, 3, 1) do
      @family.deactivate_envelope_mode!
      @family.activate_envelope_mode!
    end

    assert_equal Date.new(2026, 1, 1), @family.envelope_activated_on
  end

  test "deactivate_envelope_mode! preserves the activation date" do
    @family.activate_envelope_mode!
    activated_on = @family.envelope_activated_on

    @family.deactivate_envelope_mode!

    assert @family.cap_mode?
    assert_equal activated_on, @family.envelope_activated_on
  end

  test "unassigned_pool_balance is nil in cap mode" do
    assert @family.cap_mode?
    assert_nil @family.unassigned_pool_balance
  end

  test "envelope balance nets funded allocations against actual spend since activation" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Envelope Test #{Time.now.to_f}", family: @family, color: "#123456")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 300, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Envelope spend",
      amount: 120,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    assert_equal 180, @family.envelope_balances_by_category[category.id]
    assert_equal 300, @family.envelope_assigned_by_category[category.id]
  end

  test "envelope balance nets refunds against spend" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Envelope Refund #{Time.now.to_f}", family: @family, color: "#654321")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 200, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Purchase",
      amount: 100,
      currency: "USD"
    )

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Partial refund",
      amount: -40,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    # 200 funded - (100 spent - 40 refunded) = 140
    assert_equal 140, @family.envelope_balances_by_category[category.id]
  end

  test "envelope balance goes negative on overspend and is not clamped at zero" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Overspend #{Time.now.to_f}", family: @family, color: "#987654")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 50, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Overspend",
      amount: 80,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    assert_equal(-30, @family.envelope_balances_by_category[category.id])
  end

  test "overspending an envelope does not by itself change the pool; only reassigning funds does" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Overspend Pool #{Time.now.to_f}", family: @family, color: "#111222")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 50, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Overspend",
      amount: 80,
      currency: "USD"
    )

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount
    assert_equal(-30, @family.envelope_balances_by_category[category.id])

    # Move $30 from Unassigned into the category to cover the overspend
    @family.budget_allocations.create!(category: category, amount: 30, currency: "USD", date: Date.current, kind: "fund")
    @family.reset_envelope_caches!

    assert_equal 0, @family.envelope_balances_by_category[category.id]
    assert_equal unassigned_before - 30, @family.unassigned_pool_balance.amount
  end

  test "unassigned_pool_balance satisfies cash == unassigned + envelope balances + goal earmarks" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Identity Test #{Time.now.to_f}", family: @family, color: "#222333")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 300, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Spend",
      amount: 120,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    cash = @family.in_budget_accounts.where(currency: "USD").sum(:balance)
    reserved_in_envelopes = @family.envelope_balances_by_category.values.sum
    earmarked_for_goals = GoalAccount.joins(:goal)
      .where(account_id: @family.in_budget_accounts.select(:id))
      .where(goals: { family_id: @family.id })
      .where.not(goals: { state: "archived" })
      .sum(:allocated_amount)

    assert_equal cash - reserved_in_envelopes - earmarked_for_goals, @family.unassigned_pool_balance.amount
  end

  test "in_budget_accounts excludes accounts with in_budget false" do
    account = accounts(:depository)
    assert_includes @family.in_budget_accounts, account

    account.update!(in_budget: false)

    refute_includes @family.in_budget_accounts, account
  end

  test "reset_envelope_caches! clears the memoized envelope math" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Cache Test #{Time.now.to_f}", family: @family, color: "#333444")

    assert_equal 0, @family.envelope_balances_by_category[category.id]

    @family.budget_allocations.create!(category: category, amount: 75, currency: "USD", date: Date.current, kind: "fund")

    # Still memoized from the first read above
    assert_equal 0, @family.envelope_balances_by_category[category.id]

    @family.reset_envelope_caches!

    assert_equal 75, @family.envelope_balances_by_category[category.id]
  end
end
