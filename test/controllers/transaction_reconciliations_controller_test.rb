require "test_helper"

class TransactionReconciliationsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family  = @user.family
    @account = accounts(:depository)

    enable_preview_features
    ensure_tailwind_build

    @manual = create_transaction(account: @account, amount: 40, date: 2.days.ago.to_date, name: "Chipotle")
    @provider = create_transaction(account: @account, amount: 47.20, date: Date.current, name: "CHIPOTLE 1234")
    @provider.update!(external_id: "plaid_1", source: "plaid")

    @reconciliation = create_reconciliation
  end

  test "index lists pending reconciliations" do
    get transaction_reconciliations_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@reconciliation)}", count: 1
  end

  test "index does not list pairs that were already resolved" do
    @reconciliation.update!(status: :rejected, resolved_at: Time.current)

    get transaction_reconciliations_url

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@reconciliation)}", count: 0
  end

  test "index redirects when preview features are off" do
    disable_preview_features

    get transaction_reconciliations_url

    assert_redirected_to root_url
  end

  test "confirm merges the provider entry into the manual entry" do
    assert_difference "Entry.count", -1 do
      post confirm_transaction_reconciliation_path(@reconciliation)
    end

    assert_redirected_to transaction_reconciliations_url

    @manual.reload
    assert_equal "plaid_1", @manual.external_id
    assert_equal "plaid", @manual.source
    assert_equal 47.20, @manual.amount
    assert_equal Date.current, @manual.date
    assert_not Entry.exists?(@provider.id)

    @reconciliation.reload
    assert_predicate @reconciliation, :confirmed?
    assert_equal @user, @reconciliation.resolved_by_user
    assert_not_nil @reconciliation.resolved_at
  end

  # The survivor is the manual entry, so everything keyed to it has to come
  # through the merge untouched — that is the whole reason for claiming in place
  # rather than copying.
  test "confirm preserves the manual entry's id and its own attributes" do
    @manual.transaction.update!(category: categories(:food_and_drink))
    @manual.update!(notes: "split with Sam")

    post confirm_transaction_reconciliation_path(@reconciliation)

    @manual.reload
    assert_equal categories(:food_and_drink), @manual.transaction.category
    assert_equal "split with Sam", @manual.notes
    assert_equal "Chipotle", @manual.name
  end

  test "confirm is a no-op on an already resolved pair" do
    @reconciliation.update!(status: :confirmed, resolved_at: Time.current)

    assert_no_difference "Entry.count" do
      post confirm_transaction_reconciliation_path(@reconciliation)
    end
  end

  test "reject leaves both entries alone and tombstones the pair" do
    assert_no_difference "Entry.count" do
      post reject_transaction_reconciliation_path(@reconciliation)
    end

    assert_redirected_to transaction_reconciliations_url
    assert_predicate @reconciliation.reload, :rejected?
    assert_nil @manual.reload.external_id
    assert_equal 47.20, @provider.reload.amount
  end

  test "another family's reconciliation is not found" do
    @reconciliation.update!(family: families(:empty))

    assert_raises(ActiveRecord::RecordNotFound) do
      post confirm_transaction_reconciliation_path(@reconciliation)
    end
  end

  private
    def create_reconciliation
      TransactionReconciliation.create!(
        family: @family,
        manual_entry: @manual,
        provider_entry: @provider,
        provider_external_id: @provider.external_id,
        provider_source: @provider.source,
        status: :pending,
        confidence: 0.926,
        score_breakdown: {
          "amount" => { "ratio" => 1.18, "score" => 0.88, "weighted" => 0.396 },
          "date" => { "delta_days" => 2, "score" => 0.92, "weighted" => 0.23 },
          "name" => { "score" => 1.0, "weighted" => 0.3, "merchant_match" => true },
          "raw" => 0.926,
          "final" => 0.926
        },
        snapshot: {
          "provider_payload" => {
            "external_id" => @provider.external_id,
            "source" => @provider.source,
            "amount" => @provider.amount.to_s,
            "currency" => @provider.currency,
            "date" => @provider.date.to_s,
            "name" => @provider.name
          }
        },
        matched_at: Time.current
      )
    end

    def enable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    end
end
