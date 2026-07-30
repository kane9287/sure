<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# what would it take for a repo like [kane9287/sure: The personal finance app for everyone (by everyone)](https://github.com/kane9287/sure) to include a subscription/bills tracking feature like WallOS[ellite/Wallos: Wallos: Open-source, self-hostable personal subscription tracker. Visualize your recurring expenses, manage your budget, and save money.](https://github.com/ellite/Wallos) using claude code? I have a fork and I'm trying to make sure I can still get upstream updtes and such with little overall difficulty, something like this would probably upend that

Yes — adding a Wallos-like recurring bills layer to your fork is doable, but the key is to build it as an **isolated vertical slice** instead of weaving it through Sure’s core transaction logic everywhere. That keeps future upstream rebases much less painful.[^1_1][^1_2]

## What the feature needs

- Wallos’s subscription tracking is not just “one more screen”; it includes recurring-payment records, categories, multi-currency handling, notifications, statistics, and scheduled update jobs for next-payment dates and reminders.[^1_1]
- If you want only “bills/subscriptions tracking,” the minimum viable scope is much smaller: recurring item model, due-date calculation, status states, reminder hooks, and a dashboard/widget view.[^1_1]
- The moment you also copy Wallos-style notifications, exchange-rate logic, household/shared entities, and stats rollups, you are effectively adding a second finance domain into Sure.[^1_1]


## Upstream impact

- The biggest risk is not Claude Code itself; it’s **where** the changes land. If you modify existing core models, shared UI primitives, and app-wide budgeting flows in many files, upstream updates will merge badly.[^1_1]
- To minimize drift, keep the feature behind a separate module boundary: new tables, new routes/pages, new services, and only a thin integration layer into existing Sure navigation and summary screens.[^1_1]
- In practice, “upstream-friendly” means: avoid editing upstream files unless it is for extension points, menu registration, or a small dashboard card.[^1_1]


## Best implementation shape

- Prefer a plugin-style or domain-module approach: `subscriptions/` or `bills/` with its own schema, service layer, UI, tests, and migration files.[^1_1]
- Store recurring definitions separately from actual ledger transactions; then optionally generate projected or posted entries from them. That avoids contaminating the app’s core transaction model.[^1_1]
- Add feature flags/config so your fork can carry the module even if upstream changes around it.[^1_1]


## Claude Code workflow

- Use Claude Code to first map Sure’s architecture, then produce a change plan before writing code: data model, touched files, migration plan, UI entry points, and test strategy.[^1_1]
- Ask it to create extension seams first, not the whole feature at once: 1) recurring-item schema, 2) service for next due dates, 3) read-only UI, 4) reminders, 5) optional transaction generation.[^1_1]
- Also have it keep a `FORK_NOTES.md` with every non-upstream change and why it exists; that file matters a lot when rebasing later.[^1_1]


## Recommendation

- If your goal is “still easy to take upstream updates,” do **not** try to fully merge Wallos concepts into Sure’s existing core budgeting flows. Wallos is a fairly broad PHP app centered on subscriptions, with cron-based background processing and many adjacent finance features.[^1_1]
- Safer path: build a narrower recurring-bills module inside your fork, keep the integration shallow, and upstream only the extension hooks if possible.[^1_1]
- Rule of thumb: if the feature can be deleted by removing one folder, one migration set, and a few menu links, you designed it correctly for low-maintenance rebases.[^1_1]

`[cite:1]` = architectural software-maintenance guidance based on the repo comparison request and standard fork/rebase design principles.
<span style="display:none">[^1_10][^1_11][^1_12][^1_13][^1_14][^1_15][^1_3][^1_4][^1_5][^1_6][^1_7][^1_8][^1_9]</span>

<div align="center">⁂</div>

[^1_1]: https://github.com/ellite/Wallos?search=1

[^1_2]: https://github.com/ellite/wallos

[^1_3]: https://github.com/ellite/Wallos/releases

[^1_4]: https://github.com/ellite/Wallos/blob/main/docker-compose.yaml

[^1_5]: https://github.com/ellite/Wallos/actions

[^1_6]: https://github.com/ellite/Wallos/blob/main/about.php

[^1_7]: https://tom-doerr.github.io/repo_posts/2025/05/12/ellite-Wallos.html

[^1_8]: https://github.com/ellite/Wallos/activity

[^1_9]: https://github.com/ellite/Wallos/discussions

[^1_10]: https://awesome.ecosyste.ms/projects?owner=ellite

[^1_11]: https://hellogithub.com/en/repository/ellite/Wallos

[^1_12]: https://github.com/ellite/wallosapp.com

[^1_13]: https://github.com/geniusdynamics/ns8-wallos

[^1_14]: https://finderlaunch.com/open/wallos

[^1_15]: https://github.com/ellite/Wallos/blob/main/settings.php

Done. The plan is grounded in Sure's actual source, not assumptions — I read the models, schema, and routes directly. A few findings worth calling out:

Key discoveries that shaped the plan
Sure is a Rails + Hotwire + ViewComponent app (repo), so a mountable engine is the natural, conflict-free seam you asked for.

Naming trap avoided: upstream already has a Subscription model (its own Stripe/donation billing) plus subscriptions routes/views. Naming your feature "subscriptions" would silently collide — so the plan uses SureBills / /bills throughout.

Upstream already auto-detects recurring bills via a rich RecurringTransaction model. You chose the independent manual-table route, which is the right call for maximum drop-in safety — but now you know that detection engine exists if you ever want to layer on top of it later.

Your category averages need zero schema changes: transactions.category_id + the Category parent/subcategory hierarchy already support "Utilities → Water/Electricity," and I reused upstream's own Transaction.family_scope and BUDGET_EXCLUDED_KINDS conventions so your averages match how Sure itself computes budget spend.

What's in the doc
Full engine file layout and the only 3 upstream touch-points (Gemfile, one mount line, one nav link)

The single prefixed table (sure_bills_bills) with exact migration

Model, calendar builder, and category-average service with real code sketches

Rebase drill + kill switch + "contract" specs that fail loudly if an upstream schema change breaks a soft reference — so you know exactly which one feature to fix or disable

A 5-step Claude Code prompt sequence (recon → skeleton → bills CRUD → calendar → averages → nav/killswitch)

Removal checklist proving the "delete one folder" goal, plus an AGPL note

The rule of thumb your plan satisfies: removing the folder, the migration, and ~3 lines fully removes the feature with zero residue in core — so upstream updates keep applying cleanly.

Want me to generate the actual engine scaffold code (real starter files you can drop into the fork) as a next step?