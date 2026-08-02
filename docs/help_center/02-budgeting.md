# Budgeting: Cap Mode vs. Envelope Mode

This app supports two different ways to budget. They're not mixed together — a family picks **one mode at a time** in **Settings → Preferences → Budgeting**, and everyone in that family sees the same mode. You can switch later; nothing is destroyed when you switch, but the two modes think about money differently, so switching back and forth isn't something to do casually.

> [!NOTE]
> Switching modes is admin-only for the family, since it changes how the budget page works for everyone.

## The short version

| | **Cap Mode** | **Envelope Mode** |
|---|---|---|
| What it is | Set a *spending limit* per category for the month | Assign *real dollars you already have* to each category |
| Based on | A planned/expected number you type in | Actual cash sitting in your accounts right now |
| "Am I okay?" question | "Have I gone over my limit for Dining?" | "Do I still have money assigned to Dining?" |
| Best for | People who think in monthly limits and expected income | People who want to know exactly where every dollar is right now |
| Feels like | A traditional budget spreadsheet | Cash-in-envelopes / "give every dollar a job" |

If you're not sure which to pick: **Cap Mode** is closer to a traditional budget and is the simpler starting point. **Envelope Mode** takes a bit more up-front setup (you assign real money to categories) but gives you a much more honest, real-time picture of what you can actually spend.

## Cap Mode

Cap mode is a limit-based budget. Each month, you:

1. Enter your **expected income** for the month.
2. Set a **spending cap** per category (e.g. Groceries: $600, Dining: $150).
3. As transactions come in, the app shows you how much of each cap you've used and how much is left.

Cap mode doesn't check whether you actually *have* the money sitting in an account — it's purely a plan vs. actual comparison. If you go over a cap, the app will show it as over budget, but it won't stop you or move money around. It's a planning and awareness tool.

Any money you didn't explicitly assign a cap to falls into **Uncategorized** spending in the summary, so you can see what's not yet accounted for.

## Envelope Mode

Envelope mode is a cash-based budget, closer to the classic "envelope system" — every dollar you have gets assigned somewhere.

Here's the flow:

1. All the actual cash sitting in your **budget accounts** (checking, savings — whatever you've marked as in-budget) that hasn't been assigned anywhere yet shows up as **Unassigned**.
2. You **Fund** categories by moving money out of Unassigned and into a category (e.g. move $400 from Unassigned into Groceries).
3. As you spend from a category, its **Available** balance goes down. Spend more than you assigned, and it goes negative (**Overspent**) — the app will show this clearly, but it's just information, not a lock.
4. If a category goes overspent, you can **move money from another envelope** to cover it, right from the budgeting screen.
5. Unspent money in an envelope **carries forward** to next month — it doesn't reset to zero. Categories build up a cushion over time if you don't spend the full amount.

> [!IMPORTANT]
> **Unassigned is real cash, not a projection.** It's calculated from your actual account balances minus whatever you've already assigned to envelopes — it is *not* an estimate of income you expect to receive. You can't type in a number for it; it always reflects reality. If it looks wrong, it's almost always because a transaction or account balance needs attention (see [Good Habits](03-good-habits.md)), not because the app is guessing wrong.

### Goals and envelopes

A [Goal](04-glossary.md#goal) never takes money out of Unassigned on its own. Money leaves Unassigned when *you* assign it, and nothing else — that's what keeps the number honest and keeps a long-term goal from swallowing a month's budget.

If you're saving toward something specific (an emergency fund, a holiday fund, a new laptop), point the goal at a category and fund that category like any other envelope. The goal then acts as a **target** on that envelope: it shows what you're saving for, how much you've assigned so far, and how much more to assign this month to stay on pace. Assigning the money is what moves it; the target just tells you how much to assign.

## How balance reconciliation interacts with budgeting

Reconciling an account's balance (see [Good Habits](03-good-habits.md#if-the-ledger-is-off-dont-dwell-on-it)) never shows up as spending in either mode. It's a balance-only adjustment, not a categorized transaction — so it won't blow out a Cap Mode category limit, and it won't touch an Envelope Mode envelope. The one place it *does* show up is Envelope Mode's **Unassigned** figure, since that's pulled straight from account balances — reconciling a balance is exactly what keeps Unassigned trustworthy.

## Switching modes

Go to **Settings → Preferences → Budgeting** and change the "Budget mode" dropdown. Switching to Envelope mode for the first time starts fresh from today — it doesn't retroactively reconstruct envelope history from past months.

## Which one should my family actually use?

- Pick **Cap Mode** if you mostly think in terms of "I expect to make $X and want to spend no more than $Y per category" — a forward-looking plan.
- Pick **Envelope Mode** if you want the budget to always answer "what can I actually spend right now, with money I actually have" — a real-time, cash-first view.

There's no wrong answer — this is genuinely a preference thing. If you're testing the app for the first time, it's fine to try one for a couple weeks, see how it feels, and switch if it's not clicking.
