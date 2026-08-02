# Getting Started

The short version: **Accounts** hold your money. **Transactions** move money in, out, or between accounts. **Categories** describe what a transaction was for. Everything else in the app is built on top of those three things.

## 1. Accounts

An account is anything with a balance: a checking account, a credit card, a loan, an investment account, even a house.

Accounts come in two flavors:

| Type | Examples | Balance means... |
|---|---|---|
| **Asset** | Checking, savings, investments, crypto, property, vehicles | Money/value you have |
| **Liability** | Credit cards, loans, mortgages | Money you owe |

For asset accounts, spending money lowers the balance and income raises it — that's intuitive. Liability accounts work backwards on purpose: a **positive** balance on a credit card means you owe that much. A new purchase *increases* what you owe (the balance goes up), and a payment *decreases* it (the balance goes down). It feels weird at first, but it matches how the bank thinks about it.

You can add accounts two ways:
- **Manually** — you type in the balance and update it yourself over time.
- **Connected** — linked to a real bank/provider (Plaid, SimpleFIN, etc.) so balances and transactions sync automatically.

Manual accounts are totally fine for alpha testing. Connected accounts save you data entry but depend on outside providers, which can occasionally lag or hiccup — see [Good Habits](03-good-habits.md) for what to do when that happens.

## 2. Transactions

A transaction is a single movement of money. There are three kinds:

- **Expense** — money leaving an account (a purchase, a bill).
- **Income** — money entering an account (a paycheck, a refund).
- **Transfer** — money moving between two of *your own* accounts (paying off a credit card from checking, moving to savings). Transfers don't count as income or spending — they're just money changing pockets.

You can add transactions by hand, or they'll show up automatically for connected accounts.

## 3. Categories & Tags

**Categories** answer "what was this for?" (Groceries, Rent, Dining, Paycheck, etc.). Every expense/income transaction should ideally have one — it's what makes budgeting and reporting useful. If something doesn't have a category yet, it just shows up as **Uncategorized** — that's a normal, temporary state, not an error.

**Tags** are optional extra labels you can stack on top of categories (e.g. tagging a handful of transactions across different categories as "Vacation 2026" or "Tax Deductible"). Use them when one category isn't enough to describe something.

**Rules** let you automate categorization — e.g. "any transaction from Starbucks → Dining" gets applied automatically going forward, and can be back-applied to past transactions too.

## 4. Recording things that don't sync automatically

Not everything shows up on its own. A few common cases:

- **Checks** — there's no separate "check register." Just add it as a normal manual Expense transaction on the account it was drawn from, with a note like "Check #1042 — rent" so it's easy to spot later.
- **Cash spending** — same idea: a manual Expense transaction against whichever account the cash came from (or a dedicated cash account, if you track cash separately).
- **Recurring bills/income** — the app doesn't auto-create future transactions for you, but a **Rule** can auto-categorize them the moment they land (from a connected account) or right after you enter them (manually), so you're not re-doing the same categorization every month.

## 5. Syncing

Connected accounts sync in the background (via a job called `SyncJob`) — you don't need to do anything. If a balance looks stale, most account pages have a manual "sync now" action. Some providers include **pending** transactions (ones that have been authorized but haven't fully posted yet) — those show a "Pending" badge and may still shift slightly once they post for real.

## 6. Investments

Investment accounts track **Holdings** (what securities you own) via **Trades** (buy/sell activity). If you're manually tracking an investment account, cost basis is calculated in this priority order: whatever you enter **manually** wins first, then whatever the app **calculates** from your trade history, and finally whatever a **connected provider** reports — manual always overrides the rest.

## Next steps

Once you're comfortable with accounts and transactions, move on to [Budgeting: Cap vs. Envelope](02-budgeting.md) to actually start planning your spending.
