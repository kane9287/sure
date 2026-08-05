class AddManualReconciliationModeToFamilies < ActiveRecord::Migration[8.1]
  def change
    # "off"         : matcher never runs.
    # "review_only" : matches recorded for human review; nothing mutated silently.
    #                 The default, so upgrading changes no existing behaviour.
    # "auto"        : matches >= threshold claim the manual entry in place;
    #                 everything below still goes to review. Not reachable from
    #                 the UI until the auto-merge phase ships — the column accepts
    #                 it now so the enum never needs a second migration.
    add_column :families, :manual_reconciliation_mode, :string,
               null: false, default: "review_only"

    add_check_constraint :families,
      "manual_reconciliation_mode IN ('off','review_only','auto')",
      name: "chk_families_manual_reconciliation_mode_enum"
  end
end
