# Net signed sum of every transaction on the family's revolving-debt accounts,
# in the family's currency. Envelope mode holds this amount in the built-in
# Debt Payment envelope so a credit purchase doesn't invent cash: the spending
# envelope falls and the reserve rises by the same amount, leaving
# Family#unassigned_pool_balance untouched until the card is actually paid.
#
# Deliberately mirrors IncomeStatement::Totals#transactions_subquery_sql clause
# for clause. Parity is load-bearing, not stylistic: any filter this applies
# that Totals doesn't (or vice versa) lets a charge drain a spending envelope
# without a matching reserve, which is exactly the bug this exists to fix.
#
# Two differences from Totals, both intentional:
#
#   1. Restricted to REVOLVING_TYPES accounts.
#   2. NO `at.kind NOT IN (budget-excluded kinds)` predicate.
#
# (2) is what makes this a single query. The card-side leg of a card payment is
# a `funds_movement` transaction on the card with a negative amount — it *is*
# the payment, recorded on the debt side — so including every kind lets
# payments, balance transfers, cash advances and one-off charges all net out
# through the same signed sum. Filtering by kind and subtracting cc_payment
# separately gets balance transfers and cash advances wrong.
class IncomeStatement::LiabilityReserve
  # Accounts whose payments Transfer.kind_for_account maps to "cc_payment".
  #
  # Loan is deliberately absent. `loan_payment` is not budget-excluded and is
  # force-classified as an expense by Totals, so a loan payment already moves
  # cash and an envelope together — reserving for it as well would double
  # count, and interest accruals would inflate the reserve with nothing to
  # release them.
  REVOLVING_TYPES = %w[CreditCard OtherLiability].freeze

  def initialize(family, transactions_scope:, date_range:, included_account_ids: nil)
    @family = family
    @transactions_scope = transactions_scope
    @date_range = date_range
    @included_account_ids = included_account_ids

    validate_date_range!
  end

  def call
    # No finance accounts means nothing to reserve against
    return BigDecimal(0) if @included_account_ids&.empty?

    row = ActiveRecord::Base.connection.select_one(query_sql)
    (row&.fetch("reserve", nil) || 0).to_d
  end

  private
    def query_sql
      ActiveRecord::Base.sanitize_sql_array([ reserve_query_sql, sql_params ])
    end

    def reserve_query_sql
      <<~SQL
        SELECT COALESCE(SUM(ae.amount * COALESCE(er.rate, 1)), 0) as reserve
        FROM (#{@transactions_scope.to_sql}) at
        JOIN entries ae ON ae.entryable_id = at.id AND ae.entryable_type = 'Transaction'
        JOIN accounts a ON a.id = ae.account_id
        LEFT JOIN exchange_rates er ON (
          er.date = ae.date AND
          er.from_currency = ae.currency AND
          er.to_currency = :target_currency
        )
        WHERE a.accountable_type IN (:revolving_types)
          AND (
            at.investment_activity_label IS NULL
            OR at.investment_activity_label NOT IN ('Transfer', 'Sweep In', 'Sweep Out', 'Exchange')
          )
          AND ae.excluded = false
          AND a.family_id = :family_id
          AND a.status IN ('draft', 'active')
          AND a.exclude_from_reports = false
          #{exclude_tax_advantaged_sql}
          #{include_finance_accounts_sql}
      SQL
    end

    def sql_params
      params = {
        target_currency: @family.currency,
        family_id: @family.id,
        revolving_types: REVOLVING_TYPES,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }

      ids = @family.tax_advantaged_account_ids
      params[:tax_advantaged_account_ids] = ids if ids.present?

      params[:included_account_ids] = @included_account_ids if @included_account_ids

      params
    end

    def exclude_tax_advantaged_sql
      ids = @family.tax_advantaged_account_ids
      return "" if ids.empty?
      "AND a.id NOT IN (:tax_advantaged_account_ids)"
    end

    def include_finance_accounts_sql
      return "" if @included_account_ids.nil?
      "AND a.id IN (:included_account_ids)"
    end

    def validate_date_range!
      unless @date_range.is_a?(Range)
        raise ArgumentError, "date_range must be a Range, got #{@date_range.class}"
      end

      unless @date_range.begin.respond_to?(:to_date) && @date_range.end.respond_to?(:to_date)
        raise ArgumentError, "date_range must contain date-like objects"
      end
    end
end
