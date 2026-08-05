class BudgetAllocationsController < ApplicationController
  before_action :set_budget
  before_action :require_envelope_mode

  # Moves money into or out of an envelope. Every path lands in the same
  # append-only BudgetAllocation ledger; only the arithmetic differs.
  #
  #   kind: "fund"  -- additive, Unassigned -> envelope. The row's Add button.
  #   kind: "sweep" -- additive, envelope -> Unassigned (stored negative). The
  #                    row's Remove button. Unlike "set" this can pull out
  #                    balance carried in from earlier periods, not just what
  #                    was assigned within this one.
  #   kind: "set"   -- absolute. Makes this period's assigned total equal
  #                    :amount, posting only the difference. No longer used by
  #                    the UI, but kept as a supported ledger operation.
  #
  # from_category_id takes precedence over kind and atomically moves :amount
  # between two envelopes (sweep the source, fund the destination), leaving the
  # Unassigned pool untouched. See BudgetAllocation and
  # Family#envelope_balances_by_category.
  def create
    category = Current.family.categories.find(allocation_params[:category_id])
    kind = allocation_params[:kind].presence || "fund"
    amount = allocation_params[:amount].to_d
    from_category_id = allocation_params[:from_category_id].presence

    if from_category_id
      move_money(from_category_id: from_category_id, to_category: category, amount: amount.abs)
    elsif kind == "set"
      set_assigned(category: category, target: amount)
    else
      amount = -amount.abs if kind == "sweep"
      fund_or_sweep(category: category, amount: amount, kind: kind)
    end

    Current.family.reset_envelope_caches!
    redirect_to budget_budget_categories_path(@budget), notice: t("budget_allocations.create.success")
  rescue ActiveRecord::RecordInvalid => e
    redirect_to budget_budget_categories_path(@budget), alert: e.record.errors.full_messages.to_sentence
  end

  private
    # Posts the gap between what's already assigned to this envelope within
    # @budget's period and the requested total. A zero delta posts nothing, so
    # submitting an unchanged box leaves no ledger noise behind. A target below
    # what's already assigned sweeps the difference back to Unassigned — the
    # only "reduce" mechanism the UI needs.
    def set_assigned(category:, target:)
      already_assigned = (@budget.envelope_funded_this_period_by_category[category.id] || 0).to_d
      delta = target - already_assigned
      return if delta.zero?

      fund_or_sweep(category: category, amount: delta, kind: delta.positive? ? "fund" : "sweep")
    end

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
