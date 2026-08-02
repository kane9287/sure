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
    # The shared goals fixtures deliberately point three goals at the same
    # account, which is the ambiguous shared-pool case the family-wide clamp
    # covers — not a clean basis for asserting exact figures.
    @family.goals.destroy_all
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

    goal_account = create_in_budget_account(balance: 500)
    create_whole_account_goal(account: goal_account, target_amount: 200)

    @family.reset_envelope_caches!

    # $300 funded - $120 spent = $180 still reserved in the envelope, and the
    # goal earmarks $200 of its $500 backing account (capped at its target).
    assert_equal 180, @family.envelope_balances_by_category[category.id]
    assert_equal(
      @family.in_budget_cash_balance.amount - @family.envelope_balances_by_category.values.sum - 200,
      @family.unassigned_pool_balance.amount
    )
  end

  test "a whole-account goal earmarks its backing out of the unassigned pool" do
    @family.activate_envelope_mode!
    @family.goals.destroy_all
    account = create_in_budget_account(balance: 400)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    create_whole_account_goal(account: account, target_amount: 1_000)
    @family.reset_envelope_caches!

    # Whole-account link (goal_accounts.allocated_amount is nil): the account's
    # entire $400 backs a goal that still needs $1,000, so all of it leaves the
    # pool.
    assert_equal unassigned_before - 400, @family.unassigned_pool_balance.amount
  end

  test "a goal earmarks only up to its target; backing beyond that stays unassigned" do
    @family.activate_envelope_mode!
    @family.goals.destroy_all
    account = create_in_budget_account(balance: 3_000)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    create_whole_account_goal(account: account, target_amount: 1_200)
    @family.reset_envelope_caches!

    # $3,000 backs a $1,200 goal, so only the $1,200 it needs is earmarked —
    # the $1,800 of overflow stays allocatable.
    assert_equal unassigned_before - 1_200, @family.unassigned_pool_balance.amount
  end

  test "archiving a goal releases its earmark back to the unassigned pool" do
    @family.activate_envelope_mode!
    @family.goals.destroy_all
    account = create_in_budget_account(balance: 800)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    goal = create_whole_account_goal(account: account, target_amount: 800)
    @family.reset_envelope_caches!
    assert_equal unassigned_before - 800, @family.unassigned_pool_balance.amount

    goal.archive!
    @family.reset_envelope_caches!

    assert_equal unassigned_before, @family.unassigned_pool_balance.amount
  end

  test "a goal backed by an out-of-budget account does not touch the unassigned pool" do
    @family.activate_envelope_mode!
    @family.goals.destroy_all
    account = create_in_budget_account(balance: 900)
    account.update!(in_budget: false)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    create_whole_account_goal(account: account, target_amount: 900)
    @family.reset_envelope_caches!

    assert_equal unassigned_before, @family.unassigned_pool_balance.amount
  end

  test "goal earmarks never exceed the family's in-budget cash" do
    @family.activate_envelope_mode!
    @family.goals.destroy_all
    @family.accounts.update_all(in_budget: false)
    account = create_in_budget_account(balance: 1_000)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    # Two goals both dedicating the whole of the same account each claim its
    # full balance (Goal#backing_share_for only nets out other goals' *fixed*
    # earmarks), so the naive sum would be $2,000 earmarked against $1,000 of
    # cash. The clamp holds it to the $1,000 that actually exists.
    create_whole_account_goal(account: account, target_amount: 5_000)
    create_whole_account_goal(account: account, target_amount: 5_000)

    @family.reset_envelope_caches!

    assert_equal 1_000, @family.in_budget_cash_balance.amount
    assert_equal unassigned_before - 1_000, @family.unassigned_pool_balance.amount
  end

  test "in_budget_cash_balance sums balances across in-budget accounts" do
    account = accounts(:depository)
    other_account = accounts(:connected)

    assert_equal account.balance + other_account.balance, @family.in_budget_cash_balance.amount

    account.update!(in_budget: false)

    assert_equal other_account.balance, @family.in_budget_cash_balance.amount
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

  private
    def create_in_budget_account(balance:)
      @family.accounts.create!(
        name: "Envelope Goal Account #{Time.now.to_f}",
        balance: balance,
        currency: "USD",
        accountable: Depository.new
      )
    end

    def create_whole_account_goal(account:, target_amount:)
      @family.goals.create!(
        name: "Envelope Goal #{Time.now.to_f}",
        target_amount: target_amount,
        currency: "USD"
      ) { |goal| goal.goal_accounts.build(account: account) }
    end
end
