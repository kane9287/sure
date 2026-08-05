class AddSystemKeyToCategories < ActiveRecord::Migration[7.2]
  def change
    # Locale-independent identity for categories the app owns rather than the
    # user. Name-matching (how investment_contributions is still identified)
    # can't work here: the whole point of a built-in is that its name is
    # immutable, so the name can't also be the key. A real column also lets the
    # ~20 category pickers filter with a scope instead of a per-locale name list.
    add_column :categories, :system_key, :string

    add_index :categories, [ :family_id, :system_key ],
              unique: true,
              where: "system_key IS NOT NULL",
              name: "index_categories_on_family_id_and_system_key"

    add_check_constraint :categories,
                         "system_key IS NULL OR system_key IN ('debt_payment')",
                         name: "chk_categories_system_key_enum"
  end
end
