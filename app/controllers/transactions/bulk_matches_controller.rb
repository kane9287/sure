# Manual override for TransactionReconciliation::Matcher. Lets a user force a
# manual-capture entry and a provider-synced entry together when the auto
# scorer misses an obvious pair, using the exact same merge path
# (TransactionReconciliation::Merger#apply_from_review!) as the reviewed queue.
class Transactions::BulkMatchesController < ApplicationController
  before_action :require_preview_features!

  def create
    entries = Current.family.entries.where(id: bulk_match_params[:entry_ids]).to_a

    unless entries.size == 2
      redirect_back_or_to transactions_path, alert: t(".invalid_selection")
      return
    end

    manual_entry, provider_entry = entries.partition { |entry| entry.external_id.blank? }.map(&:first)

    unless manual_entry && provider_entry
      redirect_back_or_to transactions_path, alert: t(".ambiguous_pair")
      return
    end

    if manual_entry.account_id != provider_entry.account_id
      redirect_back_or_to transactions_path, alert: t(".cross_account")
      return
    end

    split_alert = split_guard_alert(manual_entry, provider_entry)

    if split_alert.present?
      redirect_back_or_to transactions_path, alert: split_alert
      return
    end

    return unless require_account_permission!(manual_entry.account, :annotate, redirect_path: transactions_path)

    reconciliation = TransactionReconciliation.find_or_initialize_by(
      manual_entry_id: manual_entry.id,
      provider_source: provider_entry.source,
      provider_external_id: provider_entry.external_id
    )

    reconciliation.assign_attributes(
      family: Current.family,
      provider_entry: provider_entry,
      status: :pending,
      confidence: 1.0,
      score_breakdown: { "manual_override" => true },
      snapshot: { "manual_before" => TransactionReconciliation::Merger.manual_snapshot(manual_entry) },
      cross_account: false,
      matched_at: Time.current,
      resolved_at: nil,
      resolved_by_user: nil
    )
    reconciliation.save!

    if TransactionReconciliation::Merger.new(reconciliation).apply_from_review!(user: Current.user)
      redirect_back_or_to transactions_path, notice: t(".success")
    else
      redirect_back_or_to transactions_path, alert: t(".failure")
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed,
         ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
    Rails.logger.error("Failed to manually match transactions: #{e.message}")
    redirect_back_or_to transactions_path, alert: t(".failure")
  end

  private
    def bulk_match_params
      params.require(:bulk_match).permit(entry_ids: [])
    end

    # Matching a split parent is the point of letting it be selected at all: the
    # children hang off `parent_entry_id`, so claiming the parent carries the
    # whole split across. These are the three shapes where that goes wrong.
    #
    # @return [String, nil] the alert to show, or nil if the pair is safe
    def split_guard_alert(manual_entry, provider_entry)
      # Merger destroys the provider row, and `entries.parent_entry_id` cascades
      # on delete, so its children would go with it.
      return t(".split_provider_unsupported") if provider_entry.split_parent?

      # A child's date is pinned to its parent and it can't own a provider
      # identity of its own.
      if manual_entry.split_child? || provider_entry.split_child?
        return t(".split_child_unsupported")
      end

      return nil unless manual_entry.split_parent?

      # `claim_by_provider!` writes the provider's amount onto the parent while
      # the children still sum to the old one, breaking the exact-sum invariant
      # Entry#split! enforces. Nothing downstream re-checks it, so catch it here.
      if manual_entry.amount != provider_entry.amount
        return t(".split_amount_mismatch")
      end

      nil
    end
end
