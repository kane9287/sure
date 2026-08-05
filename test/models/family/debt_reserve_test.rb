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

  test "is not fully reserved while debt is carried in unfunded" do
    reserve = Family::DebtReserve.new(@family)

    assert reserve.any_debt?
    assert_not reserve.fully_reserved?
    assert_operator reserve.unreserved_money.amount, :>, 0
    assert_equal sprintf("%.2f", reserve.unreserved_money.amount), reserve.unreserved_prefill
  end

  test "is fully reserved once the shortfall is assigned" do
    shortfall = Family::DebtReserve.new(@family).unreserved_money.amount

    @family.budget_allocations.create!(
      category: @family.debt_payment_category, amount: shortfall,
      currency: "USD", date: Date.current, kind: "fund"
    )
    @family.reset_envelope_caches!

    reserve = Family::DebtReserve.new(@family)

    assert reserve.fully_reserved?
    assert_equal 0, reserve.unreserved_money.amount
  end
end
