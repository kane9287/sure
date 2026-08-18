require "test_helper"

# Credit spending used to invent money: a card charge dropped its spending
# envelope while cash stayed put, so the Unassigned pool grew by the amount
# just spent and shrank again a month later when the card was paid. The built-in
# Debt Payment envelope absorbs that gap.
#
# The property under test throughout is Δunassigned == 0 across events that only
# move money between cash, debt and envelopes. Note that a bare Entry never
# moves accounts.balance (sync_account_later is called explicitly, not by a
# callback), so post! moves both — without that these assertions pass vacuously.
class FamilyEnvelopeDebtTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.activate_envelope_mode!

    @checking = accounts(:depository)
    @card = accounts(:credit_card)
    @groceries = @family.categories.create!(name: "Groceries #{Time.now.to_f}", color: "#123456")
    @debt = @family.debt_payment_category
  end

  test "envelope mode creates the built-in Debt Payment category" do
    assert @debt.debt_payment?
    assert @debt.system?
    assert_equal @debt, @family.debt_payment_category
  end

  test "a card purchase drops the spending envelope and raises the reserve by the same amount" do
    fund!(@groceries, 200)
    groceries_before, debt_before = balance(@groceries), balance(@debt)

    assert_pool_unchanged do
      post!(account: @card, amount: 100, category: @groceries)
    end

    assert_equal groceries_before - 100, balance(@groceries)
    assert_equal debt_before + 100, balance(@debt)
  end

  test "paying the card drains the reserve and the cash together" do
    fund!(@groceries, 200)
    post!(account: @card, amount: 100, category: @groceries)
    debt_before = balance(@debt)

    assert_pool_unchanged do
      pay!(100, to: @card)
    end

    assert_equal debt_before - 100, balance(@debt)
  end

  test "spending cash out of a funded envelope leaves the reserve alone" do
    fund!(@groceries, 200)
    debt_before = balance(@debt)

    assert_pool_unchanged do
      post!(account: @checking, amount: 50, category: @groceries)
    end

    assert_equal debt_before, balance(@debt)
  end

  test "the debt reserve is not clamped at zero" do
    debt_before = balance(@debt)

    # A refund with no offsetting charge. Clamping the reserve at zero here
    # would leave the refund raising the spending envelope with nothing pulling
    # the other way, and the pool would lose $30 that still exists.
    assert_pool_unchanged do
      post!(account: @card, amount: -30, category: @groceries)
    end

    assert_equal debt_before - 30, balance(@debt)
  end

  test "overspending a card envelope shows red without moving the pool" do
    fund!(@groceries, 80)
    debt_before = balance(@debt)

    assert_pool_unchanged do
      post!(account: @card, amount: 250, category: @groceries)
    end

    assert_operator balance(@groceries), :<, 0
    assert_equal debt_before + 250, balance(@debt)
  end

  test "the pool holds steady across a full credit cycle" do
    assert_pool_unchanged do
      fund!(@groceries, 200)
      post!(account: @card, amount: 100, category: @groceries)
      pay!(100, to: @card)
      post!(account: @checking, amount: 50, category: @groceries)
      post!(account: @card, amount: -30, category: @groceries)
      post!(account: @card, amount: 250, category: @groceries)
    end
  end

  test "debt carried in at activation stays out of the envelope system" do
    reserve_before = @family.debt_reserve.amount

    # A balance that predates activation arrives as a balance change, not as
    # transactions in the period, so nothing enters the reserve. Carried-in debt
    # is retired through DebtPlan, not by reserving cash the family may not have.
    @card.update!(balance: @card.balance + 500)
    @family.reset_envelope_caches!

    assert_equal reserve_before, @family.debt_reserve.amount
  end

  test "assigning for a card payment before making it leaves the envelope square" do
    @card.update!(balance: @card.balance + 500)

    # The intended workflow: budget this month's payment, then make it. The
    # assignment costs the pool, the payment doesn't, and the envelope lands
    # back where it started.
    assert_difference -> { @family.reset_envelope_caches!; @family.unassigned_pool_balance.amount }, -300 do
      fund!(@debt, 300)
    end

    debt_before = balance(@debt)

    assert_pool_unchanged do
      pay!(300, to: @card)
    end

    assert_equal debt_before - 300, balance(@debt)
    assert_equal 0, @family.debt_reserve.amount
  end

  test "paying down carried-in debt without assigning first shows as a shortfall" do
    @card.update!(balance: @card.balance + 500)
    debt_before = balance(@debt)

    assert_pool_unchanged do
      pay!(500, to: @card)
    end

    # Same mechanics as any other overspend — the cash is gone, so the envelope
    # is short until it's covered, and the pool only moves when the user assigns.
    assert_equal debt_before - 500, balance(@debt)
    assert_equal(-500, @family.debt_reserve.amount)

    assert_difference -> { @family.reset_envelope_caches!; @family.unassigned_pool_balance.amount }, -500 do
      fund!(@debt, 500)
    end

    assert_equal 0, @family.debt_reserve.amount
  end

  test "a payment categorized Debt Payment drains the envelope without moving the pool" do
    fund!(@debt, 300)
    debt_before = balance(@debt)

    # The case the category was unlocked for: a payment to a debt whose other
    # leg the app never sees, so nothing enters the reserve to drain it. The
    # user's own categorization is what moves the envelope.
    assert_pool_unchanged do
      post!(account: @checking, amount: 200, category: @debt)
    end

    assert_equal debt_before - 200, balance(@debt)
  end

  test "a matched card payment ignores its category so the reserve isn't drained twice" do
    fund!(@groceries, 200)
    post!(account: @card, amount: 100, category: @groceries)
    debt_before = balance(@debt)

    pay!(100, to: @card)

    # Both legs of a matched payment are budget-excluded kinds, so tagging one
    # Debt Payment can't subtract on top of the reserve's own drain.
    @checking.transactions.where(kind: "cc_payment").each { |txn| txn.update!(category: @debt) }

    assert_equal debt_before - 100, balance(@debt)
  end

  test "a detected card payment is categorized into the envelope it drains" do
    fund!(@groceries, 200)
    post!(account: @card, amount: 100, category: @groceries)
    debt_before = balance(@debt)

    transfer = nil
    assert_pool_unchanged do
      transfer = pay!(100, to: @card)
    end

    # The point of the whole exercise: the payment leaves the ledger reading
    # "Debt Payment" instead of Uncategorized, so nobody has to point a rule at
    # a second envelope to make it look right. The reserve still drains once.
    assert_equal @debt, transfer.outflow_transaction.category
    assert_equal debt_before - 100, balance(@debt)
  end

  test "a loan payment expenses its envelope without touching the debt reserve" do
    fund!(@groceries, 500)
    debt_before = balance(@debt)

    assert_pool_unchanged do
      post!(account: @checking, amount: 300, category: @groceries, kind: "loan_payment")
    end

    assert_equal debt_before, balance(@debt)
  end

  test "debt_reserve is zero in cap mode" do
    @family.deactivate_envelope_mode!

    assert_equal 0, @family.debt_reserve.amount
  end

  private
    def assert_pool_unchanged
      @family.reset_envelope_caches!
      before = @family.unassigned_pool_balance.amount

      yield

      @family.reset_envelope_caches!
      assert_equal before, @family.unassigned_pool_balance.amount,
        "Unassigned moved on an event that only shifts money between cash, debt and envelopes"
    end

    def balance(category)
      @family.reset_envelope_caches!
      @family.envelope_balances_by_category[category.id]
    end

    def fund!(category, amount)
      @family.budget_allocations.create!(
        category: category, amount: amount, currency: "USD", date: Date.current, kind: "fund"
      )
    end

    # An Entry on its own never moves accounts.balance — Entry#sync_account_later
    # is called explicitly, not from a callback — so move it here too. Without
    # this, cash is frozen and every pool assertion passes for free.
    def post!(account:, amount:, category: nil, kind: "standard")
      Entry.create!(
        account: account,
        date: Date.current,
        name: "Posted #{amount}",
        amount: amount,
        currency: "USD",
        entryable: Transaction.create!(category: category, kind: kind)
      )

      delta = account.classification == "liability" ? amount : -amount
      account.update!(balance: account.balance + delta)
    end

    def pay!(amount, to:, from: @checking)
      Transfer::Creator.new(
        family: @family,
        source_account_id: from.id,
        destination_account_id: to.id,
        date: Date.current,
        amount: amount
      ).create.tap do
        from.update!(balance: from.balance - amount)
        to.update!(balance: to.balance - amount)
      end
    end
end
