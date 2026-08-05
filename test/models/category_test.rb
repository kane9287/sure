require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "replacing and destroying" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(categories(:income))

    assert_equal categories(:income), transactions.map { |t| t.reload.category }.uniq.first
  end

  test "replacing with nil should nullify the category" do
    transactions = categories(:food_and_drink).transactions.to_a

    categories(:food_and_drink).replace_and_destroy!(nil)

    assert_nil transactions.map { |t| t.reload.category }.uniq.first
  end

  test "destroying parent category preserves subcategory transaction assignments" do
    parent = @family.categories.create!(
      name: "Parent With Child Transactions",
      color: "#000000",
      lucide_icon: "folder"
    )
    subcategory = @family.categories.create!(
      name: "Child With Transactions",
      color: "#111111",
      lucide_icon: "folder",
      parent: parent
    )
    transaction = Transaction.create!(category: subcategory)

    assert_difference "Category.count", -1 do
      parent.destroy!
    end

    assert_nil subcategory.reload.parent_id
    assert_equal subcategory, transaction.reload.category
  end

  test "invalid parent_id does not raise during validation" do
    category = Category.new(
      name: "Orphan Subcategory",
      color: "#000000",
      lucide_icon: "folder",
      family: @family,
      parent_id: SecureRandom.uuid
    )

    assert_nothing_raised { category.valid? }
    assert_not category.subcategory?
    assert_nil category.parent
  end

  test "subcategory can only be one level deep" do
    category = categories(:subcategory)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      category.subcategories.create!(name: "Invalid category", family: @family)
    end

    assert_equal "Validation failed: Parent can't have more than 2 levels of subcategories", error.message
  end

  test "all_investment_contributions_names returns all locale variants" do
    names = Category.all_investment_contributions_names

    assert_includes names, "Investment Contributions"  # English
    assert_includes names, "Contributions aux investissements"  # French
    assert_includes names, "Investeringsbijdragen"  # Dutch
    assert names.all? { |name| name.is_a?(String) }
    assert_equal names, names.uniq  # No duplicates
  end

  test "display_name localizes default category names" do
    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮", categories(:food_and_drink).display_name
      assert_equal "未分类", Category.uncategorized.display_name
    end
  end

  test "display_name returns default category names in english" do
    I18n.with_locale(:en) do
      assert_equal "Food & Drink", categories(:food_and_drink).display_name
      assert_equal "Uncategorized", Category.uncategorized.display_name
    end
  end

  test "display_name preserves custom category names" do
    category = Category.new(name: "School Supplies", color: "#123456", lucide_icon: "book", family: @family)

    I18n.with_locale(:"zh-CN") do
      assert_equal "School Supplies", category.display_name
    end
  end

  test "display_name_with_parent localizes default parent and child names" do
    category = Category.new(
      name: "Groceries",
      color: "#123456",
      lucide_icon: "shopping-bag",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > 杂货", category.display_name_with_parent
    end
  end

  test "display_name_with_parent preserves custom child names" do
    category = Category.new(
      name: "Coffee Beans",
      color: "#123456",
      lucide_icon: "coffee",
      family: @family,
      parent: categories(:food_and_drink)
    )

    I18n.with_locale(:"zh-CN") do
      assert_equal "餐饮 > Coffee Beans", category.display_name_with_parent
    end
  end

  test "should accept valid 6-digit hex colors" do
    [ "#FFFFFF", "#000000", "#123456", "#ABCDEF", "#abcdef" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert category.valid?, "#{color} should be valid"
    end
  end

  test "should reject invalid colors" do
    [ "invalid", "#123", "#1234567", "#GGGGGG", "red", "ffffff", "#ffff", "" ].each do |color|
      category = Category.new(name: "Category #{color}", color: color, lucide_icon: "shapes", family: @family)
      assert_not category.valid?, "#{color} should be invalid"
      assert_includes category.errors[:color], "is invalid"
    end
  end

  test "ids_with_transactions returns a lookup hash for categorized transactions" do
    category = categories(:food_and_drink)
    transaction = Transaction.create!(category: category)
    Entry.create!(
      account: accounts(:depository),
      entryable: transaction,
      name: "Lookup transaction",
      date: Date.current,
      amount: 10,
      currency: "USD"
    )

    lookup = Category.ids_with_transactions(family: @family, category_ids: [ category.id, 0 ])

    assert lookup.key?(category.id)
    assert_not lookup.key?(0)
  end

  test "a system category cannot be renamed, reparented or re-keyed" do
    category = @family.debt_payment_category

    category.name = "Something else"
    category.parent = categories(:food_and_drink)
    category.system_key = nil

    assert_not category.valid?
    assert_includes category.errors.attribute_names, :name
    assert_includes category.errors.attribute_names, :parent_id
    assert_includes category.errors.attribute_names, :system_key
  end

  test "a system category's color and icon are still editable" do
    category = @family.debt_payment_category

    assert category.update(color: "#abcdef", lucide_icon: "wallet")
  end

  test "a system category cannot be destroyed on its own" do
    category = @family.debt_payment_category

    assert_no_difference "Category.count" do
      assert_not category.destroy
    end

    assert_includes category.errors.attribute_names, :base
  end

  test "destroying a family still destroys its system categories" do
    family = Family.create!(name: "Doomed Family #{Time.now.to_f}", currency: "USD", locale: "en")
    family.activate_envelope_mode!
    category = family.debt_payment_category

    family.destroy!

    assert_not Category.exists?(category.id)
  end

  test "user_selectable excludes system categories" do
    category = @family.debt_payment_category

    assert_not_includes @family.categories.user_selectable, category
    assert_includes @family.categories.user_selectable, categories(:food_and_drink)
  end

  test "system_key is unique per family" do
    @family.debt_payment_category
    duplicate = @family.categories.new(name: "Another debt envelope", system_key: "debt_payment")

    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :system_key
  end

  test "display_name resolves a system category through i18n rather than the stored name" do
    category = @family.debt_payment_category

    assert_equal I18n.t("models.category.debt_payment"), category.display_name
  end

  test "debt_payment_category is idempotent across envelope mode round trips" do
    category = @family.debt_payment_category

    @family.deactivate_envelope_mode!
    @family.activate_envelope_mode!

    assert_equal category, @family.reload.debt_payment_category
  end

  test "the system category name is disambiguated when the family already uses it" do
    @family.categories.create!(name: I18n.t("models.category.debt_payment"), color: "#123456")

    category = @family.debt_payment_category

    assert category.persisted?
    assert_not_equal I18n.t("models.category.debt_payment"), category.name
    assert_equal I18n.t("models.category.debt_payment"), category.display_name
  end
end
