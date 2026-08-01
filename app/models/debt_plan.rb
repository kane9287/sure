class DebtPlan < ApplicationRecord
  include Monetizable

  # Declared here rather than on Schedule so this file's body never references a
  # nested constant at load time (which would depend on autoload ordering).
  STRATEGIES = %w[avalanche snowball].freeze
  DEFAULT_STRATEGY = "avalanche".freeze
  LIABILITY_TYPES = %w[CreditCard Loan OtherLiability].freeze

  # Budget bumps offered on the plan page ("what if I put $50 more at it?").
  WHAT_IF_INCREMENTS = [ 50, 100, 250 ].freeze

  belongs_to :family
  has_many :debt_plan_accounts, dependent: :destroy, autosave: true
  has_many :linked_accounts, through: :debt_plan_accounts, source: :account

  validates :name, presence: true, length: { maximum: 255 }
  validates :currency, presence: true
  validates :strategy, inclusion: { in: STRATEGIES }
  validates :monthly_budget, numericality: { greater_than: 0 }
  validate :must_have_at_least_one_linked_account
  validate :linked_accounts_must_be_liabilities
  validate :linked_accounts_must_match_plan_currency
  validate :linked_accounts_must_belong_to_family

  monetize :monthly_budget

  scope :alphabetically, -> { order(Arel.sql("LOWER(name) ASC")) }

  def avalanche?
    strategy == "avalanche"
  end

  def snowball?
    strategy == "snowball"
  end

  # Live snapshot of every linked liability, normalized. Recomputed from the
  # current account balances on every view — a plan keeps no balance history.
  def debts
    @debts ||= debt_plan_accounts
                 .reject(&:marked_for_destruction?)
                 .filter_map { |link| link.account && link.debt }
                 .sort_by { |debt| debt.name.to_s.downcase }
  end

  # Memoized per strategy: the index renders one schedule per plan, the show
  # page renders both, and neither should pay for the other.
  def schedule(strategy_override = nil)
    active = strategy_override.presence || strategy
    @schedules ||= {}
    @schedules[active] ||= Schedule.new(debts: debts, monthly_budget: monthly_budget.to_d, strategy: active).run
  end

  def comparison
    @comparison ||= Comparison.new(avalanche: schedule("avalanche"), snowball: schedule("snowball"))
  end

  def total_balance
    debts.sum(0.to_d, &:balance)
  end

  def total_balance_money
    Money.new(total_balance, currency)
  end

  def total_minimums
    debts.sum(0.to_d) { |debt| [ debt.minimum_amount, debt.balance ].min }
  end

  def total_minimums_money
    Money.new(total_minimums, currency)
  end

  # Everything above the minimums is what actually retires principal early.
  def extra_payment
    [ monthly_budget.to_d - total_minimums, 0.to_d ].max
  end

  def extra_payment_money
    Money.new(extra_payment, currency)
  end

  def underfunded?
    monthly_budget.to_d < total_minimums
  end

  # Debts missing an APR or a minimum. A missing APR is treated as 0% by the
  # engine, which quietly distorts avalanche ordering, so the UI flags these.
  def incomplete_debts
    debts.reject(&:complete?)
  end

  def negative_amortization_debts
    debts.select(&:negative_amortization?)
  end

  def weighted_average_apr
    return nil if total_balance.zero?

    (debts.sum(0.to_d) { |debt| debt.balance * debt.apr_amount } / total_balance).round(2)
  end

  # [{ increment:, monthly_budget_money:, result: }] for the "pay a bit more"
  # strip. Only offered once the base plan actually resolves to a date.
  def what_if_results(strategy_override = nil)
    active_strategy = strategy_override.presence || strategy

    WHAT_IF_INCREMENTS.map do |increment|
      budget = monthly_budget.to_d + increment
      {
        increment: increment,
        increment_money: Money.new(increment, currency),
        monthly_budget_money: Money.new(budget, currency),
        result: Schedule.new(debts: debts, monthly_budget: budget, strategy: active_strategy).run
      }
    end
  end

  # Chart handoff. Every currency string is formatted here so the D3 controller
  # does no money math — the same contract Goal#projection_payload uses.
  def payoff_payload(strategy_override = nil)
    result = schedule(strategy_override)

    {
      currency: currency,
      currency_symbol: Money::Currency.new(currency).symbol,
      status: result.status,
      series: payoff_series(result),
      labels: {
        balance: I18n.t("debt_plans.chart.balance"),
        interest: I18n.t("debt_plans.chart.interest")
      }
    }
  end

  private
    def payoff_series(result)
      series = [ {
        date: Date.current.iso8601,
        label: I18n.l(Date.current, format: :short),
        balance: total_balance.to_f,
        balance_formatted: Money.new(total_balance, currency).format(precision: 0),
        interest: 0.0,
        interest_formatted: Money.new(0, currency).format(precision: 0)
      } ]

      result.months.each do |month|
        series << {
          date: month.date.iso8601,
          label: I18n.l(month.date, format: :short),
          balance: month.ending_balance.to_f,
          balance_formatted: Money.new(month.ending_balance, currency).format(precision: 0),
          interest: month.cumulative_interest.to_f,
          interest_formatted: Money.new(month.cumulative_interest, currency).format(precision: 0)
        }
      end

      series
    end

    def active_links
      debt_plan_accounts.reject(&:marked_for_destruction?)
    end

    def must_have_at_least_one_linked_account
      return unless active_links.empty?

      errors.add(:base, :at_least_one_linked_account_required)
    end

    def linked_accounts_must_be_liabilities
      offending = active_links.reject do |link|
        link.account.nil? || LIABILITY_TYPES.include?(link.account.accountable_type)
      end
      return if offending.empty?

      errors.add(:linked_accounts, :must_be_liabilities)
    end

    # One currency per plan. Projecting FX rates years out isn't meaningful and
    # mixing currencies would raise inside the simulation loop.
    def linked_accounts_must_match_plan_currency
      return if currency.blank?

      mismatched = active_links.reject do |link|
        link.account.nil? || link.account.currency == currency
      end
      return if mismatched.empty?

      errors.add(:linked_accounts, :currency_mismatch)
    end

    def linked_accounts_must_belong_to_family
      return if family.nil?

      foreign = active_links.reject do |link|
        link.account.nil? || link.account.family_id == family_id
      end
      return if foreign.empty?

      errors.add(:linked_accounts, :must_belong_to_family)
    end
end
