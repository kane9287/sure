class CreateBudgetAllocations < ActiveRecord::Migration[7.2]
  def change
    # Append-only record of money moved into (or out of) an envelope from the
    # family's Unassigned pool. Spend-side amounts are never posted here —
    # those stay derived live from IncomeStatement exactly as in cap mode.
    # Only the allocation side needs a persisted event, since "I assigned
    # $200 to Groceries" isn't a Transaction and can't be inferred from
    # transaction aggregation alone.
    create_table :budget_allocations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :family_id, null: false
      t.uuid :category_id, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :date, null: false
      # "fund"   : Unassigned -> envelope (positive amount)
      # "sweep"  : envelope -> Unassigned, e.g. manual reallocation (negative amount)
      t.string :kind, null: false, default: "fund"

      t.timestamps
    end

    add_foreign_key :budget_allocations, :families
    add_foreign_key :budget_allocations, :categories

    add_index :budget_allocations, [ :family_id, :category_id, :date ], name: "index_budget_allocations_on_family_category_date"
    add_index :budget_allocations, :family_id
    add_index :budget_allocations, :category_id

    add_check_constraint :budget_allocations,
                         "kind IN ('fund','sweep')",
                         name: "chk_budget_allocations_kind_enum"
  end
end
