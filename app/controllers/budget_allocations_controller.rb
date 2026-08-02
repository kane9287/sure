class BudgetAllocationsController < ApplicationController
  before_action :set_budget
  before_action :require_envelope_mode

  # Funds an envelope from the family's Unassigned pool (kind: "fund"), or
  # sweeps money from an envelope back to Unassigned (kind: "sweep", negative
  # amount). When from_category_id is present, atomically moves money
  # between two envelopes (sweep source, fund destination) instead of
  # touching the Unassigned pool -- the "move money from…" affordance for
  # negative envelopes. See BudgetAllocation and
  # Family#envelope_balances_by_category.
  def create
    category = Current.family.categories.find(allocation_params[:category_id])
    kind = allocation_params[:kind].presence || "fund"
    amount = allocation_params[:amount].to_d
    amount = -amount.abs if kind == "sweep"
    from_category_id = allocation_params[:from_category_id].presence

    if from_category_id
      move_money(from_category_id: from_category_id, to_category: category, amount: amount.abs)
    else
      fund_or_sweep(category: category, amount: amount, kind: kind)
    end

    Current.family.reset_envelope_caches!
    redirect_to budget_budget_categories_path(@budget), notice: t("budget_allocations.create.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to budget_budget_categories_path(@budget), alert: e.record.errors.full_messages.to_sentence
  end

  private
    def fund_or_sweep(category:, amount:, kind:)
      Current.family.budget_allocations.create!(
        category: category, amount: amount, currency: Current.family.currency, date: Date.current, kind: kind
      )
    end

    def move_money(from_category_id:, to_category:, amount:)
      source_category = Current.family.categories.find(from_category_id)

      ActiveRecord::Base.transaction do
        Current.family.budget_allocations.create!(
          category: source_category, amount: -amount, currency: Current.family.currency, date: Date.current, kind: "sweep"
        )
        Current.family.budget_allocations.create!(
          category: to_category, amount: amount, currency: Current.family.currency, date: Date.current, kind: "fund"
        )
      end
    end

    def allocation_params
      params.require(:budget_allocation).permit(:category_id, :amount, :kind, :from_category_id)
    end

    def set_budget
      start_date = Budget.param_to_date(params[:budget_month_year], family: Current.family)
      @budget = Current.family.budgets.find_by!(start_date: start_date)
    end

    def require_envelope_mode
      redirect_to budget_budget_categories_path(@budget), alert: t("budget_allocations.create.envelope_mode_required") unless Current.family.envelope_mode?
    end
end
