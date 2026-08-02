class AddBudgetModeToFamilies < ActiveRecord::Migration[7.2]
  def change
    # "cap"      : v1 behaviour — each period's budgeted_spending resets, no rollover.
    # "envelope" : rolling available-to-spend balance funded from the family's
    #              Unassigned pool, carried forward across periods (see BudgetAllocation).
    add_column :families, :budget_mode, :string, null: false, default: "cap"

    add_check_constraint :families,
                         "budget_mode IN ('cap','envelope')",
                         name: "chk_families_budget_mode_enum"

    # Anchor for envelope-mode rolling balances: allocations/spend are only
    # summed from this date forward, so switching modes never has to touch or
    # reinterpret pre-existing transaction history.
    add_column :families, :envelope_activated_on, :date
  end
end
