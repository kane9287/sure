require "test_helper"

class BudgetAllocationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @category = categories(:food_and_drink)
  end

  test "valid fund allocation" do
    allocation = @family.budget_allocations.new(category: @category, amount: 100, currency: "USD", date: Date.current, kind: "fund")
    assert allocation.valid?
  end

  test "valid sweep allocation" do
    allocation = @family.budget_allocations.new(category: @category, amount: -100, currency: "USD", date: Date.current, kind: "sweep")
    assert allocation.valid?
  end

  test "requires a non-zero amount" do
    allocation = @family.budget_allocations.new(category: @category, amount: 0, currency: "USD", date: Date.current, kind: "fund")
    refute allocation.valid?
    assert_includes allocation.errors[:amount], "must be other than 0"
  end

  test "fund amount must be positive" do
    allocation = @family.budget_allocations.new(category: @category, amount: -50, currency: "USD", date: Date.current, kind: "fund")
    refute allocation.valid?
    assert_includes allocation.errors[:amount], "must be positive when funding an envelope."
  end

  test "sweep amount must be negative" do
    allocation = @family.budget_allocations.new(category: @category, amount: 50, currency: "USD", date: Date.current, kind: "sweep")
    refute allocation.valid?
    assert_includes allocation.errors[:amount], "must be negative when sweeping money back to Unassigned."
  end

  test "category must belong to the same family" do
    other_family = Family.create!(name: "Other Family")
    other_family_category = Category.create!(name: "Other Category", family: other_family, color: "#abcdef")

    allocation = @family.budget_allocations.new(category: other_family_category, amount: 100, currency: "USD", date: Date.current, kind: "fund")
    refute allocation.valid?
    assert_includes allocation.errors[:category], "Category must belong to the same household as the allocation."
  end

  test "funds and sweeps scopes filter by kind" do
    assert_includes @family.budget_allocations.funds, budget_allocations(:groceries_fund)
    refute_includes @family.budget_allocations.funds, budget_allocations(:groceries_sweep)

    assert_includes @family.budget_allocations.sweeps, budget_allocations(:groceries_sweep)
    refute_includes @family.budget_allocations.sweeps, budget_allocations(:groceries_fund)
  end

  test "net_allocated sums fund and sweep amounts for a category since a date" do
    net = BudgetAllocation.net_allocated(family: @family, category: @category, since_date: 1.year.ago)
    assert_equal 150, net # 200 fund - 50 sweep
  end

  test "total_allocated sums across all categories since a date" do
    total = BudgetAllocation.total_allocated(family: @family, since_date: 1.year.ago)
    assert_equal 150, total
  end
end
