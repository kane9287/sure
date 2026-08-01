class CreateDebtPlans < ActiveRecord::Migration[7.2]
  def change
    create_table :debt_plans, id: :uuid do |t|
      t.references :family, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :name, null: false
      t.string :strategy, null: false, default: "avalanche"
      t.decimal :monthly_budget, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.text :notes

      t.timestamps
    end

    add_check_constraint :debt_plans, "char_length(name) <= 255", name: "chk_debt_plans_name_length"
    add_check_constraint :debt_plans, "monthly_budget > 0", name: "chk_debt_plans_monthly_budget_positive"
    add_check_constraint :debt_plans,
                         "strategy IN ('avalanche','snowball')",
                         name: "chk_debt_plans_strategy_enum"
  end
end
