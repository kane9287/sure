import { Controller } from "@hotwired/stimulus";

// Live feedback for the debt plan form.
//
// The one thing a user can't work out in their head is whether the budget they
// typed actually covers every minimum payment on the debts they ticked. The
// server rejects an underfunded plan, but finding that out after a round trip
// is a bad trade — so the sum of minimums is recomputed here as accounts and
// override fields change, and the budget field is flagged inline.
export default class extends Controller {
  static targets = ["row", "budgetInput", "minimumsTotal", "underfundedWarning", "submitButton"];

  static values = {
    currency: { type: String, default: "USD" },
    minimumsTemplate: { type: String, default: "Minimum payments total {amount}/mo" },
  };

  connect() {
    this.recalculate();
  }

  recalculate() {
    const total = this.rowTargets
      .filter((row) => this.#checkbox(row)?.checked)
      .reduce((sum, row) => sum + this.#minimumFor(row), 0);

    if (this.hasMinimumsTotalTarget) {
      this.minimumsTotalTarget.textContent = this.minimumsTemplateValue.replace(
        "{amount}",
        this.#money(total),
      );
    }

    const budget = this.hasBudgetInputTarget ? Number.parseFloat(this.budgetInputTarget.value) : Number.NaN;
    const underfunded = Number.isFinite(budget) && budget > 0 && budget < total;

    if (this.hasUnderfundedWarningTarget) {
      this.underfundedWarningTarget.classList.toggle("hidden", !underfunded);
    }
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.setAttribute("aria-disabled", String(underfunded || !this.#anyChecked()));
    }
  }

  // Ticking a row reveals its APR / minimum inputs. Untouched rows stay
  // collapsed so the form doesn't read as a wall of number fields.
  toggleRow(event) {
    const row = event.target.closest("[data-debt-plan-form-target~='row']");
    const details = row?.querySelector("[data-debt-plan-form-details]");
    if (details) details.classList.toggle("hidden", !event.target.checked);
    this.recalculate();
  }

  #anyChecked() {
    return this.rowTargets.some((row) => this.#checkbox(row)?.checked);
  }

  #checkbox(row) {
    return row.querySelector("input[type='checkbox']");
  }

  // Override field first, then the server-supplied default carried on the row.
  // A row with neither contributes nothing — matching the engine, which treats
  // a missing minimum as zero.
  #minimumFor(row) {
    const input = row.querySelector("[data-debt-plan-form-minimum]");
    const typed = Number.parseFloat(input?.value);
    if (Number.isFinite(typed) && typed >= 0) return typed;

    const fallback = Number.parseFloat(row.dataset.defaultMinimum);
    return Number.isFinite(fallback) ? fallback : 0;
  }

  #money(value) {
    try {
      return new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: this.currencyValue || "USD",
        maximumFractionDigits: 0,
      }).format(value);
    } catch {
      return `${this.currencyValue || "$"}${Math.round(value).toLocaleString()}`;
    }
  }
}
