# Known Limitations & Alpha Rules

This app is genuinely alpha-quality right now. This page is about setting expectations so nothing here catches you off guard.

## What not to rely on yet

- **Don't treat this as your source of truth for taxes or legal records.** Use it for planning and visibility, but keep your bank/broker statements as the real record.
- **Manual accounts drift.** If you're not connecting an account to a provider, its balance is only as accurate as your last manual update. See [Good Habits](03-good-habits.md) for how to fix drift without stress.
- **Investment cost basis can be approximate.** If a connected provider's cost basis data looks off, you can manually override it — manual entries always take priority over calculated or provider values.
- **Multi-user use isn't heavily tested.** If more than one person in the family is editing the same account/transaction at the same time, unexpected overlaps are possible.
- **Features may be half-built or change shape entirely.** If something feels incomplete, it probably is — that's expected during alpha, not a sign of a "real" bug (though tell us anyway — see below).

## What syncing actually means

"Syncing" means the app asks a connected provider (like Plaid or SimpleFIN) for your latest balances and transactions and imports them. A few things worth knowing:

- Syncing isn't always instant — it can take a few minutes, especially right after linking a new account.
- Providers occasionally report **pending** transactions that later change slightly (amount, merchant name, date) once they fully post. That's the provider, not this app, being imprecise.
- If a sync fails or a provider has an outage, the app won't invent data — you'll just see stale balances until the next successful sync (or you can trigger one manually from the account page).

## How to report issues (alpha)

While this is a private alpha, don't file a public GitHub issue — just send feedback directly to whoever invited you to test (text, email, whatever's easiest). Use the [Alpha Feedback Template](feedback-template.md) so the report is quick to act on:

1. **Use the app for real** — real spending, real accounts (or a sandbox account if you'd rather not connect real ones yet).
2. **Note every moment of hesitation, confusion, or "why did it do that?"** — even small ones. Those moments are the most valuable signal in an alpha.
3. **Submit one short feedback item per friction point.** Don't batch a dozen things into one giant message — one clear item is easier to act on than a wall of text.
