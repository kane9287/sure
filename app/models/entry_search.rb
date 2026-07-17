class EntrySearch
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :search, :string
  attribute :amount, :string
  attribute :amount_operator, :string
  attribute :types, :string
  attribute :status, array: true
  attribute :accounts, array: true
  attribute :account_ids, array: true
  attribute :start_date, :string
  attribute :end_date, :string

  class << self
    def apply_search_filter(scope, search)
      return scope if search.blank?

      conditions = [ "entries.name ILIKE :search OR entries.notes ILIKE :search" ]
      params = { search: "%#{ActiveRecord::Base.sanitize_sql_like(search)}%" }

      if (range = numeric_search_range(search))
        conditions << "(ABS(entries.amount) >= :amount_low AND ABS(entries.amount) < :amount_high)"
        params[:amount_low]  = range.first
        params[:amount_high] = range.last
      end

      scope.where(conditions.join(" OR "), params)
    end

    def apply_date_filters(scope, start_date, end_date)
      return scope if start_date.blank? && end_date.blank?

      query = scope
      query = query.where("entries.date >= ?", start_date) if start_date.present?
      query = query.where("entries.date <= ?", end_date) if end_date.present?
      query
    end

    def apply_amount_filter(scope, amount, amount_operator)
      return scope if amount.blank? || amount_operator.blank?

      query = scope

      case amount_operator
      when "equal"
        query = query.where("ABS(ABS(entries.amount) - ?) <= 0.01", amount.to_f.abs)
      when "less"
        query = query.where("ABS(entries.amount) < ?", amount.to_f.abs)
      when "greater"
        query = query.where("ABS(entries.amount) > ?", amount.to_f.abs)
      end

      query
    end

    def apply_accounts_filter(scope, accounts, account_ids)
      return scope if accounts.blank? && account_ids.blank?

      query = scope
      query = query.where(accounts: { name: accounts }) if accounts.present?
      query = query.where(accounts: { id: account_ids }) if account_ids.present?
      query
    end

    def apply_status_filter(scope, statuses)
      return scope unless statuses.present?
      return scope if statuses.uniq.sort == %w[confirmed pending] # Both selected = no filter

      # Source the pending check from Transaction::PENDING_CHECK_SQL (aliased to
      # "t") so every provider in PENDING_PROVIDERS is covered. Previously this
      # hardcoded only simplefin/plaid/lunchflow, dropping enable_banking.
      pending_condition = <<~SQL.squish
        entries.entryable_type = 'Transaction'
        AND EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND (#{Transaction::PENDING_CHECK_SQL})
        )
      SQL

      confirmed_condition = <<~SQL.squish
        entries.entryable_type != 'Transaction'
        OR NOT EXISTS (
          SELECT 1 FROM transactions t
          WHERE t.id = entries.entryable_id
          AND (#{Transaction::PENDING_CHECK_SQL})
        )
      SQL

      case statuses.sort
      when [ "pending" ]
        scope.where(pending_condition)
      when [ "confirmed" ]
        scope.where(confirmed_condition)
      else
        scope
      end
    end

    private

    def numeric_search_range(search)
      normalized = search.to_s.strip.delete(",").sub(/\A[$€£]/, "")
      return nil unless normalized.match?(/\A\d+(\.\d+)?\z/)

      value    = BigDecimal(normalized)
      decimals = normalized[/\.(\d+)\z/, 1]&.length || 0
      step     = BigDecimal(1) / (10 ** decimals)
      [ value, value + step ]
    end
  end

  def build_query(scope)
    query = scope.joins(:account)
    query = self.class.apply_search_filter(query, search)
    query = self.class.apply_date_filters(query, start_date, end_date)
    query = self.class.apply_amount_filter(query, amount, amount_operator)
    query = self.class.apply_accounts_filter(query, accounts, account_ids)
    query = self.class.apply_status_filter(query, status)
    query
  end
end
