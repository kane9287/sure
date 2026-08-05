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
end
