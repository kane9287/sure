require "test_helper"

class TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "should get new" do
    get new_transfer_url
    assert_response :success
  end

  test "can create transfers" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          name: "Test Transfer"
        }
      }
      assert_enqueued_with job: SyncJob
    end
  end

  test "can create transfer with custom exchange rate" do
    usd_account = accounts(:depository)
    eur_account = users(:family_admin).family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    assert_equal "USD", usd_account.currency
    assert_equal "EUR", eur_account.currency

    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: usd_account.id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100,
          exchange_rate: 0.92
        }
      }
    end

    transfer = Transfer.where(
      "outflow_transaction_id IN (?) AND inflow_transaction_id IN (?)",
      usd_account.transactions.pluck(:id),
      eur_account.transactions.pluck(:id)
    ).last
    assert_not_nil transfer
    assert_equal "USD", transfer.outflow_transaction.entry.currency
    assert_equal "EUR", transfer.inflow_transaction.entry.currency
    assert_equal 100, transfer.outflow_transaction.entry.amount
    assert_in_delta(-92, transfer.inflow_transaction.entry.amount, 0.01)
  end

  test "exchange_rate endpoint returns 400 when from currency is missing" do
    get exchange_rate_url, params: {
      to: "USD"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 when to currency is missing" do
    get exchange_rate_url, params: {
      from: "EUR"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "from and to currencies are required", json_response["error"]
  end

  test "exchange_rate endpoint returns 400 on invalid date format" do
    get exchange_rate_url, params: {
      from: "EUR",
      to: "USD",
      date: "not-a-date"
    }

    assert_response :bad_request
    json_response = JSON.parse(response.body)
    assert_equal "Invalid date format", json_response["error"]
  end

  test "exchange_rate endpoint returns rate for different currencies" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "EUR", date: Date.current)
                .returns(OpenStruct.new(rate: 0.92))

    get exchange_rate_url, params: {
      from: "USD",
      to: "EUR",
      date: Date.current.to_s
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal 0.92, json_response["rate"]
  end

  test "exchange_rate endpoint returns error when exchange rate unavailable" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "USD", to: "EUR", date: Date.current)
                .returns(nil)

    get exchange_rate_url, params: {
      from: "USD",
      to: "EUR",
      date: Date.current.to_s
    }

    assert_response :not_found
    json_response = JSON.parse(response.body)
    assert_equal "Exchange rate not found", json_response["error"]
  end

  test "cannot create transfer when exchange rate unavailable and no custom rate provided" do
    usd_account = accounts(:depository)
    eur_account = users(:family_admin).family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_no_difference "Transfer.count" do
      post transfers_url, params: {
        transfer: {
          from_account_id: usd_account.id,
          to_account_id: eur_account.id,
          date: Date.current,
          amount: 100
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "can create transfer with source fee" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          source_fee_amount: 3
        }
      }
    end

    transfer = Transfer.order(created_at: :desc).first
    assert_equal 100, transfer.amount
    assert_equal 3, transfer.derived_source_fee_amount
    assert_equal 0, transfer.derived_destination_fee_amount
    # Outflow should be principal only (no fee baked in)
    assert_equal 100, transfer.outflow_transaction.entry.amount
    # Inflow should be -(converted_principal)
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
    # Fee transaction should be created
    assert_equal 1, transfer.fee_transactions.count
    fee_tx = transfer.fee_transactions.first
    assert_equal "standard", fee_tx.kind
    assert_equal 3, fee_tx.entry.amount
    assert_equal accounts(:depository).id, fee_tx.entry.account_id
    assert transfer.has_source_fee?
    assert_not transfer.has_destination_fee?
  end

  test "can create transfer with destination fee" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          destination_fee_amount: 3
        }
      }
    end

    transfer = Transfer.order(created_at: :desc).first
    assert_equal 100, transfer.amount
    assert_equal 0, transfer.derived_source_fee_amount
    assert_equal 3, transfer.derived_destination_fee_amount
    # Outflow should be principal only
    assert_equal 100, transfer.outflow_transaction.entry.amount
    # Inflow should be -(converted_principal)
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
    # Fee transaction should be created
    assert_equal 1, transfer.fee_transactions.count
    fee_tx = transfer.fee_transactions.first
    assert_equal "standard", fee_tx.kind
    assert_equal 3, fee_tx.entry.amount
    assert_equal accounts(:credit_card).id, fee_tx.entry.account_id
    assert_not transfer.has_source_fee?
    assert transfer.has_destination_fee?
  end

  test "can create transfer with both source and destination fees" do
    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 100,
          source_fee_amount: 2,
          destination_fee_amount: 3
        }
      }
    end

    transfer = Transfer.order(created_at: :desc).first
    assert_equal 100, transfer.amount
    assert_equal 2, transfer.derived_source_fee_amount
    assert_equal 3, transfer.derived_destination_fee_amount
    # Outflow should be principal only
    assert_equal 100, transfer.outflow_transaction.entry.amount
    # Inflow should be -(converted_principal)
    assert_equal(-100, transfer.inflow_transaction.entry.amount)
    # Two fee transactions should be created
    assert_equal 2, transfer.fee_transactions.count
    source_fee_tx = transfer.fee_transactions.find { |t| t.entry.account_id == accounts(:depository).id }
    dest_fee_tx = transfer.fee_transactions.find { |t| t.entry.account_id == accounts(:credit_card).id }
    assert_equal 2, source_fee_tx.entry.amount
    assert_equal 3, dest_fee_tx.entry.amount
    assert transfer.has_fees?
  end

  test "derived fee methods reflect fee transaction entry edits" do
    post transfers_url, params: {
      transfer: {
        from_account_id: accounts(:depository).id,
        to_account_id: accounts(:credit_card).id,
        date: Date.current,
        amount: 100,
        source_fee_amount: 3
      }
    }

    transfer = Transfer.order(created_at: :desc).first
    assert_equal 3, transfer.derived_source_fee_amount

    # Simulate an independent edit of the fee transaction entry
    fee_tx = transfer.fee_transactions.first
    fee_tx.entry.update!(amount: 5)

    # Derived fee should reflect the updated entry
    transfer.reload
    assert_equal 5, transfer.derived_source_fee_amount
    assert transfer.has_source_fee?
  end

  test "exchange_rate endpoint returns same_currency for matching currencies" do
    get exchange_rate_url, params: {
      from: "USD",
      to: "USD"
    }

    assert_response :success
    json_response = JSON.parse(response.body)
    assert_equal true, json_response["same_currency"]
    assert_equal 1.0, json_response["rate"]
  end

  test "soft deletes transfer" do
    assert_difference -> { Transfer.count }, -1 do
      delete transfer_url(transfers(:one))
    end
  end

  test "can add notes to transfer" do
    transfer = transfers(:one)
    assert_nil transfer.notes

    patch transfer_url(transfer), params: { transfer: { notes: "Test notes" } }

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]
    assert_equal "Test notes", transfer.reload.notes
  end

  test "handles rejection without FrozenError" do
    transfer = transfers(:one)

    assert_difference "Transfer.count", -1 do
      patch transfer_url(transfer), params: {
        transfer: {
          status: "rejected"
        }
      }
    end

    assert_redirected_to transactions_url
    assert_equal "Transfer updated", flash[:notice]

    # Verify the transfer was actually destroyed
    assert_raises(ActiveRecord::RecordNotFound) do
      transfer.reload
    end
  end

  test "mark_as_recurring creates a recurring transfer" do
    transfer = transfers(:one)
    family = users(:family_admin).family
    family.recurring_transactions.destroy_all

    assert_difference -> { RecurringTransaction.where(family: family).count }, +1 do
      post mark_as_recurring_transfer_url(transfer)
    end

    rt = RecurringTransaction.where(family: family).last
    assert rt.transfer?
    assert_equal transfer.outflow_transaction.entry.account, rt.account
    assert_equal transfer.inflow_transaction.entry.account, rt.destination_account
    assert rt.manual?
    assert_equal I18n.t("recurring_transactions.transfer_marked_as_recurring"), flash[:notice]
    assert_redirected_to transactions_path
  end

  test "mark_as_recurring is idempotent: second call flashes already-exists" do
    transfer = transfers(:one)
    family = users(:family_admin).family
    family.recurring_transactions.destroy_all

    post mark_as_recurring_transfer_url(transfer)
    assert_equal I18n.t("recurring_transactions.transfer_marked_as_recurring"), flash[:notice]

    assert_no_difference -> { RecurringTransaction.where(family: family).count } do
      post mark_as_recurring_transfer_url(transfer)
    end
    assert_equal I18n.t("recurring_transactions.transfer_already_exists"), flash[:alert]
  end

  test "mark_as_recurring is rejected when recurring_transactions_disabled" do
    transfer = transfers(:one)
    family = users(:family_admin).family
    family.update!(recurring_transactions_disabled: true)
    family.recurring_transactions.destroy_all

    assert_no_difference -> { RecurringTransaction.where(family: family).count } do
      post mark_as_recurring_transfer_url(transfer)
    end
    assert_equal I18n.t("recurring_transactions.transfer_feature_disabled"), flash[:alert]
  end

  test "new with recurring_transaction_id pre-fills both endpoints and the amount" do
    recurring = create_manual_recurring_transfer(amount: 250)

    get new_transfer_url(recurring_transaction_id: recurring.id)
    assert_response :success
    assert_select "input[type='hidden'][name='transfer[from_account_id]'][value=?]", accounts(:depository).id
    assert_select "input[type='hidden'][name='transfer[to_account_id]'][value=?]", accounts(:credit_card).id
    assert_select "input[name='transfer[amount]'][value=?]", "250.0"
    assert_select "input[type='hidden'][name='recurring_transaction_id'][value=?]", recurring.id
  end

  test "new with recurring_transaction_id prefills the average amount when variance is tracked" do
    recurring = create_manual_recurring_transfer(amount: 250)
    recurring.update!(expected_amount_min: 200, expected_amount_max: 300, expected_amount_avg: 260)

    get new_transfer_url(recurring_transaction_id: recurring.id)
    assert_response :success
    assert_select "input[name='transfer[amount]'][value=?]", "260.0"
  end

  test "new with auto-detected recurring_transaction_id does not prefill" do
    recurring = create_manual_recurring_transfer(amount: 250)
    recurring.update!(manual: false)

    get new_transfer_url(recurring_transaction_id: recurring.id)
    assert_response :success
    assert_select "input[type='hidden'][name='transfer[to_account_id]'][value=?]", accounts(:credit_card).id, count: 0
    assert_select "input[type='hidden'][name='recurring_transaction_id']", count: 0
  end

  test "new with non-transfer recurring_transaction_id does not prefill" do
    recurring = recurring_transactions(:netflix_subscription)
    recurring.update!(manual: true)

    get new_transfer_url(recurring_transaction_id: recurring.id)
    assert_response :success
    assert_select "input[type='hidden'][name='recurring_transaction_id']", count: 0
  end

  test "new with recurring_transaction_id from another family does not prefill" do
    other_family = families(:empty)
    source = other_family.accounts.create!(name: "Other source", balance: 0, currency: "USD", accountable: Depository.new)
    destination = other_family.accounts.create!(name: "Other destination", balance: 0, currency: "USD", accountable: Depository.new)
    recurring = other_family.recurring_transactions.create!(
      account: source,
      destination_account: destination,
      name: "Should not leak",
      amount: 250,
      currency: "USD",
      expected_day_of_month: 10,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 10.days.from_now.to_date,
      status: "active",
      manual: true,
      occurrence_count: 1
    )

    get new_transfer_url(recurring_transaction_id: recurring.id)
    assert_response :success
    assert_select "input[type='hidden'][name='recurring_transaction_id']", count: 0
  end

  test "create with recurring_transaction_id records the occurrence" do
    recurring = create_manual_recurring_transfer(amount: 250)

    assert_difference "Transfer.count", 1 do
      post transfers_url, params: {
        recurring_transaction_id: recurring.id,
        transfer: {
          from_account_id: accounts(:depository).id,
          to_account_id: accounts(:credit_card).id,
          date: Date.current,
          amount: 275
        }
      }
    end

    recurring.reload
    assert_equal Date.current, recurring.last_occurrence_date
    assert_equal 2, recurring.occurrence_count
    assert_equal "active", recurring.status
    assert_equal recurring.expected_day_of_month, recurring.next_expected_date.day
    assert recurring.next_expected_date > Date.current
    assert_equal 275, recurring.expected_amount_avg
  end

  test "create without recurring_transaction_id leaves recurring transactions untouched" do
    recurring = create_manual_recurring_transfer(amount: 250)
    original_date = recurring.last_occurrence_date

    post transfers_url, params: {
      transfer: {
        from_account_id: accounts(:depository).id,
        to_account_id: accounts(:credit_card).id,
        date: Date.current,
        amount: 275
      }
    }

    recurring.reload
    assert_equal original_date, recurring.last_occurrence_date
    assert_equal 1, recurring.occurrence_count
  end

  test "create with recurring_transaction_id from another family does not record an occurrence" do
    other_family = families(:empty)
    source = other_family.accounts.create!(name: "Other source", balance: 0, currency: "USD", accountable: Depository.new)
    destination = other_family.accounts.create!(name: "Other destination", balance: 0, currency: "USD", accountable: Depository.new)
    recurring = other_family.recurring_transactions.create!(
      account: source,
      destination_account: destination,
      name: "Should not leak",
      amount: 250,
      currency: "USD",
      expected_day_of_month: 10,
      last_occurrence_date: 1.month.ago.to_date,
      next_expected_date: 10.days.from_now.to_date,
      status: "active",
      manual: true,
      occurrence_count: 1
    )
    original_date = recurring.last_occurrence_date

    post transfers_url, params: {
      recurring_transaction_id: recurring.id,
      transfer: {
        from_account_id: accounts(:depository).id,
        to_account_id: accounts(:credit_card).id,
        date: Date.current,
        amount: 275
      }
    }

    recurring.reload
    assert_equal original_date, recurring.last_occurrence_date
    assert_equal 1, recurring.occurrence_count
  end

  private
    # No manual transfer row exists in the fixtures, so build one inline.
    def create_manual_recurring_transfer(amount:)
      users(:family_admin).family.recurring_transactions.create!(
        account: accounts(:depository),
        destination_account: accounts(:credit_card),
        name: "Card payment",
        amount: amount,
        currency: "USD",
        expected_day_of_month: 10,
        last_occurrence_date: 1.month.ago.to_date,
        next_expected_date: 10.days.from_now.to_date,
        status: "active",
        manual: true,
        occurrence_count: 1
      )
    end
end
