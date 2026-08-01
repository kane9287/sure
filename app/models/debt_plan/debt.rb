class DebtPlan
  # Normalizes the three incompatible liability accountables (CreditCard, Loan,
  # OtherLiability) into one uniform shape the payoff engine can consume.
  #
  # Only CreditCard carries both a rate and a minimum; Loan has a rate but no
  # minimum column; OtherLiability has neither. Plan-level overrides therefore
  # take precedence over whatever the accountable happens to expose, and a
  # missing value stays nil so the UI can flag it rather than silently
  # pretending it is zero.
  class Debt
    attr_reader :key, :name, :balance, :apr, :minimum, :currency, :account, :subtype

    class << self
      # Resolution order for both rate and minimum: plan override, then the
      # accountable's own column, then nil.
      def from_link(link)
        account = link.account
        accountable = account.accountable

        new(
          key: link.account_id,
          name: account.name,
          balance: account.balance,
          apr: link.apr_override || accountable_apr(accountable),
          minimum: link.minimum_payment_override || accountable_minimum(accountable),
          currency: account.currency,
          account: account,
          subtype: account.subtype,
          mortgage: mortgage?(account, accountable)
        )
      end

      def accountable_apr(accountable)
        case accountable
        when CreditCard then accountable.apr
        when Loan then accountable.interest_rate
        end
      end

      # Loan#monthly_payment is a fixed-rate annuity computed off the *original*
      # balance, so it is a prefill hint only — never authoritative.
      def accountable_minimum(accountable)
        case accountable
        when CreditCard then accountable.minimum_payment
        when Loan then accountable.monthly_payment&.amount
        end
      end

      def mortgage?(account, accountable)
        accountable.is_a?(Loan) && account.subtype == "mortgage"
      end
    end

    def initialize(key:, name:, balance:, apr: nil, minimum: nil, currency: nil, account: nil, subtype: nil, mortgage: false)
      @key = key
      @name = name
      @balance = balance.to_d
      @apr = apr&.to_d
      @minimum = minimum&.to_d
      @currency = currency
      @account = account
      @subtype = subtype
      @mortgage = mortgage
    end

    def mortgage?
      @mortgage
    end

    # A nil APR is treated as 0% by the engine, which silently breaks avalanche
    # ordering — #complete? drives the "needs input" badge that warns about it.
    def apr_amount
      apr || 0.to_d
    end

    def minimum_amount
      minimum || 0.to_d
    end

    def monthly_rate
      apr_amount / 1200
    end

    def monthly_interest
      (balance * monthly_rate).round(2)
    end

    def apr?
      apr.present?
    end

    def minimum?
      minimum.present?
    end

    def complete?
      apr? && minimum?
    end

    # The minimum doesn't even cover this month's interest, so paying only the
    # minimum grows the balance forever.
    def negative_amortization?
      minimum? && balance.positive? && minimum_amount < monthly_interest
    end

    def balance_money
      Money.new(balance, currency) if currency
    end

    def minimum_money
      Money.new(minimum_amount, currency) if currency
    end
  end
end
