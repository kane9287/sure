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

  test "spending from a funded envelope leaves the unassigned pool where it was" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Identity Test #{Time.now.to_f}", family: @family, color: "#222333")
    account = accounts(:depository)

    @family.budget_allocations.create!(category: category, amount: 300, currency: "USD", date: Date.current, kind: "fund")
    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    # Asserting `unassigned == cash - sum(balances)` would be tautological —
    # that's the definition of unassigned_pool_balance. The property that can
    # actually fail is that cash and the envelope move together, which needs
    # accounts.balance moved alongside the Entry (Entry#sync_account_later is
    # called explicitly, not from a callback, so an Entry alone freezes cash).
    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: category),
      date: Date.current,
      name: "Spend",
      amount: 120,
      currency: "USD"
    )
    account.update!(balance: account.balance - 120)

    @family.reset_envelope_caches!

    assert_equal 180, @family.envelope_balances_by_category[category.id]
    assert_equal unassigned_before, @family.unassigned_pool_balance.amount
  end

  test "subcategory spend is counted once, not once per ancestor" do
    @family.activate_envelope_mode!
    parent = categories(:food_and_drink)
    child = categories(:subcategory)
    account = accounts(:depository)

    @family.budget_allocations.create!(category: parent, amount: 300, currency: "USD", date: Date.current, kind: "fund")
    @family.budget_allocations.create!(category: child, amount: 200, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: child),
      date: Date.current,
      name: "Restaurant",
      amount: 100,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    # A parent's CategoryTotal#total is own + children, so charging it against
    # both envelopes would drain $200 of budget for $100 of spend and invent
    # the difference in the Unassigned pool.
    assert_equal 100, @family.envelope_balances_by_category[child.id]
    assert_equal 300, @family.envelope_balances_by_category[parent.id]
  end

  test "a goal backed by an in-budget account does not move the unassigned pool" do
    @family.activate_envelope_mode!
    account = create_in_budget_account(balance: 800)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    # Goals never withhold cash on their own — they claim it by being funded
    # into an envelope, like every other dollar. Reserving the backing account's
    # balance instead would pull the whole $800 out of the pool and leave
    # nothing to budget with.
    create_whole_account_goal(account: account, target_amount: 5_000)
    @family.reset_envelope_caches!

    assert_equal unassigned_before, @family.unassigned_pool_balance.amount
  end

  test "funding a goal's envelope moves the pool by exactly the amount assigned" do
    @family.activate_envelope_mode!
    category = Category.create!(name: "Goal Envelope #{Time.now.to_f}", family: @family, color: "#445566")
    goal = @family.goals.create!(name: "Holiday fund", target_amount: 1_200, currency: "USD", category: category)

    @family.reset_envelope_caches!
    unassigned_before = @family.unassigned_pool_balance.amount

    @family.budget_allocations.create!(category: category, amount: 500, currency: "USD", date: Date.current, kind: "fund")
    @family.reset_envelope_caches!

    # Assigning is the only thing that moves money: $500 out of the pool, $500
    # into the envelope, $500 of progress on the goal.
    assert_equal unassigned_before - 500, @family.unassigned_pool_balance.amount
    assert_equal 500, @family.envelope_balances_by_category[category.id]
    assert_equal BigDecimal("500"), Goal.find(goal.id).current_balance.to_d
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
