# View-model for the built-in Debt Payment envelope on the envelope budget
# screen. Keeps the per-account breakdown and the reserved/unreserved
# arithmetic out of the template — the row is the only place any of it is
# needed, so it lives here rather than in Family.
class Family::DebtReserve
  Line = Data.define(:account, :balance_money)

  attr_reader :family

  def initialize(family)
    @family = family
  end

  def reserved_money
    @reserved_money ||= family.debt_reserve
  end

  def unreserved_money
    @unreserved_money ||= family.unreserved_debt_balance
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

  def fully_reserved?
    !unreserved_money.positive?
  end

  # Prefill for the "reserve it now" form: the shortfall, rounded to cents.
  def unreserved_prefill
    sprintf("%.2f", unreserved_money.amount)
  end

  private
    def currency
      family.primary_currency_code
    end
end
