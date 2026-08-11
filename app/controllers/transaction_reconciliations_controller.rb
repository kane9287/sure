class TransactionReconciliationsController < ApplicationController
  before_action :require_preview_features!
  before_action :set_reconciliation, only: %i[confirm reject]

  def index
    load_queue
    @breadcrumbs = [ [ t("breadcrumbs.home"), dashboard_path ], [ t("transaction_reconciliations.index.title"), nil ] ]

    # Deliberately no mark-as-read here, unlike the insights feed. These rows are
    # a question waiting on an answer, not a notification — the badge should
    # clear when the queue is empty, not when it has been glanced at.
  end

  def confirm
    return unless authorize_reconciliation!

    if TransactionReconciliation::Merger.new(@reconciliation).apply_from_review!(user: Current.user)
      respond_with_queue notice: t(".success")
    else
      respond_with_queue alert: t(".failure")
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed,
         ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
    Rails.logger.error("Failed to confirm reconciliation #{@reconciliation.id}: #{e.message}")
    respond_with_queue alert: t(".failure")
  end

  def reject
    return unless authorize_reconciliation!

    if TransactionReconciliation::Merger.new(@reconciliation).reject!(user: Current.user)
      respond_with_queue notice: t(".success")
    else
      respond_with_queue alert: t(".failure")
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::Deadlocked,
         ActiveRecord::LockWaitTimeout => e
    Rails.logger.error("Failed to reject reconciliation #{@reconciliation.id}: #{e.message}")
    respond_with_queue alert: t(".failure")
  end

  private
    # Scoped through the family, so another family's id is a 404 rather than a
    # permission error that confirms the row exists.
    def set_reconciliation
      @reconciliation = Current.family.transaction_reconciliations.find(params[:id])
    end

    # Merging rewrites an entry, so the acting user needs write access to the
    # account it lives on — the same bar the manual duplicate merge applies.
    def authorize_reconciliation!
      require_account_permission!(
        @reconciliation.manual_entry.account,
        :annotate,
        redirect_path: transaction_reconciliations_path
      )
    end

    def load_queue
      @reconciliations = Current.family.transaction_reconciliations
                                .actionable
                                .ordered
                                .includes(manual_entry: :account, provider_entry: :account)
                                .to_a
    end

    def respond_with_queue(notice: nil, alert: nil)
      load_queue

      respond_to do |format|
        format.turbo_stream do
          flash.now[:notice] = notice if notice
          flash.now[:alert]  = alert  if alert
          render :update
        end
        format.html { redirect_to transaction_reconciliations_path, notice: notice, alert: alert }
      end
    end
end
