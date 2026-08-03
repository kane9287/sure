require "test_helper"

# The inline manual-capture hook in Account::ProviderImportAdapter#import_transaction.
# Kept in its own file rather than appended to the (already long) adapter test,
# since every case here needs the same preview + family-mode setup.
class Account::ProviderImportAdapterReconciliationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family  = @account.family
    @adapter = Account::ProviderImportAdapter.new(@account)

    @family.update!(manual_reconciliation_mode: "review_only")
    @family.users.each do |user|
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    end

    @merchant = ProviderMerchant.create!(
      provider_merchant_id: "reconciliation_merchant",
      name: "Chipotle",
      source: "plaid"
    )
  end

  test "records a review instead of claiming, leaving the manual entry untouched" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    assert_difference [ "@account.entries.count", "TransactionReconciliation.count" ], 1 do
      import(amount: 47.20, date: Date.current)
    end

    reconciliation = TransactionReconciliation.last

    assert_equal manual, reconciliation.manual_entry
    assert_predicate reconciliation, :pending?
    assert_equal @family, reconciliation.family
    assert_equal "plaid", reconciliation.provider_source

    manual.reload
    assert_nil manual.external_id
    assert_equal 40, manual.amount
    assert_equal 2.days.ago.to_date, manual.date
  end

  # The claim/no-claim boundary is the entire safety story for this PR.
  test "never mutates either side while the family is in review_only mode" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    provider_entry = import(amount: 47.20, date: Date.current)

    assert_not_equal manual.id, provider_entry.id
    assert_equal "plaid_reconciliation_1", provider_entry.external_id
    assert_equal 40, manual.reload.amount
  end

  test "mode off skips the matcher entirely" do
    @family.update!(manual_reconciliation_mode: "off")
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current)
    end
  end

  test "a family with nobody opted into preview is not matched" do
    @family.users.each do |user|
      user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => false))
    end
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current)
    end
  end

  # A multi-thousand-row historical backfill must not pay for this feature.
  test "historical imports short-circuit before the matcher runs" do
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)
    TransactionReconciliation::Matcher.any_instance.expects(:call).never

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: 400.days.ago.to_date)
    end
  end

  test "an imported row is not a candidate" do
    imported = create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)
    imported.update!(import_locked: true)

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current)
    end
  end

  test "an entry a provider already claimed is not a candidate" do
    claimed = create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)
    claimed.update!(external_id: "already_claimed", source: "plaid")

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current)
    end
  end

  test "re-importing the same payload does not raise a second review" do
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    import(amount: 47.20, date: Date.current)

    assert_no_difference [ "@account.entries.count", "TransactionReconciliation.count" ] do
      import(amount: 47.20, date: Date.current)
    end
  end

  # Providers that send a pending row and then a posted row under a different id
  # would otherwise raise two cards for one purchase.
  test "only one open review exists per manual entry" do
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    import(amount: 47.20, date: Date.current, external_id: "plaid_pending")

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current, external_id: "plaid_posted")
    end
  end

  test "a pair the user rejected is never proposed again" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, merchant: @merchant)

    import(amount: 47.20, date: Date.current)
    reconciliation = TransactionReconciliation.last
    reconciliation.update!(status: :rejected, resolved_at: Time.current)
    reconciliation.provider_entry.destroy!

    assert_no_difference "TransactionReconciliation.count" do
      import(amount: 47.20, date: Date.current)
    end

    assert_nil manual.reload.external_id
  end

  # No regression on the path that already worked: an exact date + amount match
  # is claimed in place by find_duplicate_transaction, before our hook is reached.
  test "an exact duplicate is still claimed rather than queued for review" do
    manual = create_manual_capture(amount: 40, date: Date.current, merchant: @merchant)

    assert_no_difference [ "@account.entries.count", "TransactionReconciliation.count" ] do
      import(amount: 40, date: Date.current)
    end

    assert_equal "plaid_reconciliation_1", manual.reload.external_id
  end

  private
    def create_manual_capture(amount:, date:, merchant: nil)
      create_transaction(
        account: @account,
        amount: amount,
        date: date,
        currency: "USD",
        name: "Chipotle",
        merchant: merchant
      )
    end

    def import(amount:, date:, external_id: "plaid_reconciliation_1")
      @adapter.import_transaction(
        external_id: external_id,
        amount: amount,
        currency: "USD",
        date: date,
        name: "CHIPOTLE 1234",
        source: "plaid",
        merchant: @merchant
      )
    end
end
