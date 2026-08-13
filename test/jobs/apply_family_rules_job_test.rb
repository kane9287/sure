require "test_helper"

class ApplyFamilyRulesJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Rules test", balance: 1000, currency: "USD", accountable: Depository.new)
    @groceries = @family.categories.create!(name: "Groceries")
    @dining = @family.categories.create!(name: "Dining")
  end

  test "applies active rules and skips inactive ones" do
    whole_foods = create_transaction(account: @account, name: "Whole Foods", date: Date.current).entryable
    chipotle = create_transaction(account: @account, name: "Chipotle", date: Date.current).entryable

    create_rule(active: true, matching: "Whole Foods", category: @groceries)
    create_rule(active: false, matching: "Chipotle", category: @dining)

    ApplyFamilyRulesJob.perform_now(@family)

    assert_equal @groceries, whole_foods.reload.category
    assert_nil chipotle.reload.category
  end

  # Automatic runs must never clobber a user's manual edits.
  test "respects attribute locks" do
    transaction = create_transaction(account: @account, name: "Whole Foods", date: Date.current).entryable
    transaction.update!(category: @dining)
    transaction.lock_attr!(:category_id)

    create_rule(active: true, matching: "Whole Foods", category: @groceries)

    ApplyFamilyRulesJob.perform_now(@family)

    assert_equal @dining, transaction.reload.category
  end

  test "records runs as scheduled by default" do
    create_transaction(account: @account, name: "Whole Foods", date: Date.current)
    rule = create_rule(active: true, matching: "Whole Foods", category: @groceries)

    ApplyFamilyRulesJob.perform_now(@family)

    assert_equal "scheduled", rule.rule_runs.order(:created_at).last.execution_type
  end

  private
    def create_rule(active:, matching:, category:)
      Rule.create!(
        family: @family,
        resource_type: "transaction",
        active: active,
        effective_date: 1.year.ago.to_date,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: matching) ],
        actions: [ Rule::Action.new(action_type: "set_transaction_category", value: category.id) ]
      )
    end
end
