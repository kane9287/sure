require "test_helper"

class Family::DebtReserveTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.activate_envelope_mode!
    @card = accounts(:credit_card)
  end

  test "lists one line per revolving-debt account and totals them" do
    reserve = Family::DebtReserve.new(@family)

    line_accounts = reserve.lines.map(&:account)
    assert_includes line_accounts, @card
    assert_includes line_accounts, accounts(:other_liability)
    assert_not_includes line_accounts, accounts(:loan)
    assert_not_includes line_accounts, accounts(:depository)

    assert_equal reserve.lines.sum { |line| line.balance_money.amount }, reserve.total_debt_money.amount
  end

  test "drops zero-balance accounts from the breakdown" do
    @card.update!(balance: 0)

    reserve = Family::DebtReserve.new(@family)

    assert_not_includes reserve.lines.map(&:account), @card
  end

  # Carried-in debt is not the envelope's problem: it never asks to be reserved,
  # so a family that simply owes money sees no shortfall and no prefilled demand.
  test "carrying debt does not by itself create a shortfall" do
    square_envelope!

    reserve = Family::DebtReserve.new(@family)

    assert reserve.any_debt?, "the fixture family owes on two revolving accounts"
    assert_not reserve.shortfall?
    assert_equal 0, reserve.shortfall_money.amount

    # The prefill offers this month's minimum, never the carried balance —
    # asking for the full 1200 owed is precisely the behavior this replaced.
    assert_operator reserve.total_debt_money.amount, :>, reserve.suggested_payment_money.amount
    assert_equal "125.00", reserve.prefill
  end

  test "a card payment with nothing assigned becomes the shortfall and the prefill" do
    @family.stubs(:debt_reserve).returns(Money.new(-125, "USD"))

    reserve = Family::DebtReserve.new(@family)

    assert reserve.shortfall?
    assert_equal 125, reserve.shortfall_money.amount
    assert_equal 0, reserve.reserved_money.amount
    assert_equal "125.00", reserve.prefill
  end

  test "a positive balance reads as reserved with no shortfall" do
    @family.stubs(:debt_reserve).returns(Money.new(60, "USD"))

    reserve = Family::DebtReserve.new(@family)

    assert_not reserve.shortfall?
    assert_equal 60, reserve.reserved_money.amount
    assert_equal 0, reserve.shortfall_money.amount
  end

  # The fixture plan exercises both resolution paths in DebtPlan::Debt: the card
  # falls back to CreditCard#minimum_payment (100), while the IOU has no such
  # column and depends on its plan-level override (25).
  test "suggests this month's card minimums from the family's payoff plans" do
    square_envelope!

    reserve = Family::DebtReserve.new(@family)

    assert reserve.suggested_payment?
    assert_equal 125, reserve.suggested_payment_money.amount
    assert_equal "125.00", reserve.prefill, "no shortfall, so the plan minimum is offered"
  end

  # Loan payments are already expensed through their own spending envelope by
  # IncomeStatement::Totals, so counting a loan minimum here would fund it twice.
  test "loan minimums are left out of the suggestion" do
    square_envelope!
    debt_plans(:card_payoff).debt_plan_accounts.create!(
      account: accounts(:loan), minimum_payment_override: 2_000, apr_override: 4
    )

    assert_equal 125, Family::DebtReserve.new(@family).suggested_payment_money.amount
  end

  test "a shortfall takes precedence over the plan minimum in the prefill" do
    @family.stubs(:debt_reserve).returns(Money.new(-200, "USD"))

    reserve = Family::DebtReserve.new(@family)

    assert_equal 125, reserve.suggested_payment_money.amount
    assert_equal "200.00", reserve.prefill
  end

  test "prefill is blank when there is nothing to suggest" do
    square_envelope!
    @family.debt_plans.destroy_all

    reserve = Family::DebtReserve.new(@family)

    assert_not reserve.suggested_payment?
    assert_equal "", reserve.prefill
  end

  private
    # Pins the envelope balance at zero so a test about suggestions or the
    # breakdown isn't at the mercy of whatever card activity the fixtures
    # happen to place in the current period.
    def square_envelope!
      @family.stubs(:debt_reserve).returns(Money.new(0, "USD"))
    end
end
