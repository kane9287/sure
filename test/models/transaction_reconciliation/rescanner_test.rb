require "test_helper"

class TransactionReconciliation::RescannerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family  = @account.family

    @family.update!(manual_reconciliation_mode: "review_only")
  end

  test "finds a review match for an already-imported, unmatched provider entry" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, name: "samsung affirm")
    provider = create_provider_entry(amount: 40, date: 1.day.ago.to_date, name: "affirm - direct payment")

    assert_difference "TransactionReconciliation.count", 1 do
      assert_equal 1, TransactionReconciliation::Rescanner.call(@account)
    end

    reconciliation = TransactionReconciliation.last
    assert_equal manual, reconciliation.manual_entry
    assert_equal provider, reconciliation.provider_entry
    assert_predicate reconciliation, :pending?
  end

  test "skips a provider entry already under an open or resolved reconciliation" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, name: "samsung affirm")
    provider = create_provider_entry(amount: 40, date: 1.day.ago.to_date, name: "affirm - direct payment")

    TransactionReconciliation.create!(
      family: @family,
      manual_entry: manual,
      provider_entry: provider,
      provider_external_id: provider.external_id,
      provider_source: provider.source,
      status: :pending,
      confidence: 0.9,
      score_breakdown: {},
      snapshot: {},
      matched_at: Time.current
    )

    assert_no_difference "TransactionReconciliation.count" do
      assert_equal 0, TransactionReconciliation::Rescanner.call(@account)
    end
  end

  test "skips a pair the user already rejected" do
    manual = create_manual_capture(amount: 40, date: 2.days.ago.to_date, name: "samsung affirm")
    provider = create_provider_entry(amount: 40, date: 1.day.ago.to_date, name: "affirm - direct payment")

    TransactionReconciliation.create!(
      family: @family,
      manual_entry: manual,
      provider_entry: nil,
      provider_external_id: provider.external_id,
      provider_source: provider.source,
      status: :rejected,
      confidence: 0.9,
      score_breakdown: {},
      snapshot: {},
      matched_at: Time.current,
      resolved_at: Time.current
    )

    assert_no_difference "TransactionReconciliation.count" do
      assert_equal 0, TransactionReconciliation::Rescanner.call(@account)
    end
  end

  test "respects manual_reconciliation_mode off" do
    @family.update!(manual_reconciliation_mode: "off")
    create_manual_capture(amount: 40, date: 2.days.ago.to_date, name: "samsung affirm")
    create_provider_entry(amount: 40, date: 1.day.ago.to_date, name: "affirm - direct payment")

    assert_no_difference "TransactionReconciliation.count" do
      assert_equal 0, TransactionReconciliation::Rescanner.call(@account)
    end
  end

  test "respects the recency window" do
    create_manual_capture(amount: 40, date: 400.days.ago.to_date, name: "samsung affirm")
    create_provider_entry(amount: 40, date: 400.days.ago.to_date, name: "affirm - direct payment")

    assert_no_difference "TransactionReconciliation.count" do
      assert_equal 0, TransactionReconciliation::Rescanner.call(@account)
    end
  end

  test "call_for_accounts sums matches across multiple accounts" do
    other_account = accounts(:credit_card)

    create_manual_capture(amount: 40, date: 2.days.ago.to_date, name: "samsung affirm")
    create_provider_entry(amount: 40, date: 1.day.ago.to_date, name: "affirm - direct payment")

    other_manual = create_transaction(account: other_account, amount: 25, date: 2.days.ago.to_date, currency: "USD", name: "netflix")
    other_provider = create_transaction(account: other_account, amount: 25, date: 1.day.ago.to_date, currency: "USD", name: "netflix.com")
    other_provider.update!(external_id: "plaid_rescan_2", source: "plaid")

    assert_difference "TransactionReconciliation.count", 2 do
      assert_equal 2, TransactionReconciliation::Rescanner.call_for_accounts([ @account, other_account ])
    end
  end

  private
    def create_manual_capture(amount:, date:, name:)
      create_transaction(account: @account, amount: amount, date: date, currency: "USD", name: name)
    end

    def create_provider_entry(amount:, date:, name:, external_id: "plaid_rescan_1")
      entry = create_transaction(account: @account, amount: amount, date: date, currency: "USD", name: name)
      entry.update!(external_id: external_id, source: "plaid")
      entry
    end
end
