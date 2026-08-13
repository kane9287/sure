require "test_helper"

class TransactionReconciliation::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family  = families(:dylan_family)
    @user    = users(:family_admin)
    @account = accounts(:depository)

    @manual = create_transaction(account: @account, amount: 40, date: 3.days.ago.to_date, name: "Target")
    @provider = create_transaction(account: @account, amount: 40, date: 1.day.ago.to_date, name: "TARGET T-1957")
    @provider.update!(external_id: "simplefin_1", source: "simplefin")
  end

  test "moves split children onto the date the provider claimed" do
    @manual.split!([
      { name: "Groceries", amount: 25, category_id: categories(:food_and_drink).id },
      { name: "Gifts", amount: 15, category_id: categories(:one).id }
    ])

    assert merge!

    @manual.reload
    assert_equal @provider.date, @manual.date
    assert_equal [ @manual.date ], @manual.child_entries.map(&:date).uniq
  end

  test "carries split children through the claim untouched" do
    @manual.split!([
      { name: "Groceries", amount: 25, category_id: categories(:food_and_drink).id },
      { name: "Gifts", amount: 15, category_id: categories(:one).id }
    ])
    child_ids = @manual.child_entries.pluck(:id).sort

    assert merge!

    @manual.reload
    assert_equal child_ids, @manual.child_entries.pluck(:id).sort
    assert_equal "simplefin_1", @manual.external_id
    assert_equal "Target", @manual.name, "manual name should win over the provider descriptor"
    assert_predicate @manual, :excluded?, "split parent stays excluded so it is not double counted"
  end

  test "does not backfill a category onto a split parent" do
    @provider.entryable.update!(category_id: categories(:food_and_drink).id)
    @manual.split!([
      { name: "Groceries", amount: 25, category_id: categories(:food_and_drink).id },
      { name: "Gifts", amount: 15, category_id: categories(:one).id }
    ])

    assert merge!

    assert_nil @manual.reload.entryable.category_id
  end

  test "still backfills a category onto an unsplit manual entry" do
    @provider.entryable.update!(category_id: categories(:food_and_drink).id)

    assert merge!

    assert_equal categories(:food_and_drink).id, @manual.reload.entryable.category_id
  end

  private
    def merge!
      reconciliation = TransactionReconciliation.create!(
        family: @family,
        manual_entry: @manual,
        provider_entry: @provider,
        provider_external_id: @provider.external_id,
        provider_source: @provider.source,
        status: :pending,
        confidence: 1.0,
        score_breakdown: { "manual_override" => true },
        snapshot: { "manual_before" => TransactionReconciliation::Merger.manual_snapshot(@manual) },
        cross_account: false,
        matched_at: Time.current
      )

      TransactionReconciliation::Merger.new(reconciliation).apply_from_review!(user: @user)
    end
end
