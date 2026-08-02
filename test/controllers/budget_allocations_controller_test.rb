require "test_helper"

class BudgetAllocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)

    @budget = budgets(:one)
    @family = @budget.family
    @family.activate_envelope_mode!

    # Fresh categories so fixture transactions can't add spend to the envelopes
    # under test — these assertions are about allocations, not the spend side.
    @category = Category.create!(name: "Alloc dest #{Time.now.to_f}", family: @family, color: "#4da568")
    @source = Category.create!(name: "Alloc source #{Time.now.to_f}", family: @family, color: "#445566")
  end

  test "set funds the difference up to the requested total" do
    post_allocation(kind: "set", amount: "200")

    assert_redirected_to budget_budget_categories_path(@budget)
    assert_equal 200, assigned_this_period
  end

  test "set sweeps the difference back to Unassigned when the total drops" do
    fund(300)

    assert_difference -> { @family.budget_allocations.count }, 1 do
      post_allocation(kind: "set", amount: "125")
    end

    posted = @family.budget_allocations.order(:created_at).last
    assert_equal 125, assigned_this_period
    assert_equal(-175, posted.amount)
    assert_equal "sweep", posted.kind
  end

  test "set with an unchanged total posts nothing" do
    fund(300)

    assert_no_difference -> { @family.budget_allocations.count } do
      post_allocation(kind: "set", amount: "300")
    end

    assert_equal 300, assigned_this_period
  end

  test "set measures against this period only, leaving carried-forward money alone" do
    @family.update!(envelope_activated_on: 2.months.ago.to_date)
    fund(500, date: @budget.start_date - 1.day)

    post_allocation(kind: "set", amount: "100")

    # Prior periods are untouched, so the rolling balance is last month's $500
    # plus this month's $100 — the carry-forward that makes envelopes roll over.
    assert_equal 100, assigned_this_period
    assert_equal 600, envelope_balance
  end

  test "fund stays additive" do
    fund(100)

    post_allocation(kind: "fund", amount: "50")

    assert_equal 150, assigned_this_period
  end

  test "from_category_id moves money between envelopes without touching Unassigned" do
    fund(400, category: @source)
    before = unassigned_pool

    assert_difference -> { @family.budget_allocations.count }, 2 do
      post budget_budget_allocations_path(@budget), params: {
        budget_allocation: { category_id: @category.id, from_category_id: @source.id, amount: "150" }
      }
    end

    assert_equal 150, assigned_this_period
    assert_equal 250, assigned_this_period(@source)
    assert_equal before, unassigned_pool
  end

  test "create is rejected outside envelope mode" do
    @family.deactivate_envelope_mode!

    assert_no_difference -> { @family.budget_allocations.count } do
      post_allocation(kind: "set", amount: "200")
    end

    assert_redirected_to budget_budget_categories_path(@budget)
  end

  private
    def post_allocation(kind:, amount:, category: @category)
      post budget_budget_allocations_path(@budget), params: {
        budget_allocation: { category_id: category.id, kind: kind, amount: amount }
      }
    end

    def fund(amount, category: @category, date: Date.current)
      @family.budget_allocations.create!(
        category: category, amount: amount, currency: @family.currency, date: date, kind: "fund"
      )
    end

    def assigned_this_period(category = @category)
      @family.budget_allocations
             .where(category_id: category.id, date: @budget.start_date..@budget.end_date)
             .sum(:amount)
    end

    # reload leaves Family's memoized envelope math in place, so the cache has
    # to be cleared explicitly after a request has written allocations.
    def envelope_balance(category = @category)
      @family.reset_envelope_caches!
      @family.envelope_balances_by_category[category.id]
    end

    def unassigned_pool
      @family.reset_envelope_caches!
      @family.unassigned_pool_balance
    end
end
