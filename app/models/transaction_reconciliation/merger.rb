# Turns a Matcher::Decision into a durable record, and a reviewed pair into a
# single entry.
#
# **The invariant this class exists to hold:** no provider-sourced money ever
# leaves the ledger un-represented. The only row this class ever destroys is a
# provider row whose `external_id`, `source`, amount and date were transferred
# to a survivor in the same transaction — so the bank's version of events is
# always present exactly once, under its own identity, and the next sync finds
# it by the ordinary `find_or_initialize_by(external_id:, source:)` path.
#
# The survivor is always the manual entry. Its UUID never changes, so tags,
# attachments, splits and transfer links come through untouched — which is the
# entire reason this is a claim rather than a copy.
class TransactionReconciliation::Merger
  Error = Class.new(StandardError)

  # Enough of the pre-merge manual entry to put it back. `locked_attributes` is
  # snapshotted verbatim rather than reconstructed: which fields the user had
  # taken ownership of is not derivable from the values alone.
  MANUAL_ENTRY_SNAPSHOT_ATTRIBUTES = %w[
    amount currency date name notes excluded user_modified locked_attributes
    external_id source
  ].freeze

  # Notes live on the entry, not the transaction, so they are covered above.
  TRANSACTION_SNAPSHOT_ATTRIBUTES = %w[
    category_id merchant_id kind extra locked_attributes
  ].freeze

  class << self
    # Called from Account::ProviderImportAdapter after the provider entry has
    # been saved, so the pair is recorded with both sides pointing at real rows.
    # Records only — nothing is mutated, which is what makes the review path
    # safe to ship ahead of auto-merge.
    def record_review!(decision:, provider_entry:, family: provider_entry.account.family)
      manual_entry = decision.manual_entry

      # Something claimed the manual entry between scoring and saving. Rare, but
      # the whole point of matching on `external_id IS NULL` is that a claimed
      # entry is off the table.
      return nil if manual_entry.external_id.present?

      TransactionReconciliation.create!(
        family: family,
        manual_entry: manual_entry,
        provider_entry: provider_entry,
        provider_external_id: decision.payload["external_id"],
        provider_source: decision.payload["source"],
        status: :pending,
        confidence: decision.confidence,
        score_breakdown: decision.result.breakdown,
        snapshot: {
          "provider_payload" => decision.payload,
          "manual_before" => manual_snapshot(manual_entry)
        },
        cross_account: decision.cross_account,
        matched_at: Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      # The pair is already on file — a re-import of the same provider payload
      # after its entry was destroyed. Idempotent by design.
      TransactionReconciliation.find_by(
        manual_entry_id: decision.manual_entry.id,
        provider_source: decision.payload["source"],
        provider_external_id: decision.payload["external_id"]
      )
    end

    def manual_snapshot(entry)
      snapshot = entry.attributes.slice(*MANUAL_ENTRY_SNAPSHOT_ATTRIBUTES)
      snapshot["amount"] = snapshot["amount"].to_s
      snapshot["date"] = snapshot["date"].to_s
      snapshot["transaction"] = transaction_snapshot(entry)
      snapshot
    end

    def transaction_snapshot(entry)
      return {} unless entry.transaction?

      entry.entryable.attributes.slice(*TRANSACTION_SNAPSHOT_ATTRIBUTES)
    end
  end

  def initialize(reconciliation)
    @reconciliation = reconciliation
  end

  # The human said yes. Both rows exist here — unlike the auto path, where the
  # provider row was claimed before it was ever created — so the provider row
  # hands its identity to the survivor and is destroyed.
  def apply_from_review!(user:)
    return false unless reconciliation.resolvable?

    provider_entry = reconciliation.provider_entry
    manual_entry   = reconciliation.manual_entry

    return false if provider_entry.nil?
    raise Error, "cross-account merges are not supported" if provider_entry.account_id != manual_entry.account_id

    window_start = nil

    ApplicationRecord.transaction(requires_new: true) do
      begin
        manual_entry.lock!
        provider_entry.lock!
      rescue ActiveRecord::RecordNotFound
        # One side was deleted while the card sat on screen. Nothing to merge.
        raise ActiveRecord::Rollback
      end

      raise ActiveRecord::Rollback if manual_entry.external_id.present?

      # Read the provider side live rather than from the snapshot: a pending row
      # can have been revised upward between the match and the confirmation, and
      # the bank's current number is the one that belongs on the ledger.
      payload           = provider_payload(provider_entry)
      provider_tx_attrs = self.class.transaction_snapshot(provider_entry)
      window_start      = [ manual_entry.date, provider_entry.date ].min

      snapshot = reconciliation.snapshot.merge(
        "provider_payload" => payload,
        "provider_transaction" => provider_tx_attrs,
        "manual_before" => self.class.manual_snapshot(manual_entry)
      )

      # Read off the provider row before it goes away; approving a match must not
      # discard the memo the auto-claim path would have kept.
      provider_notes = provider_entry.notes

      # Destroy before claiming. The partial unique index on
      # (account_id, source, external_id) is checked per statement rather than
      # at commit, so the provider row has to release the identity before the
      # survivor can take it. Both happen inside one transaction, so the pair is
      # never observable in a half-merged state.
      provider_entry.destroy!

      manual_entry.claim_by_provider!(
        external_id: payload["external_id"],
        source: payload["source"],
        amount: payload["amount"].to_d,
        date: Date.parse(payload["date"])
      )

      sync_split_children_date(manual_entry)
      merge_notes(manual_entry, provider_notes)
      backfill_from_provider(manual_entry, provider_tx_attrs)

      reconciliation.update!(
        status: :confirmed,
        provider_entry_id: nil,
        snapshot: snapshot,
        resolved_at: Time.current,
        resolved_by_user: user
      )
    end

    return false unless reconciliation.confirmed?

    manual_entry.account.sync_later(window_start_date: window_start)
    true
  end

  # The human said no. Nothing moves; the row becomes the tombstone that keeps
  # the next sync from proposing the same pair again.
  def reject!(user:)
    return false unless reconciliation.resolvable?

    reconciliation.resolve!(status: :rejected, user: user)
    true
  end

  private
    attr_reader :reconciliation

    def provider_payload(entry)
      {
        "external_id" => entry.external_id,
        "source" => entry.source,
        "amount" => entry.amount.to_s,
        "currency" => entry.currency,
        "date" => entry.date.to_s,
        "name" => entry.name,
        "merchant_id" => (entry.entryable.merchant_id if entry.transaction?)
      }
    end

    # A split parent's children are validated to share its date, and the list
    # view groups them under it by date (EntriesHelper#group_split_entries). The
    # claim moves the parent onto the provider's date, so the children have to
    # follow or the group silently breaks apart — `split_child_date_matches_parent`
    # only fires on a child's own date change, so nothing catches this from the
    # parent's side.
    #
    # `update!` rather than `update_column`: the validation compares against
    # `parent_entry.date`, which already holds the claimed value, so it passes
    # and the children keep their ordinary callbacks.
    def sync_split_children_date(manual_entry)
      manual_entry.child_entries.where.not(date: manual_entry.date).each do |child|
        child.update!(date: manual_entry.date)
      end
    end

    # Notes are the one field where neither side wins outright: the user's note
    # and the bank's memo are concatenated, matching what a sync would do to a
    # claimed row (`Account::ProviderImportAdapter#import_transaction`).
    def merge_notes(manual_entry, provider_notes)
      merged = manual_entry.notes_merged_with(provider_notes)
      # Blank means neither side had anything to say.
      return if merged.blank? || merged == manual_entry.notes

      manual_entry.update!(notes: merged)
    end

    # The provider fills gaps, never overwrites. `enrich_attributes` consults
    # `locked_attributes` per field, and a manual entry has its name, notes,
    # category and merchant locked at creation — so this reduces in practice to
    # "adopt the merchant the provider identified, if the user never named one".
    def backfill_from_provider(manual_entry, provider_tx_attrs)
      return unless manual_entry.transaction?

      manual_tx = manual_entry.entryable

      # A split parent's category is meaningless — the children hold the
      # categories and the parent is excluded from the income statement — so the
      # provider's guess would only surface a stray category on the parent row.
      backfillable = manual_entry.split_parent? ? %w[merchant_id] : %w[category_id merchant_id]

      attrs = backfillable.each_with_object({}) do |key, hash|
        value = provider_tx_attrs[key]
        hash[key] = value if value.present? && manual_tx[key].blank?
      end

      manual_tx.enrich_attributes(attrs, source: "reconciliation") if attrs.any?

      incoming = provider_tx_attrs["extra"].presence || {}
      return if incoming.blank?

      merged = (manual_tx.extra || {}).deep_merge(incoming)
      manual_tx.update!(extra: merged) if merged != manual_tx.extra
    end
end
