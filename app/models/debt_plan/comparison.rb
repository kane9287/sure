class DebtPlan
  # Runs the same debts and budget through both strategies so the UI can answer
  # the only question that matters when choosing one: what does each cost you?
  #
  # Avalanche always wins on interest (it never leaves a higher rate accruing
  # while it pays a lower one). Snowball's payoff is behavioural — it usually
  # clears the *first* debt sooner, which is why people stick with it.
  class Comparison
    attr_reader :avalanche, :snowball

    # Takes already-run results so a plan can hand over its memoized schedules
    # instead of paying for a second pass of each strategy.
    def initialize(avalanche:, snowball:)
      @avalanche = avalanche
      @snowball = snowball
    end

    def for(strategy)
      strategy.to_s == "snowball" ? snowball : avalanche
    end

    def comparable?
      avalanche.paid_off? && snowball.paid_off?
    end

    # Positive => avalanche costs this much less interest than snowball.
    def interest_saved
      return nil unless comparable?

      snowball.total_interest - avalanche.total_interest
    end

    # Positive => avalanche is debt-free this many months sooner.
    def months_saved
      return nil unless comparable?

      snowball.months_to_payoff - avalanche.months_to_payoff
    end

    # Positive => snowball clears its first debt this many months sooner.
    def first_payoff_months_saved
      return nil unless comparable?

      avalanche_first = avalanche.first_payoff&.month_index
      snowball_first = snowball.first_payoff&.month_index
      return nil if avalanche_first.nil? || snowball_first.nil?

      avalanche_first - snowball_first
    end
  end
end
