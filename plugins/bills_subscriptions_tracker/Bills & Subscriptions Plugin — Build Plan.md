# Bills & Subscriptions Plugin — Build Plan

A drop-in **mountable Rails engine** that adds a bills/subscriptions calendar, a monthly bills list, and category-average costs to your fork of [Sure](https://github.com/we-promise/sure) — without touching upstream files or upstream schema.

---

## 1. Design decisions (locked in)

| Decision | Choice | Why it matters for upstream safety |
|---|---|---|
| **Data source** | Own manual `bills` table | Fully independent of upstream's `recurring_transactions` logic. If upstream changes recurring detection, your bills are unaffected. |
| **Integration seam** | Mountable Rails engine (`SureBills`) | Everything lives in one folder. Removal = delete folder + remove one `mount` line + drop one table. |
| **Category averages** | Pick a category (or enter a custom target value); average is computed over **all transactions in that category** | Reads existing `entries` + `transactions.category_id`. No schema change — computed live. |
| **Deliverable** | This build plan doc | You execute with Claude Code. |

**Naming note:** Do **not** call the engine or its routes `subscriptions` — upstream already has a `Subscription` model (Stripe/donation billing) and a `subscriptions` views/routes namespace. Collision would cause silent breakage. Use `SureBills` / `bills` throughout.

---

## 2. What upstream already gives you (confirmed from source)

Understanding these lets the plugin stay thin and read-only against core data:

- **`Entry`** (`app/models/entry.rb`) — the ledger row. Uses Rails `delegated_type :entryable`, so a `Transaction` is reached via `entry.entryable`. Key columns: `account_id`, `amount` (decimal 19,4), `currency`, `date`, `name`, `excluded`. Scope `Entry.visible` filters to active/draft accounts.
- **`Transaction`** (`app/models/transaction.rb`) — `belongs_to :category, optional: true`. Has `kind` enum. **`BUDGET_EXCLUDED_KINDS = %w[funds_movement one_time cc_payment]`** — exclude these for clean averages. `Transaction.family_scope(family)` joins `entry: :account` and scopes by family.
- **`Category`** (`app/models/category.rb`) — `belongs_to :family`; self-referential `parent_id` with `subcategories` and `scope :roots`. So your "Utilities → Water / Electricity" hierarchy already works. Categories are family-scoped.
- **`RecurringTransaction`** — a full auto-detection model (next-due dates, variance, active/inactive). **You are NOT depending on it**, but it's worth knowing it exists so you don't duplicate its UI unnecessarily. Your `bills` table is the manual, user-curated layer.
- **Multi-tenancy:** everything is scoped by `family`. `Current.family` and `Current.user` are the request-scoped accessors. Your engine must respect this.
- **Money:** upstream uses a `Monetizable` concern + `monetize :amount`. For an isolated engine you can format via the existing `Money` lib (`lib/money.rb`) or just render `amount` + `currency` to avoid coupling. Plan uses the light-touch approach.
- **UI stack:** Rails + Hotwire (Turbo/Stimulus) + ViewComponent (`app/components`) + Tailwind, with design tokens in `design/tokens`. Your engine ships plain ERB views styled with the same Tailwind classes so it looks native.
- **Schema version at time of planning:** `2026_07_14_120000`. All UUID primary keys (`gen_random_uuid()`).

---

## 3. Architecture: the `SureBills` engine

```
sure/
├── engines/
│   └── sure_bills/                      ← the entire plugin (delete = gone)
│       ├── sure_bills.gemspec
│       ├── lib/
│       │   ├── sure_bills.rb
│       │   └── sure_bills/
│       │       ├── engine.rb            ← isolate_namespace + config
│       │       └── version.rb
│       ├── config/
│       │   └── routes.rb                ← engine-internal routes
│       ├── app/
│       │   ├── controllers/sure_bills/
│       │   │   ├── application_controller.rb
│       │   │   ├── bills_controller.rb
│       │   │   ├── calendar_controller.rb
│       │   │   └── category_averages_controller.rb
│       │   ├── models/sure_bills/
│       │   │   └── bill.rb              ← the ONLY new table
│       │   ├── services/sure_bills/
│       │   │   ├── calendar_builder.rb
│       │   │   └── category_average_calculator.rb
│       │   ├── components/sure_bills/   ← optional ViewComponents
│       │   └── views/sure_bills/
│       │       ├── layouts/sure_bills/application.html.erb
│       │       ├── bills/
│       │       ├── calendar/
│       │       └── category_averages/
│       ├── db/migrate/
│       │   └── 20260720000000_create_sure_bills_bills.rb
│       └── spec/  (or test/)
```

### 3.1 Total upstream footprint (the whole point)

Only **three** touch-points on upstream files, all additive and one-line-ish:

1. **`Gemfile`** — add: `gem "sure_bills", path: "engines/sure_bills"`
2. **`config/routes.rb`** — add one line: `mount SureBills::Engine, at: "/bills"`
3. **Navigation** (optional) — one link in the sidebar partial to `/bills`. If you skip this, navigate by URL. This is the only edit to an upstream *view*; keep it in `FORK_NOTES.md`.

Everything else is inside `engines/sure_bills/`. **Removal procedure:** delete the folder, remove the Gemfile line, remove the mount line, remove the nav link, run the down-migration (or just drop `sure_bills_bills`). Zero residue in core.

### 3.2 Why an engine survives rebases

- Upstream never has files under `engines/sure_bills/`, so `git rebase`/`merge` produces **zero conflicts** there.
- The only conflict-prone spots are the 2–3 shared lines (Gemfile, routes.rb, nav). These are tiny, easy to re-apply, and documented in `FORK_NOTES.md`.
- Your table name is prefixed (`sure_bills_bills`) so it can never collide with an upstream migration.

---

## 4. The one new table

Isolated, prefixed, self-contained. It does **not** reference or alter any upstream table's structure — it only stores UUID references to `families`/`categories` (soft references; no FK to avoid coupling to upstream constraints, or with `on_delete: :nullify` if you prefer integrity — your call).

```ruby
# engines/sure_bills/db/migrate/20260720000000_create_sure_bills_bills.rb
class CreateSureBillsBills < ActiveRecord::Migration[7.2]
  def change
    create_table :sure_bills_bills, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :family_id,   null: false          # soft ref to families.id
      t.uuid    :category_id, null: true            # soft ref to categories.id (nullable)
      t.string  :name,        null: false
      t.decimal :amount,      precision: 19, scale: 4, null: false
      t.string  :currency,    null: false, default: "USD"
      t.string  :cadence,     null: false, default: "monthly"  # monthly|yearly|weekly|quarterly
      t.integer :due_day,     null: true            # day-of-month for monthly cadence (1..31)
      t.date    :first_due_on, null: true           # anchor for non-monthly cadences
      t.date    :ends_on,     null: true            # optional end
      t.boolean :active,      null: false, default: true
      t.text    :notes
      t.timestamps
    end

    add_index :sure_bills_bills, :family_id
    add_index :sure_bills_bills, [:family_id, :active]
    add_index :sure_bills_bills, :category_id
  end
end
```

> **Design principle you asked for:** if an upstream change ever breaks the join to `categories` (e.g. they rename the table), only the category-average and category-label features degrade — the bills list and calendar keep working because they don't depend on it. You can then fix or disable that one feature.

---

## 5. The model

```ruby
# engines/sure_bills/app/models/sure_bills/bill.rb
module SureBills
  class Bill < ApplicationRecord
    self.table_name = "sure_bills_bills"

    CADENCES = %w[weekly monthly quarterly yearly].freeze

    validates :name, :amount, :currency, :family_id, presence: true
    validates :cadence, inclusion: { in: CADENCES }
    validates :due_day, numericality: { only_integer: true,
              greater_than: 0, less_than_or_equal_to: 31 }, allow_nil: true

    scope :active,    -> { where(active: true) }
    scope :for_family, ->(family_id) { where(family_id: family_id) }

    # Soft association — resolved lazily, tolerant of upstream schema drift.
    def category
      return nil if category_id.blank?
      @category ||= ::Category.find_by(id: category_id)
    rescue ActiveRecord::StatementInvalid, NameError
      nil   # upstream Category changed/removed → degrade gracefully
    end

    # All due dates for this bill within [range_start, range_end].
    def occurrences_in(range_start, range_end)
      SureBills::CalendarBuilder.occurrences_for(self, range_start, range_end)
    end

    def monthly_normalized_amount
      case cadence
      when "weekly"    then amount * 52 / 12
      when "monthly"   then amount
      when "quarterly" then amount / 3
      when "yearly"    then amount / 12
      else amount
      end
    end
  end
end
```

`SureBills::ApplicationRecord` should inherit from the app's `::ApplicationRecord` so it shares the DB connection:

```ruby
# engines/sure_bills/app/models/sure_bills/application_record.rb
module SureBills
  class ApplicationRecord < ::ApplicationRecord
    self.abstract_class = true
  end
end
```

---

## 6. The three features

### 6.1 Bills calendar view

- **Route:** `GET /bills/calendar?month=2026-07`
- **Service `CalendarBuilder`:** given a month, expand each active bill's `cadence` + `due_day`/`first_due_on` into concrete dates within the month. Return a `{ Date => [bills...] }` map.
- **View:** a month grid (7 columns) rendered with the same Tailwind tokens Sure uses. Each day cell lists the bills due that day with amount + category color dot. Header shows month total and prev/next month links (Turbo Frame for snappy nav).
- **No dependency on ledger data** — this is purely your bills table, so it's the most robust feature.

**Cadence expansion logic (in `CalendarBuilder.occurrences_for`):**
- `monthly` → the `due_day` of each month (clamp to end-of-month for short months, mirroring upstream's `calculate_next_expected_date` fallback).
- `weekly` → every 7 days from `first_due_on`.
- `quarterly` → `first_due_on` + n×3 months.
- `yearly` → same month/day as `first_due_on` each year.
- Respect `ends_on` and `active`.

### 6.2 Monthly bills list

- **Route:** `GET /bills` (index)
- Shows all active bills for `Current.family`, grouped or sortable by category, with:
  - per-bill amount and cadence
  - `monthly_normalized_amount` so weekly/yearly bills are comparable
  - **month total** (sum of normalized amounts) — your "what do my recurring bills cost per month" number
- CRUD: `new/create/edit/update/destroy` all within the engine. Turbo forms for inline add/edit.

### 6.3 Category average costs

Your exact ask: pick a category (or type a custom target value), see the **average across all transactions in that category**.

- **Route:** `GET /bills/category_averages?category_id=...&months=6`
- **Service `CategoryAverageCalculator`:**

```ruby
# engines/sure_bills/app/services/sure_bills/category_average_calculator.rb
module SureBills
  class CategoryAverageCalculator
    # Average monthly spend for a category over the trailing `months` window,
    # using ALL transactions in that category (excluding transfer-like kinds).
    def self.average_monthly(family:, category_id:, months: 6, include_subcategories: true)
      category_ids = [category_id]
      if include_subcategories
        category_ids += ::Category.where(parent_id: category_id).pluck(:id)
      end

      start_date = months.months.ago.to_date.beginning_of_month

      # Reuse upstream's family scope + budget-exclusion convention.
      rel = ::Transaction
        .family_scope(family)                              # joins entry: :account, scopes family
        .where(category_id: category_ids)
        .where.not(kind: ::Transaction::BUDGET_EXCLUDED_KINDS)
        .where("entries.date >= ?", start_date)
        .where(entries: { excluded: false })

      total = rel.sum("entries.amount")                    # decimal, in family currency terms
      { total: total, months: months, average: (total / months) }
    end
  end
end
```

- **View:** a category picker (populated from `Current.family.categories.alphabetically_by_hierarchy`), a months selector (3/6/12), and the computed average. Add an optional free-text "target amount" input; render actual-vs-target delta.
- **Graceful degradation:** wrap the `::Transaction`/`::Category` calls so that if upstream renames a column, this view shows "unavailable — plugin needs update" instead of 500-ing, keeping the rest of the engine alive.

> Note on currency/`Money`: to stay decoupled, the calculator returns raw decimals in the account/entry currency and the view labels the currency. If you want proper multi-currency normalization, you can later call upstream's `Money`/`ExchangeRate` — but that adds coupling, so it's intentionally out of the drop-in scope.

---

## 7. Controllers & auth

The engine's base controller inherits from the host app's `ApplicationController` so you get sessions, `Current.family`, `Current.user`, and auth for free — without redefining any of it:

```ruby
# engines/sure_bills/app/controllers/sure_bills/application_controller.rb
module SureBills
  class ApplicationController < ::ApplicationController
    before_action :require_family!   # if upstream exposes such a guard; else rely on its authentication

    private

    def current_family
      Current.family
    end
    helper_method :current_family
  end
end
```

All queries scope to `current_family` (e.g. `SureBills::Bill.for_family(current_family.id)`), matching Sure's tenancy model. Never expose another family's bills.

`isolate_namespace SureBills` in `engine.rb` keeps routes, helpers, and table-name prefixing contained.

---

## 8. Rebase / upstream-update strategy

1. **Keep a `FORK_NOTES.md`** at repo root listing exactly the shared-file edits:
   - `Gemfile`: `gem "sure_bills", path: "engines/sure_bills"`
   - `config/routes.rb`: `mount SureBills::Engine, at: "/bills"`
   - nav partial: link to `/bills` (name the exact file + line context)
2. **Branch hygiene:** keep `main` tracking upstream; keep your work on a `bills-plugin` branch (or apply the 3 shared edits as a single, well-labeled commit you can cherry-pick). This makes re-applying after a rebase trivial.
3. **Rebase drill:**
   ```bash
   git fetch upstream
   git rebase upstream/main        # engine folder → zero conflicts
   # resolve only Gemfile / routes.rb / nav if they conflict (rare, tiny)
   bin/rails db:migrate            # your prefixed migration is untouched by upstream
   bin/rails test                  # run engine specs (see §9)
   ```
4. **Schema-drift smoke test:** the engine specs assert the soft references still resolve (`Category`, `Transaction.family_scope`, `entries.date`, `entries.excluded`, `Transaction::BUDGET_EXCLUDED_KINDS`). If upstream changes any, the test fails loudly and points you at the one file to fix — you disable/patch that feature without touching bills/calendar.
5. **Kill switch:** an ENV flag (`SURE_BILLS_ENABLED`) checked in the engine initializer + nav link, so you can disable the whole plugin instantly if a rebase breaks it, then fix at leisure.

---

## 9. Testing

- Put specs under `engines/sure_bills/spec/` (match upstream's framework — repo has both `spec/` and `test/`; check which is active and mirror it).
- **Model specs:** cadence expansion (esp. Feb/short-month clamping), `monthly_normalized_amount`, validations.
- **Service specs:** `CategoryAverageCalculator` excludes `BUDGET_EXCLUDED_KINDS` and `excluded` entries; includes subcategories.
- **Integration "contract" specs (critical for rebase safety):** assert the upstream APIs the engine leans on still exist — `::Category.roots`, `::Transaction.family_scope`, `Current.family`, `entries.date`, `entries.excluded`. These are your early-warning system.

---

## 10. Claude Code execution sequence

Run these as **separate, sequential** prompts. Have Claude map before it builds, and update `FORK_NOTES.md` after each step.

**Prompt 0 — Recon (no code):**
> "Map this Rails app's architecture relevant to a new mountable engine: how ApplicationController exposes Current.family/Current.user and authentication; the ViewComponent + Hotwire + Tailwind conventions and where design tokens live; how Category hierarchy and Transaction.family_scope work; and the active test framework (spec/ vs test/). Output a short findings doc. Do not write feature code yet."

**Prompt 1 — Engine skeleton + mount:**
> "Create a mountable Rails engine at engines/sure_bills with isolate_namespace SureBills, a gemspec, engine.rb, version.rb, an internal config/routes.rb, and a SureBills::ApplicationController inheriting from ::ApplicationController and a SureBills::ApplicationRecord inheriting from ::ApplicationRecord. Wire it up: add the gem to the root Gemfile (path: engines/sure_bills) and add `mount SureBills::Engine, at: '/bills'` to config/routes.rb. Create FORK_NOTES.md documenting every edit to a non-engine file. Boot the app and confirm /bills responds. Change no other upstream files."

**Prompt 2 — Bills table + model + CRUD:**
> "Add migration create_sure_bills_bills (columns per plan: family_id, category_id nullable, name, amount decimal 19,4, currency, cadence, due_day, first_due_on, ends_on, active, notes; uuid pk gen_random_uuid; indexes on family_id, [family_id,active], category_id). Build SureBills::Bill with validations, scopes (active, for_family), a soft `category` reader that rescues upstream drift, and monthly_normalized_amount. Build BillsController (index/new/create/edit/update/destroy) scoped to Current.family, with Turbo-friendly ERB views styled with the app's existing Tailwind classes. Do not add foreign keys to upstream tables. Add model specs."

**Prompt 3 — Calendar:**
> "Add SureBills::CalendarBuilder that expands a bill's cadence (weekly/monthly/quarterly/yearly) into concrete due dates within a given month, clamping monthly due_day to end-of-month for short months. Add CalendarController#show (param month=YYYY-MM), a month-grid ERB view with prev/next month via Turbo Frame, per-day bill chips with category color, and a month total. Add service specs including February edge cases."

**Prompt 4 — Category averages:**
> "Add SureBills::CategoryAverageCalculator.average_monthly(family:, category_id:, months:, include_subcategories:) that sums entries.amount for Transactions in the category (+ subcategories via Category.parent_id), excluding Transaction::BUDGET_EXCLUDED_KINDS and excluded entries, using Transaction.family_scope, over a trailing window; return total/months/average. Add CategoryAveragesController + view: a category picker from Current.family.categories.alphabetically_by_hierarchy, a 3/6/12-month selector, an optional free-text target amount with actual-vs-target delta. Wrap upstream calls to degrade gracefully if schema drifts. Add specs."

**Prompt 5 — Nav + kill switch + contract specs:**
> "Add one sidebar nav link to /bills (record it in FORK_NOTES.md). Add a SURE_BILLS_ENABLED env flag that hides the nav link and short-circuits the engine when false. Add integration 'contract' specs asserting the upstream APIs the engine depends on still exist (Category.roots, Transaction.family_scope, Current.family, entries.date, entries.excluded, Transaction::BUDGET_EXCLUDED_KINDS). Run the full engine suite."

---

## 11. Removal / disable checklist (proof of "drop-in")

To **disable** temporarily: set `SURE_BILLS_ENABLED=false`.

To **remove** entirely:
1. Delete `engines/sure_bills/`
2. Remove the Gemfile line
3. Remove the `mount SureBills::Engine` line
4. Remove the nav link
5. `bin/rails db:migrate` down the bills migration, or `DROP TABLE sure_bills_bills;`

No upstream model, schema, or logic was ever modified → upstream updates apply cleanly.

---

## 12. Licensing note (AGPL-3.0)

Sure is AGPL-3.0. If you ever distribute or network-serve your fork publicly, the engine code is a derivative work and must also be offered under AGPL-3.0 with source available. For a private self-hosted homelab instance this is a non-issue, but worth recording in `FORK_NOTES.md`.

---

### Sources
- Sure repo (stack, structure): https://github.com/we-promise/sure
- Entry model: https://github.com/we-promise/sure/blob/main/app/models/entry.rb
- Transaction model (kinds, family_scope, BUDGET_EXCLUDED_KINDS): https://github.com/we-promise/sure/blob/main/app/models/transaction.rb
- Category model (hierarchy, roots): https://github.com/we-promise/sure/blob/main/app/models/category.rb
- RecurringTransaction model: https://github.com/we-promise/sure/blob/main/app/models/recurring_transaction.rb
- Subscription model (naming-collision warning): https://github.com/we-promise/sure/blob/main/app/models/subscription.rb
- Schema: https://github.com/we-promise/sure/blob/main/db/schema.rb
- routes.rb (mount conventions): https://github.com/we-promise/sure/blob/main/config/routes.rb
