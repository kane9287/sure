class CreateDebtPlanAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :debt_plan_accounts, id: :uuid do |t|
      t.references :debt_plan, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.references :account, null: false, foreign_key: { on_delete: :restrict }, type: :uuid
      # Mirrors loans.interest_rate precision so a loan rate never truncates on copy.
      t.decimal :apr_override, precision: 10, scale: 3
      t.decimal :minimum_payment_override, precision: 19, scale: 4

      t.timestamps
    end

    add_index :debt_plan_accounts, [ :debt_plan_id, :account_id ],
              unique: true,
              name: "index_debt_plan_accounts_on_plan_and_account"

    add_check_constraint :debt_plan_accounts,
                         "apr_override IS NULL OR apr_override >= 0",
                         name: "chk_debt_plan_accounts_apr_non_negative"
    add_check_constraint :debt_plan_accounts,
                         "minimum_payment_override IS NULL OR minimum_payment_override >= 0",
                         name: "chk_debt_plan_accounts_minimum_non_negative"
  end
end
