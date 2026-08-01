class DebtPlansController < ApplicationController
  before_action :set_debt_plan, only: %i[show edit update destroy]

  LIABILITY_TYPES = DebtPlan::LIABILITY_TYPES

  rescue_from ActiveRecord::RecordNotFound, with: :debt_plan_not_found

  def index
    @debt_plans = Current.family.debt_plans
                         .alphabetically
                         .includes(debt_plan_accounts: { account: :accountable })
                         .to_a
    @linkable_account_count = linkable_accounts.count
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("debt_plans.index.title"), nil ]
    ]
  end

  def show
    # Query param, not session state — the saved strategy stays the default and
    # the toggle is shareable/back-button friendly.
    @strategy = requested_strategy
    @result = @debt_plan.schedule(@strategy)
    @comparison = @debt_plan.comparison
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("debt_plans.index.title"), debt_plans_path ],
      [ @debt_plan.name, nil ]
    ]
  end

  def new
    @debt_plan = Current.family.debt_plans.new(
      name: t("debt_plans.new.default_name"),
      strategy: "avalanche",
      currency: Current.family.primary_currency_code
    )
    load_form_collections
    # Mortgages are technically debt but almost nobody wants a 30-year note
    # dominating a payoff plan, so they start unchecked.
    @selected_account_ids = @linkable_accounts.reject { |a| mortgage?(a) }.map { |a| a.id.to_s }
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("debt_plans.index.title"), debt_plans_path ],
      [ t("debt_plans.new.heading"), nil ]
    ]
  end

  def create
    @debt_plan = Current.family.debt_plans.new(debt_plan_params)
    accounts = lookup_accounts(params.dig(:debt_plan, :account_ids))
    @debt_plan.currency = (accounts.first&.currency || Current.family.primary_currency_code) if @debt_plan.currency.blank?

    overrides = submitted_overrides
    DebtPlan.transaction do
      accounts.each { |account| @debt_plan.debt_plan_accounts.build(link_attributes(account, overrides)) }
      @debt_plan.save!
    end

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to debt_plan_path(@debt_plan) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, debt_plan_path(@debt_plan)) }
    end
  rescue ActiveRecord::RecordInvalid
    load_form_collections
    @selected_account_ids = Array(params.dig(:debt_plan, :account_ids)).reject(&:blank?).map(&:to_s)
    render :new, status: :unprocessable_entity
  end

  def edit
    load_form_collections
    @selected_account_ids = @debt_plan.debt_plan_accounts.map { |link| link.account_id.to_s }
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("debt_plans.index.title"), debt_plans_path ],
      [ @debt_plan.name, debt_plan_path(@debt_plan) ],
      [ t("debt_plans.edit.heading"), nil ]
    ]
  end

  def update
    account_ids = params.dig(:debt_plan, :account_ids)
    accounts_supplied = !account_ids.nil?
    accounts = accounts_supplied ? lookup_accounts(account_ids) : []

    if accounts_supplied && accounts.empty?
      @debt_plan.errors.add(:base, :at_least_one_linked_account_required)
      load_edit_failure_state
      render :edit, status: :unprocessable_entity
      return
    end

    DebtPlan.transaction do
      @debt_plan.update!(debt_plan_params)
      sync_linked_accounts!(@debt_plan, accounts, submitted_overrides) if accounts_supplied
    end

    flash[:notice] = t(".success")
    respond_to do |format|
      format.html { redirect_to debt_plan_path(@debt_plan) }
      format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, debt_plan_path(@debt_plan)) }
    end
  rescue ActiveRecord::RecordInvalid
    load_edit_failure_state
    render :edit, status: :unprocessable_entity
  end

  def destroy
    @debt_plan.destroy!
    redirect_to debt_plans_path, notice: t(".success")
  end

  private
    def set_debt_plan
      @debt_plan = Current.family.debt_plans
                          .includes(debt_plan_accounts: { account: :accountable })
                          .find(params[:id])
    end

    def debt_plan_not_found
      redirect_to debt_plans_path, alert: t("debt_plans.errors.not_found")
    end

    def debt_plan_params
      params.require(:debt_plan).permit(:name, :strategy, :monthly_budget, :notes)
    end

    def requested_strategy
      DebtPlan::STRATEGIES.include?(params[:strategy]) ? params[:strategy] : @debt_plan.strategy
    end

    def linkable_accounts
      Current.user.accessible_accounts.where(accountable_type: LIABILITY_TYPES).visible
    end

    def lookup_accounts(ids)
      return [] if ids.blank?

      linkable_accounts.where(id: Array(ids).reject(&:blank?)).to_a
    end

    def load_form_collections
      @linkable_accounts = linkable_accounts.includes(:accountable).alphabetically.to_a
    end

    def load_edit_failure_state
      load_form_collections
      @selected_account_ids = Array(params.dig(:debt_plan, :account_ids)).reject(&:blank?).map(&:to_s)
    end

    def mortgage?(account)
      account.accountable_type == "Loan" && account.subtype == "mortgage"
    end

    def link_attributes(account, overrides)
      values = overrides[account.id.to_s] || {}
      {
        account: account,
        apr_override: values[:apr],
        minimum_payment_override: values[:minimum]
      }
    end

    def sync_linked_accounts!(plan, accounts, overrides)
      desired_ids = accounts.map(&:id).to_set
      current_ids = plan.debt_plan_accounts.pluck(:account_id).to_set

      # Only unlink accounts the current user can actually see in the picker. A
      # family plan may link another member's private account, which never
      # renders as a checkbox — its absence is not an intentional removal.
      removable_ids = Current.user.accessible_accounts.where(id: current_ids.to_a).pluck(:id).to_set

      ((current_ids & removable_ids) - desired_ids).each do |id|
        plan.debt_plan_accounts.where(account_id: id).destroy_all
      end
      plan.debt_plan_accounts.reload

      # Save through the plan so the liability / currency / family validations
      # fire — create! on debt_plan_accounts bypasses them.
      accounts.each do |account|
        attributes = link_attributes(account, overrides)
        existing = plan.debt_plan_accounts.find { |link| link.account_id == account.id }

        if existing
          existing.assign_attributes(attributes.except(:account))
        else
          plan.debt_plan_accounts.build(attributes)
        end
      end
      plan.save!
    end

    # { account_id => { apr:, minimum: } } from debt_plan[overrides].
    # A blank value means "no override" (NULL), not zero.
    def submitted_overrides
      raw = params.dig(:debt_plan, :overrides)
      return {} if raw.blank?

      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      hash.each_with_object({}) do |(account_id, values), memo|
        next unless values.respond_to?(:[])

        memo[account_id.to_s] = {
          apr: values["apr"].to_s.strip.presence,
          minimum: values["minimum"].to_s.strip.presence
        }
      end
    end
end
