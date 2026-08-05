class Family < ApplicationRecord
  include Syncable, AutoTransferMatchable, Subscribeable, VectorSearchable
  include PlaidConnectable, SimplefinConnectable, LunchflowConnectable, AkahuConnectable, EnableBankingConnectable
  include CoinbaseConnectable, BinanceConnectable, KrakenConnectable, CoinstatsConnectable, SnaptradeConnectable, MercuryConnectable, BrexConnectable, SophtronConnectable
  include IndexaCapitalConnectable, IbkrConnectable, WiseConnectable
  include UpConnectable
  include Trading212Connectable
  include QuestradeConnectable
  include RedbarkConnectable

  DATE_FORMATS = [
    [ "MM-DD-YYYY", "%m-%d-%Y" ],
    [ "DD.MM.YYYY", "%d.%m.%Y" ],
    [ "DD-MM-YYYY", "%d-%m-%Y" ],
    [ "YYYY-MM-DD", "%Y-%m-%d" ],
    [ "DD/MM/YYYY", "%d/%m/%Y" ],
    [ "YYYY/MM/DD", "%Y/%m/%d" ],
    [ "MM/DD/YYYY", "%m/%d/%Y" ],
    [ "D/MM/YYYY", "%e/%m/%Y" ],
    [ "YYYY.MM.DD", "%Y.%m.%d" ],
    [ "YYYYMMDD", "%Y%m%d" ],
    # QIF month-name imports rely on QifParser preserving normalized spaces.
    [ "DD MMM YYYY", "%d %b %Y" ]
  ].freeze


  MONIKERS = [ "Family", "Group" ].freeze
  ASSISTANT_TYPES = %w[builtin external].freeze
  SHARING_DEFAULTS = %w[shared private].freeze

  has_many :users, dependent: :destroy
  has_many :accounts, dependent: :destroy
  has_many :invitations, dependent: :destroy

  has_many :imports, dependent: :destroy
  has_many :import_sessions, dependent: :destroy
  has_many :import_source_mappings, dependent: :destroy
  has_many :family_exports, dependent: :destroy
  has_many :account_statements, dependent: :destroy

  has_many :entries, through: :accounts
  has_many :transactions, through: :accounts
  has_many :rules, dependent: :destroy
  has_many :trades, through: :accounts
  has_many :holdings, through: :accounts

  has_many :tags, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :merchants, dependent: :destroy, class_name: "FamilyMerchant"

  has_many :budgets, dependent: :destroy
  has_many :budget_categories, through: :budgets
  has_many :budget_allocations, dependent: :destroy

  has_many :goals, dependent: :destroy
  has_many :debt_plans, dependent: :destroy

  # Net inflow into every depository account linked to any primary-currency
  # goal, over the given window. Transfers between linked accounts net to zero
  # because both sides of an internal move land inside the same account set;
  # external transfers (e.g. checking → linked savings) net positive.
  #
  # Scoped to the family's primary currency: mixed-currency families would
  # otherwise sum raw EUR + USD numbers and surface the result as primary.
  # Foreign-currency goals are excluded from this KPI until FX conversion is
  # added.
  #
  # Entry amount convention in Sure: inflow is negative, so flip the sign.
  # Result is allowed to go negative (net outflow last 30d) so the headline
  # reflects reality; the controller decides how to render.
  def savings_inflow_velocity(range: 30.days.ago.to_date..Date.current, account_ids: nil)
    ids = account_ids || goal_linked_account_ids
    return 0 if ids.empty?

    net = Entry
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(account_id: ids, date: range)
      .where(excluded: false)
      .merge(Transaction.excluding_pending)
      .sum(:amount)

    -net.to_d
  end

  # Two velocity windows in a single pair of sums that share one
  # account-id lookup. The kpi tile on the index reads both the current
  # 30d window and the prior 30d window; without this helper the
  # `accounts.joins(:goal_accounts)…pluck(:id)` query runs twice per
  # request even though the answer is identical.
  def savings_inflow_windows(window_days: 30, now: Date.current)
    ids = goal_linked_account_ids
    {
      current: savings_inflow_velocity(range: (now - window_days)..now, account_ids: ids),
      prior:   savings_inflow_velocity(range: (now - 2 * window_days)..(now - window_days - 1), account_ids: ids)
    }
  end

  private

    # Depository accounts linked to this family's goals, restricted to the
    # primary currency until FX is added. Memoized for the lifetime of the
    # Family instance so a single request that reads velocity twice (the
    # KPI tile uses current vs prior 30d) doesn't re-run the join+pluck.
    # `accounts` is already scoped by the has_many association, and the
    # join restricts to this family's goals — so cross-family bleed
    # remains impossible.
    def goal_linked_account_ids
      @goal_linked_account_ids ||= accounts
        .joins(:goal_accounts)
        .where(goal_accounts: { goal_id: goals.select(:id) })
        .where(currency: primary_currency_code)
        .distinct
        .pluck(:id)
    end

  public

  has_many :llm_usages, dependent: :destroy
  has_many :recurring_transactions, dependent: :destroy
  has_many :insights, dependent: :destroy
  has_many :transaction_reconciliations, dependent: :destroy

  # Families with at least one opted-in member. Lets a job filter in one
  # indexed query rather than loading every family and asking each in Ruby.
  scope :with_preview_features, -> { where(id: User.with_preview_features.select(:family_id)) }

  # Family-level rollup of the per-user preview flag, for callers that run
  # without a Current.user (the nightly insights job). Preview access is a
  # personal preference but the data it produces is family-scoped, so one
  # opted-in member is enough to generate for the family.
  #
  # EXISTS rather than `users.any?(&:preview_features_enabled?)`: the job asks
  # this once per family, and the block form would load and instantiate every
  # member just to answer a boolean.
  #
  # Never gate UI on this — visibility is per-user, and this answers "somebody
  # in the household opted in", so a view using it would show the feature to a
  # user who explicitly opted out. Use the PreviewGateable helper (Current.user)
  # for anything a person sees.
  def preview_features_enabled?
    users.with_preview_features.exists?
  end

  BUDGET_MODES = %w[cap envelope].freeze

  # Gates whether provider syncs try to reconcile against manual point-of-sale
  # captures, and how far they may go without asking. Distinct from the preview
  # flag, which is per-user and gates visibility: auto-merge mutates data the
  # whole household shares, so one member opting into preview must not silently
  # rewrite another member's entries.
  MANUAL_RECONCILIATION_MODES = %w[off review_only auto].freeze

  validates :locale, inclusion: { in: I18n.available_locales.map(&:to_s) }
  validates :date_format, inclusion: { in: DATE_FORMATS.map(&:last) }
  validates :month_start_day, inclusion: { in: 1..28 }
  validates :moniker, inclusion: { in: MONIKERS }
  validates :assistant_type, inclusion: { in: ASSISTANT_TYPES }
  validates :default_account_sharing, inclusion: { in: SHARING_DEFAULTS }
  validates :budget_mode, inclusion: { in: BUDGET_MODES }
  validates :manual_reconciliation_mode, inclusion: { in: MANUAL_RECONCILIATION_MODES }

  before_validation :normalize_enabled_currencies!
  before_save :snapshot_envelope_activation!
  # after_save, not activate_envelope_mode! — that method isn't on any UI path.
  # The only way a user reaches envelope mode is the settings select, which
  # mass-assigns budget_mode through Family#update.
  after_save :ensure_envelope_system_categories!, if: :should_create_envelope_system_categories?

  def primary_currency_code
    normalize_currency_code(currency) || "USD"
  end

  def custom_enabled_currencies?
    enabled_currencies.present?
  end

  def enabled_currency_codes(extra: [])
    selected_codes = if custom_enabled_currencies?
      [ primary_currency_code, *Array(enabled_currencies) ]
    else
      Money::Currency.as_options.map(&:iso_code)
    end

    normalize_currency_codes([ *selected_codes, *Array(extra) ])
  end

  def enabled_currency_objects(extra: [])
    enabled_currency_codes(extra:).map { |code| Money::Currency.new(code) }
  end

  def secondary_enabled_currency_objects(extra: [])
    enabled_currency_objects(extra:).reject { |currency| currency.iso_code == primary_currency_code }
  end


  def moniker_label
    case moniker.presence
    when nil, "Family"
      I18n.t("shared.family_moniker.singular", default: "Family")
    when "Group"
      I18n.t("shared.family_moniker.group_singular", default: "Group")
    else
      moniker
    end
  end

  def moniker_label_plural
    case moniker.presence
    when nil, "Family"
      I18n.t("shared.family_moniker.plural", default: "Families")
    when "Group"
      I18n.t("shared.family_moniker.group_plural", default: "Groups")
    else
      "#{moniker}s"
    end
  end

  def share_all_by_default?
    default_account_sharing == "shared"
  end

  # Shares every existing account in this family (except ones the user already
  # owns) with the given user, honoring the family's default sharing policy and
  # the user's role. Guests receive read_only; members/admins receive read_write.
  #
  # This is the single entry point for "a member just joined, give them the
  # accounts the family shares by default." It self-guards on the sharing policy
  # and family membership so every membership path (invitation accept, SSO JIT
  # sign-up, token registration, mobile SSO) can call it without reintroducing
  # the "member joined but sees nothing" bug. No-op when sharing is disabled or
  # there is nothing to share, and idempotent on re-run.
  def auto_share_existing_accounts_with(user)
    return unless share_all_by_default?
    # Load-bearing security guard: insert_all below bypasses AccountShare's
    # user_in_same_family / cannot_share_with_owner validations, so this
    # membership check is the ONLY thing preventing cross-family sharing.
    # Do not drop it when refactoring.
    return unless user&.persisted? && user.family_id == id

    permission = user.guest? ? "read_only" : "read_write"
    records = accounts.where.not(owner_id: user.id).pluck(:id).map do |account_id|
      { account_id: account_id, user_id: user.id, permission: permission,
        include_in_finances: true, created_at: Time.current, updated_at: Time.current }
    end

    AccountShare.insert_all(records, unique_by: %i[account_id user_id]) if records.any?
  end

  def envelope_mode?
    budget_mode == "envelope"
  end

  def cap_mode?
    budget_mode == "cap"
  end

  # Switches the family into envelope mode. Idempotent on the activation
  # date: re-activating after a trip back to cap mode resumes the existing
  # rolling balances instead of re-snapshotting, since nothing about
  # allocations/spend was destroyed while cap mode was active (see
  # BudgetAllocation, Family#envelope_balances_by_category). The activation
  # date itself is stamped by the snapshot_envelope_activation! callback so
  # any save path that flips budget_mode (including the generic settings
  # form's mass-assignment) gets the same safe behavior.
  def activate_envelope_mode!
    update!(budget_mode: "envelope")
  end

  def deactivate_envelope_mode!
    update!(budget_mode: "cap")
  end

  # The built-in envelope that holds cash against money already spent on credit.
  # Self-healing find-or-create rather than a backfill migration: families
  # already in envelope mode when this shipped get theirs on the next budget
  # page load (see Budget.find_or_bootstrap).
  def debt_payment_category
    @debt_payment_category ||= find_or_create_system_category("debt_payment")
  end

  # Creates any system categories envelope mode depends on. Idempotent.
  def ensure_envelope_system_categories!
    debt_payment_category
  end

  # The family's cash not yet assigned to an envelope: cash in in-budget
  # accounts, minus every envelope's rolling balance (negative balances reduce
  # the pool the same way positive ones reserve from it — see
  # envelope_balances_by_category). Nothing else subtracts from it; in
  # particular goals never withhold cash on their own, they claim it by being
  # funded into an envelope like everything else. Only meaningful in envelope
  # mode; nil otherwise so callers don't mistake a cap-mode family's $0 for
  # "fully assigned."
  def unassigned_pool_balance
    return nil unless envelope_mode?

    reserved_in_envelopes = envelope_balances_by_category.values.sum

    Money.new(in_budget_cash_balance.amount - reserved_in_envelopes, primary_currency_code)
  end

  def in_budget_accounts
    accounts.where(accountable_type: "Depository", in_budget: true, status: "active")
  end

  # Total cash sitting in this family's in-budget accounts, restricted to the
  # primary currency (same caveat as savings_inflow_velocity: mixed-currency
  # families would otherwise sum raw EUR + USD figures). Exposed publicly so
  # views can show it alongside unassigned_pool_balance without duplicating
  # the query — this is the real, self-reconciling number that Unassigned is
  # derived from (not a projected/expected income figure).
  def in_budget_cash_balance
    Money.new(in_budget_accounts.where(currency: primary_currency_code).sum(:balance), primary_currency_code)
  end

  # Each envelope category's rolling available-to-spend balance since
  # envelope_activated_on: net funded (BudgetAllocation fund - sweep) minus
  # net actual spend, over the whole span — not clamped at zero. A negative
  # balance is exactly what makes an overspend reduce unassigned_pool_balance
  # (see above) without needing a separate period-end sweep step: the
  # identity cash == unassigned + sum(envelope balances) holds continuously.
  #
  # Memoized per instance (cleared by reset_envelope_caches!) so rendering
  # every category on the budget page fires two queries total, not two per
  # category.
  def envelope_balances_by_category
    envelope_category_math[:balances]
  end

  # Each category's cumulative net funding (fund - sweep) since activation.
  # Same memoized pass as envelope_balances_by_category. The UI's "Assigned"
  # figure is the per-period one (BudgetCategory#envelope_assigned); this is
  # the lifetime total behind it.
  def envelope_assigned_by_category
    envelope_category_math[:assigned]
  end

  # The Debt Payment envelope's balance: cash held against credit purchases
  # already made, plus anything assigned toward paying debt down. Zero for a
  # family that never uses credit, and negative when card payments have gone
  # out that nothing was assigned for — the same overspend semantics as any
  # other envelope. See IncomeStatement::LiabilityReserve.
  def debt_reserve
    return Money.new(0, primary_currency_code) unless envelope_mode?

    Money.new(envelope_balances_by_category.fetch(debt_payment_category.id, 0), primary_currency_code)
  end

  def reset_envelope_caches!
    remove_instance_variable(:@envelope_category_math) if instance_variable_defined?(:@envelope_category_math)
    remove_instance_variable(:@child_category_ids_by_parent) if instance_variable_defined?(:@child_category_ids_by_parent)
  end

  private
    def envelope_category_math
      @envelope_category_math ||= begin
        activation = envelope_activated_on

        if activation.nil?
          { balances: Hash.new(0), assigned: Hash.new(0) }
        else
          period = Period.custom(start_date: activation, end_date: Date.current)
          # Defaults to Current.user, same as every other Family/Budget income
          # statement read in this app — scoped to what the viewing member can
          # see (see CLAUDE.md: use Current.user, not an explicit override).
          statement = income_statement
          allocated = budget_allocations.since(activation).group(:category_id).sum(:amount)
          expense_by_cat = statement.expense_totals(period: period).category_totals.index_by { |ct| ct.category.id }
          income_by_cat = statement.income_totals(period: period).category_totals.index_by { |ct| ct.category.id }

          # Cash owed on cards for purchases already made. Held in the built-in
          # Debt Payment envelope so the spending envelope's drop at swipe time
          # is offset and the Unassigned pool doesn't grow; the reserve then
          # drains at the same rate cash leaves when the card is paid.
          reserve = statement.liability_reserve_total(period: period)
          debt_id = debt_payment_category.id

          category_ids = (allocated.keys + expense_by_cat.keys + income_by_cat.keys + [ debt_id ]).compact.uniq
          balances = Hash.new(0)
          assigned = Hash.new(0)

          # A parent's CategoryTotal#total is own + children (see
          # IncomeStatement#build_period_total). PeriodTotal#total compensates by
          # rejecting subcategories, but envelopes are per-category, so without
          # subtracting children back out a subcategory's spend would drain two
          # envelopes and invent the difference in the Unassigned pool.
          own = ->(totals_by_cat, category_id) {
            total = (totals_by_cat[category_id]&.total || 0).to_d
            child_category_ids_by_parent[category_id].each do |child_id|
              total -= (totals_by_cat[child_id]&.total || 0).to_d
            end
            total
          }

          category_ids.each do |category_id|
            funded = (allocated[category_id] || 0).to_d
            spent = own.call(expense_by_cat, category_id)
            refunded = own.call(income_by_cat, category_id)
            # Additive, and deliberately outside the clamp below: the reserve
            # must be free to go negative (a card refund with no offsetting
            # charge, or a payment against debt that predates activation) or
            # Unassigned stops tracking cash.
            debt = category_id == debt_id ? reserve : BigDecimal(0)
            assigned[category_id] = funded
            balances[category_id] = funded + debt - [ spent - refunded, 0 ].max
          end

          { balances: balances, assigned: assigned }
        end
      end
    end

    # Child category ids keyed by parent id, defaulting to an empty list so
    # callers can iterate without a nil check. Loaded once per instance
    # alongside the rest of the envelope math.
    def child_category_ids_by_parent
      @child_category_ids_by_parent ||= categories.where.not(parent_id: nil)
                                                  .pluck(:parent_id, :id)
                                                  .group_by(&:first)
                                                  .transform_values { |pairs| pairs.map(&:last) }
                                                  .tap { |h| h.default = [].freeze }
    end
  public

  def uses_custom_month_start?
    month_start_day != 1
  end

  def custom_month_start_for(date)
    if date.day >= month_start_day
      Date.new(date.year, date.month, month_start_day)
    else
      previous_month = date - 1.month
      Date.new(previous_month.year, previous_month.month, month_start_day)
    end
  end

  def custom_month_end_for(date)
    start_date = custom_month_start_for(date)
    next_month_start = start_date + 1.month
    next_month_start - 1.day
  end

  def current_custom_month_period
    start_date = custom_month_start_for(Date.current)
    end_date = custom_month_end_for(Date.current)
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def assigned_merchants
    merchant_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    Merchant.where(id: merchant_ids)
  end

  def available_merchants
    assigned_ids = transactions.where.not(merchant_id: nil).pluck(:merchant_id).uniq
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: self)
      .recently_unlinked
      .pluck(:merchant_id)
    family_merchant_ids = merchants.pluck(:id)
    Merchant.where(id: (assigned_ids + recently_unlinked_ids + family_merchant_ids).uniq)
  end

  def assigned_merchants_for(user)
    merchant_ids = Transaction.joins(:entry)
      .where(entries: { account_id: accounts.accessible_by(user).select(:id) })
      .where.not(merchant_id: nil)
      .distinct
      .pluck(:merchant_id)
    Merchant.where(id: merchant_ids)
  end

  def available_merchants_for(user)
    assigned_ids = Transaction.joins(:entry)
      .where(entries: { account_id: accounts.accessible_by(user).select(:id) })
      .where.not(merchant_id: nil)
      .distinct
      .pluck(:merchant_id)
    recently_unlinked_ids = FamilyMerchantAssociation
      .where(family: self)
      .recently_unlinked
      .pluck(:merchant_id)
    family_merchant_ids = merchants.pluck(:id)
    Merchant.where(id: (assigned_ids + recently_unlinked_ids + family_merchant_ids).uniq)
  end

  def auto_categorize_transactions_later(transactions, rule_run_id: nil)
    AutoCategorizeJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  def auto_categorize_transactions(transaction_ids)
    AutoCategorizer.new(self, transaction_ids: transaction_ids).auto_categorize
  end

  def auto_detect_transaction_merchants_later(transactions, rule_run_id: nil)
    AutoDetectMerchantsJob.perform_later(self, transaction_ids: transactions.pluck(:id), rule_run_id: rule_run_id)
  end

  def auto_detect_transaction_merchants(transaction_ids)
    AutoMerchantDetector.new(self, transaction_ids: transaction_ids).auto_detect
  end

  def balance_sheet(user: Current.user)
    BalanceSheet.new(self, user: user)
  end

  def income_statement(user: Current.user)
    IncomeStatement.new(self, user: user)
  end

  # Returns the Investment Contributions category for this family, creating it if it doesn't exist.
  # This is used for auto-categorizing transfers to investment accounts.
  # Always uses the family's locale to ensure consistent category naming across all users.
  def investment_contributions_category
    # Find ALL legacy categories (created under old request-locale behavior)
    legacy = categories.where(name: Category.all_investment_contributions_names).order(:created_at).to_a

    if legacy.any?
      keeper = legacy.first
      duplicates = legacy[1..]

      # Reassign transactions and subcategories from duplicates to keeper
      if duplicates.any?
        duplicate_ids = duplicates.map(&:id)
        categories.where(parent_id: duplicate_ids).update_all(parent_id: keeper.id)
        Transaction.where(category_id: duplicate_ids).update_all(category_id: keeper.id)
        BudgetCategory.where(category_id: duplicate_ids).update_all(category_id: keeper.id)
        categories.where(id: duplicate_ids).delete_all
      end

      # Rename keeper to family's locale name if needed
      I18n.with_locale(locale) do
        correct_name = Category.investment_contributions_name
        keeper.update!(name: correct_name) unless keeper.name == correct_name
      end
      return keeper
    end

    # Create new category using family's locale
    I18n.with_locale(locale) do
      categories.find_or_create_by!(name: Category.investment_contributions_name) do |cat|
        cat.color = "#0d9488"
        cat.lucide_icon = "trending-up"
      end
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Handle race condition: another process created the category
    I18n.with_locale(locale) do
      categories.find_by!(name: Category.investment_contributions_name)
    end
  end

  # Returns account IDs for tax-advantaged accounts (401k, IRA, HSA, etc.)
  # Used to exclude these accounts from budget/cashflow calculations.
  # Tax-advantaged accounts are retirement savings, not daily expenses.
  def tax_advantaged_account_ids
    @tax_advantaged_account_ids ||= begin
      # Investment accounts derive tax_treatment from subtype
      tax_advantaged_subtypes = Investment::SUBTYPES.select do |_, meta|
        meta[:tax_treatment].in?(%i[tax_deferred tax_exempt tax_advantaged])
      end.keys

      investment_ids = accounts
        .joins("INNER JOIN investments ON investments.id = accounts.accountable_id AND accounts.accountable_type = 'Investment'")
        .where(investments: { subtype: tax_advantaged_subtypes })
        .pluck(:id)

      # Crypto accounts have an explicit tax_treatment column
      crypto_ids = accounts
        .joins("INNER JOIN cryptos ON cryptos.id = accounts.accountable_id AND accounts.accountable_type = 'Crypto'")
        .where(cryptos: { tax_treatment: %w[tax_deferred tax_exempt] })
        .pluck(:id)

      investment_ids + crypto_ids + tax_advantaged_depository_account_ids
    end
  end

  def investment_statement(user: Current.user)
    InvestmentStatement.new(self, user: user)
  end

  def eu?
    country != "US" && country != "CA"
  end

  def requires_securities_data_provider?
    # If family has any trades, they need a provider for historical prices
    trades.any?
  end

  def requires_exchange_rates_data_provider?
    # If family has any accounts not denominated in the family's currency, they need a provider for historical exchange rates
    return true if accounts.where.not(currency: self.currency).any?

    # If family has any entries in different currencies, they need a provider for historical exchange rates
    uniq_currencies = entries.pluck(:currency).uniq
    return true if uniq_currencies.count > 1
    return true if uniq_currencies.count > 0 && uniq_currencies.first != self.currency

    false
  end

  def missing_data_provider?
    (requires_securities_data_provider? && Security.provider.nil?) ||
    (requires_exchange_rates_data_provider? && ExchangeRate.provider.nil?)
  end

  # Returns securities with plan restrictions for a specific provider
  # @param provider [String] The provider name (e.g., "TwelveData")
  # @return [Array<Hash>] Array of hashes with ticker, name, required_plan, provider
  def securities_with_plan_restrictions(provider:)
    security_ids = trades.joins(:security).pluck("securities.id").uniq
    return [] if security_ids.empty?

    restrictions = Security.plan_restrictions_for(security_ids, provider: provider)
    return [] if restrictions.empty?

    Security.where(id: restrictions.keys).map do |security|
      restriction = restrictions[security.id]
      {
        ticker: security.ticker,
        name: security.name,
        required_plan: restriction[:required_plan],
        provider: restriction[:provider]
      }
    end
  end

  def oldest_entry_date
    entries.order(:date).first&.date || Date.current
  end

  # Used for invalidating family / balance sheet related aggregation queries
  def build_cache_key(key, invalidate_on_data_updates: false)
    # Our data sync process updates this timestamp whenever any family account successfully completes a data update.
    # By including it in the cache key, we can expire caches every time family account data changes.
    data_invalidation_key = invalidate_on_data_updates ? latest_sync_completed_at : nil

    [
      id,
      key,
      data_invalidation_key,
      accounts.maximum(:updated_at)
    ].compact.join("_")
  end

  # Used for invalidating entry related aggregation queries
  def entries_cache_version
    @entries_cache_version ||= begin
      ts = entries.maximum(:updated_at)
      ts.present? ? ts.to_i : 0
    end
  end

  def self_hoster?
    Rails.application.config.app_mode.self_hosted?
  end

  private
    # Mirrors the inline `investment_ids` / `crypto_ids` SQL blocks in
    # `tax_advantaged_account_ids`. Joins `depositories` and filters by
    # `Depository::TAX_ADVANTAGED_SUBTYPES` (currently `%w[hsa]`). Extracted
    # rather than inlined because the existing two blocks are already long
    # enough; the extraction keeps `tax_advantaged_account_ids` readable.
    def tax_advantaged_depository_account_ids
      accounts
        .joins("INNER JOIN depositories ON depositories.id = accounts.accountable_id AND accounts.accountable_type = 'Depository'")
        .where(depositories: { subtype: Depository::TAX_ADVANTAGED_SUBTYPES })
        .pluck(:id)
    end

    # Stamps envelope_activated_on the first time budget_mode becomes
    # "envelope", regardless of which save path triggered it (explicit
    # activate_envelope_mode!, or the settings form's generic
    # family_attributes mass-assignment). Leaves the date alone on every
    # later save so re-entering envelope mode after a trip back to cap mode
    # resumes existing rolling balances instead of re-snapshotting.
    def snapshot_envelope_activation!
      self.envelope_activated_on = Date.current if budget_mode == "envelope" && envelope_activated_on.blank?
    end

    def should_create_envelope_system_categories?
      persisted? && envelope_mode? && saved_change_to_budget_mode?
    end

    # Looked up by system_key, never by name — the name is a fallback for old
    # data and raw SQL, while everything user-facing renders display_name from
    # i18n. The stored name is only disambiguated because Category still has a
    # per-family uniqueness validation on it and the user may already own a
    # category with the same label.
    def find_or_create_system_category(key)
      existing = categories.find_by(system_key: key)
      return existing if existing

      config = Category::SYSTEM_KEYS.fetch(key)

      I18n.with_locale(locale) do
        categories.create!(
          system_key: key,
          name: available_category_name(I18n.t(config[:name_key])),
          color: config[:color],
          lucide_icon: config[:lucide_icon]
        )
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # Another request created it between the find and the create.
      categories.find_by!(system_key: key)
    end

    def available_category_name(preferred)
      return preferred unless categories.exists?(name: preferred)

      (2..).each do |n|
        candidate = "#{preferred} (#{n})"
        return candidate unless categories.exists?(name: candidate)
      end
    end

    def normalize_enabled_currencies!
      if enabled_currencies.blank?
        self.enabled_currencies = nil
        return
      end

      normalized_codes = normalize_currency_codes([ primary_currency_code, *Array(enabled_currencies) ])
      all_codes = Money::Currency.as_options.map(&:iso_code)
      all_selected = normalized_codes.size == all_codes.size && (normalized_codes - all_codes).empty?
      self.enabled_currencies = all_selected ? nil : normalized_codes
    end

    def normalize_currency_codes(values)
      Array(values).filter_map { |value| normalize_currency_code(value) }.uniq
    end

    def normalize_currency_code(value)
      return if value.blank?

      Money::Currency.new(value).iso_code
    rescue Money::Currency::UnknownCurrencyError, ArgumentError
      nil
    end
end
