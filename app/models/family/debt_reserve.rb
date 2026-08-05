# View-model for the built-in Debt Payment envelope on the envelope budget
# screen. Keeps the per-account breakdown and the reserved/shortfall arithmetic
# out of the template — the row is the only place any of it is needed, so it
# lives here rather than in Family.
#
# Scope note: this envelope is responsible for card spending done *since*
# envelope mode was switched on, nothing more. Debt carried in before that is
# deliberately outside the envelope system — it's retired through DebtPlan at a
# pace the family chooses, so nothing here ever asks them to reserve it.
class Family::DebtReserve
  Line = Data.define(:account, :balance_money)

  attr_reader :family

  def initialize(family)
    @family = family
  end

  # The envelope's raw balance: funded + new card spending - payments. Negative
  # when payments have gone out that nothing was assigned for.
  def balance_money
    @balance_money ||= family.debt_reserve
  end

  def reserved_money
    Money.new([ balance_money.amount, 0 ].max, currency)
  end

  # Card payments already made with no assignment behind them. Unlike a debt
  # balance this is small, monthly and actionable: the cash is gone, so
  # Unassigned overstates what's available until it's covered.
  def shortfall_money
    Money.new([ -balance_money.amount, 0 ].max, currency)
  end

  def shortfall?
    shortfall_money.positive?
  end

  # What the family's payoff plans say this month's card minimums come to — the
  # natural amount to assign here, offered as a suggestion and never enforced.
  #
  # Loans are excluded even when a plan covers them: loan_payment is already
  # expensed by IncomeStatement::Totals, so a loan reconciles through its own
  # spending envelope and counting it here would fund it twice.
  def suggested_payment_money
    @suggested_payment_money ||= Money.new(suggested_payment_amount, currency)
  end

  def suggested_payment?
    suggested_payment_money.positive?
  end

  # Prefill for the assign box: clear the shortfall first if there is one,
  # otherwise offer this month's minimums. Blank when we'd be guessing.
  def prefill
    amount = shortfall? ? shortfall_money.amount : suggested_payment_money.amount
    return "" unless amount.positive?

    sprintf("%.2f", amount)
  end

  def total_debt_money
    Money.new(lines.sum { |line| line.balance_money.amount }, currency)
  end

  # One line per revolving-debt account the reserve is computed over, so the
  # user can see which card the number came from. Zero-balance accounts are
  # dropped — they'd be noise on an otherwise short list.
  def lines
    @lines ||= family.income_statement
                     .eligible_accounts
                     .where(accountable_type: IncomeStatement::LiabilityReserve::REVOLVING_TYPES,
                            currency: currency)
                     .order(:name)
                     .filter_map do |account|
                       next if account.balance.to_d.zero?

                       Line.new(account: account, balance_money: Money.new(account.balance, currency))
                     end
  end

  def any_debt?
    lines.any?
  end

  private
    def currency
      family.primary_currency_code
    end

    def suggested_payment_amount
      revolving = IncomeStatement::LiabilityReserve::REVOLVING_TYPES

      family.debt_plans
            .where(currency: currency)
            .flat_map(&:debts)
            .select { |debt| revolving.include?(debt.account&.accountable_type) }
            .uniq(&:key) # an account may be linked to more than one plan
            .sum(0.to_d) { |debt| [ debt.minimum_amount, debt.balance ].min }
    end
end
