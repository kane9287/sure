class TransactionReconciliation::Rescanner
  def self.call(account) = new(account).call

  def initialize(account)
    @account = account
  end

  def call
    return 0 unless account.family.manual_reconciliation_mode != "off"

    matcher = TransactionReconciliation::Matcher.new(
      account: account, mode: account.family.manual_reconciliation_mode
    )

    candidate_provider_entries.reduce(0) do |created, provider_entry|
      decision = matcher.call(
        external_id: provider_entry.external_id,
        source: provider_entry.source,
        amount: provider_entry.amount,
        currency: provider_entry.currency,
        date: provider_entry.date,
        name: provider_entry.name,
        merchant_id: provider_entry.transaction&.merchant_id
      )

      next created unless decision&.review?

      record = TransactionReconciliation::Merger.record_review!(
        decision: decision, provider_entry: provider_entry
      )
      record ? created + 1 : created
    end
  end

  private
    attr_reader :account

    # Provider-sourced rows (external_id present) still standing on their own —
    # a row that was already merged no longer exists (Merger destroys it), so
    # anything left here was never claimed. Excludes rows already under an open
    # or resolved reconciliation to avoid duplicate cards. Same recency bound
    # ProviderImportAdapter uses for a first sync, so a rescan can't reach
    # further back than a live sync ever would.
    def candidate_provider_entries
      account.entries
             .where(entryable_type: "Transaction")
             .where.not(external_id: nil)
             .where(date: Account::ProviderImportAdapter::BACKFILL_MATCH_RECENCY_DAYS.days.ago..)
             .where.not(id: TransactionReconciliation.where.not(provider_entry_id: nil).select(:provider_entry_id))
             .includes(:transaction)
    end
end
