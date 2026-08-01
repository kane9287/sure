require "test_helper"

class DebtPlan::ScheduleTest < ActiveSupport::TestCase
  # Pure engine — no fixtures, no database. Debts are built inline so each
  # case is a hand-checkable amortization.
  def debt(key, balance:, apr: nil, minimum: nil, name: nil)
    DebtPlan::Debt.new(key: key, name: name || key.to_s, balance: balance, apr: apr, minimum: minimum)
  end

  def three_debts
    [
      debt(:high_rate, balance: 1000, apr: 24, minimum: 25),
      debt(:small_balance, balance: 500, apr: 10, minimum: 25),
      debt(:big, balance: 3000, apr: 18, minimum: 60)
    ]
  end

  def run_schedule(debts, budget, strategy, start_date: Date.new(2026, 1, 31))
    DebtPlan::Schedule.new(
      debts: debts,
      monthly_budget: budget,
      strategy: strategy,
      start_date: start_date
    ).run
  end

  test "avalanche clears the highest rate first" do
    result = run_schedule(three_debts, 400, "avalanche")

    assert_equal :paid_off, result.status
    assert_equal :high_rate, result.payoff_order.first.debt.key
  end

  test "snowball clears the smallest balance first" do
    result = run_schedule(three_debts, 400, "snowball")

    assert_equal :paid_off, result.status
    assert_equal :small_balance, result.payoff_order.first.debt.key
  end

  test "avalanche never costs more interest than snowball" do
    avalanche = run_schedule(three_debts, 400, "avalanche")
    snowball = run_schedule(three_debts, 400, "snowball")

    assert avalanche.total_interest <= snowball.total_interest,
           "avalanche (#{avalanche.total_interest}) should not exceed snowball (#{snowball.total_interest})"
  end

  test "a cleared debt's minimum rolls into the next target" do
    debts = [
      debt(:small, balance: 100, minimum: 100),
      debt(:big, balance: 1000, minimum: 50)
    ]

    result = run_schedule(debts, 150, "snowball")

    assert_equal :paid_off, result.status
    # Month 1: 100 clears :small, 50 to :big. Month 2 onward the freed 100
    # rolls forward, so :big receives the whole 150.
    assert_equal 100.to_d, result.months.first.payments[:small]
    assert_equal 150.to_d, result.months.second.payments[:big]
    assert_equal 8, result.months_to_payoff
  end

  test "a zero-interest debt terminates with no interest" do
    result = run_schedule([ debt(:free, balance: 1200, apr: 0, minimum: 100) ], 100, "avalanche")

    assert_equal :paid_off, result.status
    assert_equal 12, result.months_to_payoff
    assert_equal 0.to_d, result.total_interest
  end

  test "a budget below the minimums is reported as underfunded" do
    result = run_schedule(three_debts, 50, "avalanche")

    assert_equal :underfunded, result.status
    assert_nil result.payoff_date
    assert_empty result.months
  end

  test "a minimum below the monthly interest is reported as negative amortization" do
    # 24% APR on 10,000 is 200/mo of interest against a 100/mo minimum, and the
    # budget leaves nothing extra to break the cycle.
    result = run_schedule([ debt(:sinking, balance: 10_000, apr: 24, minimum: 100) ], 100, "avalanche")

    assert_equal :negative_amortization, result.status
    assert_equal [ :sinking ], result.blocked_debts.map(&:key)
  end

  test "the month guard trips instead of looping forever" do
    result = run_schedule([ debt(:huge, balance: 100_000) ], 1, "avalanche")

    assert_equal :never, result.status
    assert_equal DebtPlan::Schedule::MAX_MONTHS, result.months.size
    assert_nil result.months_to_payoff
  end

  test "no debts means already debt free" do
    result = run_schedule([], 100, "avalanche")

    assert_equal :paid_off, result.status
    assert_equal 0, result.months_to_payoff
  end
end
