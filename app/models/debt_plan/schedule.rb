class DebtPlan
  # Month-by-month debt payoff simulation. Pure PORO — hand it DebtPlan::Debt
  # values and a budget, get back a schedule. No ActiveRecord, no I/O.
  #
  # Both strategies pay every debt its minimum first, then throw the entire
  # remainder at a single target. Freeing a minimum when a debt clears rolls it
  # into next month's remainder automatically — that rolling is the "snowball",
  # and it applies to avalanche too. The strategies differ only in which debt
  # is the target:
  #
  #   avalanche → highest APR first  (mathematically cheapest)
  #   snowball  → smallest balance first (fastest first win)
  class Schedule
    # 50 years. Guards plans that never amortize instead of looping forever.
    MAX_MONTHS = 600

    Month = Data.define(
      :index, :date, :interest, :principal, :payment,
      :ending_balance, :cumulative_interest, :payments, :paid_off
    )

    PayoffStep = Data.define(:debt, :date, :month_index, :interest_paid, :payment)

    Result = Data.define(
      :status, :strategy, :months, :payoff_date, :months_to_payoff,
      :total_interest, :total_paid, :starting_balance, :payoff_order,
      :blocked_debts
    ) do
      def paid_off?
        status == :paid_off
      end

      # Anything other than :paid_off means we cannot honestly quote a date.
      def projectable?
        paid_off?
      end

      def years_to_payoff
        return nil if months_to_payoff.nil?

        months_to_payoff / 12
      end

      def remainder_months
        return nil if months_to_payoff.nil?

        months_to_payoff % 12
      end

      def first_payoff
        payoff_order.first
      end
    end

    attr_reader :debts, :monthly_budget, :strategy, :start_date

    def initialize(debts:, monthly_budget:, strategy: DebtPlan::DEFAULT_STRATEGY, start_date: Date.current)
      @debts = Array(debts).select { |debt| debt.balance.positive? }
      @monthly_budget = monthly_budget.to_d
      @strategy = DebtPlan::STRATEGIES.include?(strategy.to_s) ? strategy.to_s : DebtPlan::DEFAULT_STRATEGY
      @start_date = start_date
    end

    # Sum of every minimum the plan must cover in month one. A budget below
    # this can't even hold the debts steady, so we refuse to quote a date.
    def required_minimums
      debts.sum(0.to_d) { |debt| [ debt.minimum_amount, debt.balance ].min }
    end

    def starting_balance
      debts.sum(0.to_d, &:balance)
    end

    def run
      return terminal_result(:paid_off, payoff_date: start_date, months_to_payoff: 0) if debts.empty?
      return terminal_result(:underfunded) if monthly_budget < required_minimums

      balances = debts.to_h { |debt| [ debt.key, debt.balance ] }
      interest_by_debt = debts.to_h { |debt| [ debt.key, 0.to_d ] }
      cleared = {}

      months = []
      payoff_order = []
      cumulative_interest = 0.to_d
      total_paid = 0.to_d
      status = :never
      payoff_date = nil

      (1..MAX_MONTHS).each do |index|
        date = start_date >> index

        month_interest = accrue!(balances, interest_by_debt)
        payments = disburse!(balances)

        month_payment = payments.values.sum(0.to_d)
        cumulative_interest += month_interest
        total_paid += month_payment

        newly_cleared = debts.select do |debt|
          !cleared[debt.key] && balances[debt.key] <= 0 && payments[debt.key].to_d.positive?
        end

        newly_cleared.each do |debt|
          cleared[debt.key] = true
          payoff_order << PayoffStep.new(
            debt: debt,
            date: date,
            month_index: index,
            interest_paid: interest_by_debt[debt.key],
            payment: payments[debt.key]
          )
        end

        months << Month.new(
          index: index,
          date: date,
          interest: month_interest,
          principal: month_payment - month_interest,
          payment: month_payment,
          ending_balance: balances.values.sum(0.to_d),
          cumulative_interest: cumulative_interest,
          payments: payments,
          paid_off: newly_cleared
        )

        next unless balances.values.all?(&:zero?)

        status = :paid_off
        payoff_date = date
        break
      end

      status = stalled_status(balances) unless status == :paid_off

      Result.new(
        status: status,
        strategy: strategy,
        months: months,
        payoff_date: payoff_date,
        months_to_payoff: status == :paid_off ? months.size : nil,
        total_interest: cumulative_interest,
        total_paid: total_paid,
        starting_balance: starting_balance,
        payoff_order: payoff_order,
        blocked_debts: status == :paid_off ? [] : stalled_debts(balances)
      )
    end

    private
      # Charge a month of interest to every open debt, capitalizing it into the
      # balance. BigDecimal throughout — Float drift compounds over 600 months.
      def accrue!(balances, interest_by_debt)
        debts.sum(0.to_d) do |debt|
          next 0.to_d unless balances[debt.key].positive?

          charge = (balances[debt.key] * debt.monthly_rate).round(2)
          balances[debt.key] += charge
          interest_by_debt[debt.key] += charge
          charge
        end
      end

      # Minimums first (in plan order), then the entire remainder onto the
      # strategy's target, cascading to the next target as each one clears.
      def disburse!(balances)
        payments = debts.to_h { |debt| [ debt.key, 0.to_d ] }
        available = monthly_budget

        debts.each do |debt|
          break unless available.positive?
          next unless balances[debt.key].positive?

          pay = [ debt.minimum_amount, balances[debt.key], available ].min
          next unless pay.positive?

          balances[debt.key] -= pay
          payments[debt.key] += pay
          available -= pay
        end

        prioritized(balances).each do |debt|
          break unless available.positive?

          pay = [ available, balances[debt.key] ].min
          next unless pay.positive?

          balances[debt.key] -= pay
          payments[debt.key] += pay
          available -= pay
        end

        payments
      end

      def prioritized(balances)
        open = debts.select { |debt| balances[debt.key].positive? }

        if strategy == "snowball"
          open.sort_by { |debt| [ balances[debt.key], -debt.apr_amount, debt.name.to_s.downcase ] }
        else
          open.sort_by { |debt| [ -debt.apr_amount, balances[debt.key], debt.name.to_s.downcase ] }
        end
      end

      # We ran out of months. Distinguish "just very slow" from "structurally
      # impossible": if a surviving debt's minimum is below its own monthly
      # interest and the budget never reaches it, the balance grows forever.
      def stalled_status(balances)
        stalled_debts(balances).any? ? :negative_amortization : :never
      end

      def stalled_debts(balances)
        debts.select do |debt|
          balance = balances[debt.key]
          balance.positive? && debt.minimum_amount < (balance * debt.monthly_rate).round(2)
        end
      end

      def terminal_result(status, payoff_date: nil, months_to_payoff: nil)
        Result.new(
          status: status,
          strategy: strategy,
          months: [],
          payoff_date: payoff_date,
          months_to_payoff: months_to_payoff,
          total_interest: 0.to_d,
          total_paid: 0.to_d,
          starting_balance: starting_balance,
          payoff_order: [],
          blocked_debts: status == :underfunded ? debts.select(&:negative_amortization?) : []
        )
      end
  end
end
