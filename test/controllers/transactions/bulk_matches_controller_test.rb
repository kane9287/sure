require "test_helper"

class Transactions::BulkMatchesControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @family  = @user.family
    @account = accounts(:depository)

    enable_preview_features

    @manual = create_transaction(account: @account, amount: 2.84, date: Date.current, name: "Interest Charge")
    @provider = create_transaction(account: @account, amount: 2.84, date: Date.current, name: "Interest Charge")
    @provider.update!(external_id: "plaid_1", source: "plaid")
  end

  test "matches a manual entry and a provider entry the scorer missed" do
    assert_difference "Entry.count", -1 do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, @provider.id ] } }
    end

    assert_redirected_to transactions_url

    @manual.reload
    assert_equal "plaid_1", @manual.external_id
    assert_equal "plaid", @manual.source
    assert_not Entry.exists?(@provider.id)

    reconciliation = TransactionReconciliation.find_by(manual_entry_id: @manual.id, provider_source: "plaid", provider_external_id: "plaid_1")
    assert_predicate reconciliation, :confirmed?
    assert_equal 1.0, reconciliation.confidence
  end

  test "rejects a selection that is not exactly two entries" do
    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id ] } }
    end

    assert_redirected_to transactions_url
    assert_equal "Select exactly 2 transactions to match.", flash[:alert]
  end

  test "rejects two entries that are both manual or both synced" do
    other_manual = create_transaction(account: @account, amount: 5, date: Date.current, name: "Other")

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, other_manual.id ] } }
    end

    assert_redirected_to transactions_url
    assert_equal "Select one manually entered transaction and one synced transaction to match.", flash[:alert]
  end

  test "rejects a pair from different accounts" do
    other_account_provider = create_transaction(account: accounts(:credit_card), amount: 2.84, date: Date.current, name: "Interest Charge")
    other_account_provider.update!(external_id: "plaid_2", source: "plaid")

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, other_account_provider.id ] } }
    end

    assert_redirected_to transactions_url
    assert_equal "Matched transactions must be in the same account.", flash[:alert]
  end

  test "matches a split parent and carries its children across" do
    split_children(@manual, [ 2.00, 0.84 ])

    assert_difference "Entry.count", -1 do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, @provider.id ] } }
    end

    @manual.reload
    assert_equal "plaid_1", @manual.external_id
    assert_not Entry.exists?(@provider.id)

    assert_equal 2, @manual.child_entries.count
    assert_equal [ 0.84, 2.00 ], @manual.child_entries.map { |c| c.amount.to_f }.sort
    assert_equal [ categories(:food_and_drink).id, categories(:one).id ].sort,
                 @manual.child_entries.map { |c| c.entryable.category_id }.sort
    assert_predicate @manual, :excluded?
  end

  test "rejects a split parent whose amount differs from the synced entry" do
    split_children(@manual, [ 2.00, 0.84 ])
    @provider.update!(amount: 3.15)

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, @provider.id ] } }
    end

    assert_match "same amount", flash[:alert]
    assert_nil @manual.reload.external_id
  end

  test "rejects a pair whose synced entry is itself split" do
    split_children(@provider, [ 2.00, 0.84 ])

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, @provider.id ] } }
    end

    assert_match "synced transaction is split", flash[:alert]
    assert_equal 2, @provider.reload.child_entries.count
  end

  test "rejects a split child selected on its own" do
    child = split_children(@manual, [ 2.00, 0.84 ]).first

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ child.id, @provider.id ] } }
    end

    assert_match "Split lines", flash[:alert]
    assert_nil child.reload.external_id
  end

  test "redirects when preview features are off" do
    disable_preview_features

    assert_no_difference "Entry.count" do
      post transactions_bulk_match_url, params: { bulk_match: { entry_ids: [ @manual.id, @provider.id ] } }
    end

    assert_redirected_to root_url
  end

  private
    def split_children(entry, amounts)
      categories = [ categories(:food_and_drink), categories(:one) ]

      entry.split!(amounts.each_with_index.map { |amount, i|
        { name: "Line #{i + 1}", amount: amount, category_id: categories[i].id }
      })
    end

    def enable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    end

    def disable_preview_features
      @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => false))
    end
end
