# frozen_string_literal: true

json.id category.id
json.name category.name
json.color category.color
json.icon category.lucide_icon

# Built-in categories are maintained by the app: their balance is derived, so
# clients must not offer them when picking a category for a transaction.
# set! rather than json.system — Jbuilder routes bare method calls through
# method_missing, and `system` collides with the private Kernel method.
json.set! "system", category.system?
json.system_key category.system_key

# Parent information (for subcategories)
if category.parent.present?
  json.parent do
    json.id category.parent.id
    json.name category.parent.name
  end
else
  json.parent nil
end

# Subcategories count (for parent categories)
json.subcategories_count category.subcategories.size

json.created_at category.created_at.iso8601
json.updated_at category.updated_at.iso8601
