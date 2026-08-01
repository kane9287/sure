require "test_helper"

class DebtPlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @plan = debt_plans(:card_payoff)
    @credit_card = accounts(:credit_card)
    @other_liability = accounts(:other_liability)
  end

  def debt_for(account, plan: @plan)
    DebtPlan.find(plan.id).debts.find { |debt| debt.key == account.id }
  end

  test "reads rate and minimum off the accountable when no override is set" do
    debt = debt_for(@credit_card)

    assert_equal credit_cards(:one).apr, debt.apr
    assert_equal credit_cards(:one).minimum_payment, debt.minimum
    assert debt.complete?
  end

  test "plan overrides win over the accountable's own columns" do
    debt_plan_accounts(:card_payoff_credit_card).update!(apr_override: 9.5, minimum_payment_override: 60)

    debt = debt_for(@credit_card)

    assert_equal 9.5.to_d, debt.apr
    assert_equal 60.to_d, debt.minimum
  end

  test "an accountable with no rate columns resolves from overrides alone" do
    debt = debt_for(@other_liability)

    assert_equal 6.5.to_d, debt.apr
    assert_equal 25.to_d, debt.minimum
  end

  test "a debt with neither an override nor an accountable value is incomplete" do
    debt_plan_accounts(:card_payoff_iou).update!(apr_override: nil, minimum_payment_override: nil)

    plan = DebtPlan.find(@plan.id)
    debt = plan.debts.find { |d| d.key == @other_liability.id }

    assert_nil debt.apr
    assert_nil debt.minimum
    assert_not debt.complete?
    assert_includes plan.incomplete_debts.map(&:key), @other_liability.id
  end

  test "detects mortgages by loan subtype" do
    account = accounts(:loan)
    account.update!(subtype: "mortgage")

    debt = DebtPlan::Debt.from_link(DebtPlanAccount.new(debt_plan: @plan, account: account))

    assert debt.mortgage?
  end

  test "total minimums caps each minimum at its balance" do
    assert_equal 125.to_d, @plan.total_minimums
    assert_equal 375.to_d, @plan.extra_payment
    assert_not @plan.underfunded?
  end

  test "requires at least one debt" do
    plan = @family.debt_plans.new(name: "Empty", strategy: "avalanche", monthly_budget: 100, currency: "USD")

    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :base
  end

  test "rejects accounts that are not liabilities" do
    plan = @family.debt_plans.new(name: "Mixed", strategy: "avalanche", monthly_budget: 100, currency: "USD")
    plan.debt_plan_accounts.build(account: accounts(:depository))

    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :linked_accounts
  end

  test "rejects debts in a different currency than the plan" do
    plan = DebtPlan.find(@plan.id)
    plan.currency = "EUR"

    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :linked_accounts
  end

  test "rejects an unknown strategy" do
    plan = DebtPlan.find(@plan.id)
    plan.strategy = "lasso"

    assert_not plan.valid?
    assert_includes plan.errors.attribute_names, :strategy
  end

  test "schedule is memoized per strategy" do
    plan = DebtPlan.find(@plan.id)

    assert_same plan.schedule("avalanche"), plan.schedule("avalanche")
    assert_not_same plan.schedule("avalanche"), plan.schedule("snowball")
  end

  test "payoff payload pre-formats every currency string" do
    payload = DebtPlan.find(@plan.id).payoff_payload

    assert_equal "USD", payload[:currency]
    assert payload[:series].first[:balance_formatted].present?
    assert payload[:series].all? { |point| point[:interest_formatted].present? }
  end
end
