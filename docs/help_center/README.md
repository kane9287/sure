# Help Center (Alpha)

This is a plain-language help center for this fork of Sure. It's written to be read two ways:

1. **In the app later** — these files live in `docs/help_center/` so they can be wired into an in-app help page the same way `docs/onboarding/guide.md` already is (see `Settings::GuidesController` for the pattern).
2. **Right now, standalone** — you can open these files directly on GitHub, or just email/share the raw `.md` files with alpha testers. No app required.

Nothing here is fancy. It's written to be understood fast, not to look pretty.

## What this app is

A personal finance app for tracking accounts, transactions, and budgets in one place — checking/savings, credit cards, loans, investments, and manually-tracked assets like property. It supports both automatic bank syncing and fully manual entry.

## Who it's for

Right now: this fork's alpha testers. It's built for someone who wants a clear, real-time picture of their money without needing to be a spreadsheet person — but who's also willing to poke at unfinished software and say when something feels off.

## What it's not (yet)

- Not a polished, finished product — this is alpha software, expect rough edges (see [Known Limitations](05-known-limitations.md)).
- Not a replacement for your bank's own records — treat it as a view/planning layer on top of your accounts, not the source of truth for legal or tax purposes.
- Not multi-user-conflict-tested — if more than one person in a family is using it at the same time, unexpected overlaps are possible.

## Contents

1. [Getting Started](01-getting-started.md) — accounts, transactions, categories, syncing: the daily-use basics.
2. [Budgeting: Cap vs. Envelope](02-budgeting.md) — the two budgeting modes, how they differ, and which one to pick.
3. [Good Habits](03-good-habits.md) — how to use this app without stressing yourself out.
4. [Glossary](04-glossary.md) — every term used in the app, defined in one place.
5. [Known Limitations & Alpha Rules](05-known-limitations.md) — what not to rely on yet, and how to report issues.
6. [Alpha Feedback Template](feedback-template.md) — copy/paste this for each friction point you hit.

## A note for alpha testers

This app is under active development. Things will change, break, or look unfinished. If something in the app doesn't match what these docs say, the docs are probably out of date — not you. Flag it and we'll fix it. See [Known Limitations & Alpha Rules](05-known-limitations.md) for how to send that feedback.

See also: [`docs/onboarding/guide.md`](../onboarding/guide.md) for the original upstream walkthrough of account creation, which covers some of the same ground as [Getting Started](01-getting-started.md) in more visual detail (with screenshots).
