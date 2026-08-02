require "test_helper"

class BudgetCategoryEnvelopeTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.activate_envelope_mode!
    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current.beginning_of_month)
    @category = Category.create!(name: "BC Envelope #{Time.now.to_f}", family: @family, color: "#445566")
    @budget.sync_budget_categories
    @budget_category = @budget.budget_categories.find_by(category: @category)
  end

  test "available_to_spend delegates to envelope_available_to_spend in envelope mode" do
    account = accounts(:depository)

    @family.budget_allocations.create!(category: @category, amount: 250, currency: "USD", date: Date.current, kind: "fund")

    Entry.create!(
      account: account,
      entryable: Transaction.create!(category: @category),
      date: Date.current,
      name: "Spend",
      amount: 60,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    assert_equal 190, @budget_category.available_to_spend
    assert_equal @budget_category.envelope_available_to_spend, @budget_category.available_to_spend
  end

  test "available_to_spend falls back to cap-mode math when family is in cap mode" do
    @family.deactivate_envelope_mode!
    @budget_category.update!(budgeted_spending: 100)

    refute_equal @budget_category.envelope_available_to_spend, @budget_category.available_to_spend
    assert_equal 100, @budget_category.available_to_spend
  end

  test "envelope_assigned counts only this period's funding while the balance carries prior periods forward" do
    @family.update!(envelope_activated_on: 2.months.ago.to_date)

    # Assigned before this budget's period: rolls into the balance, but is not
    # part of what was assigned this month.
    @family.budget_allocations.create!(category: @category, amount: 500, currency: "USD", date: @budget.start_date - 1.day, kind: "fund")

    @family.budget_allocations.create!(category: @category, amount: 150, currency: "USD", date: Date.current, kind: "fund")
    @family.budget_allocations.create!(category: @category, amount: -50, currency: "USD", date: Date.current, kind: "sweep")

    Entry.create!(
      account: accounts(:depository),
      entryable: Transaction.create!(category: @category),
      date: Date.current,
      name: "Spend",
      amount: 30,
      currency: "USD"
    )

    @family.reset_envelope_caches!

    assert_equal 100, @budget_category.envelope_assigned
    assert_equal 570, @budget_category.envelope_available_to_spend
  end

  test "envelope_available_to_spend defaults to zero for an unfunded category" do
    assert_equal 0, @budget_category.envelope_available_to_spend
    assert_equal 0, @budget_category.envelope_assigned
  end
end
