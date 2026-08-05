require "test_helper"

# The reserve exists to cancel out the envelope drop a credit purchase causes,
# so its filters have to agree with IncomeStatement::Totals exactly. Every
# filter test below asserts *parity*: the same charge disappears from the
# reserve and from expense_totals together. A charge that only disappears from
# one of them is the bug this class was written to fix.
class IncomeStatement::LiabilityReserveTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @card = accounts(:credit_card)
    @category = categories(:food_and_drink)
    @period = Period.custom(start_date: 30.days.ago.to_date, end_date: Date.current)
  end

  test "a card charge counts toward the reserve" do
    charge(100)

    assert_equal 100, reserve
  end

  test "a charge on an OtherLiability account counts" do
    charge(100, account: accounts(:other_liability))

    assert_equal 100, reserve
  end

  test "a charge on a Loan account does not count" do
    # loan_payment is not budget-excluded and Totals force-classifies it as an
    # expense, so loans already move cash and an envelope together. Reserving
    # for them too would double count.
    charge(100, account: accounts(:loan))

    assert_equal 0, reserve
  end

  test "spending from a cash account does not count" do
    charge(100, account: accounts(:depository))

    assert_equal 0, reserve
  end

  test "a refund to the card subtracts from the reserve" do
    charge(100)
    charge(-30)

    assert_equal 70, reserve
  end

  test "both legs of a card payment net the reserve back to zero" do
    charge(100)

    Transfer::Creator.new(
      family: @family,
      source_account_id: accounts(:depository).id,
      destination_account_id: @card.id,
      date: Date.current,
      amount: 100
    ).create

    # The cash-side leg is cc_payment (budget-excluded, and on a Depository
    # anyway); the card-side leg is a funds_movement of -100 on the card, which
    # is the payment as recorded against the debt.
    assert_equal 0, reserve
  end

  test "a balance transfer between two cards nets to zero" do
    second_card = @family.accounts.create!(
      name: "Second Card", balance: 0, currency: "USD", accountable: CreditCard.new
    )

    Transfer::Creator.new(
      family: @family,
      source_account_id: @card.id,
      destination_account_id: second_card.id,
      date: Date.current,
      amount: 500
    ).create

    # Paying card B with card A moves debt, it doesn't create or retire any.
    # The two-query formulation (liability spend minus cc_payment outflows)
    # reads this as -500.
    assert_equal 0, reserve
  end

  test "a cash advance from a card adds to the reserve" do
    Transfer::Creator.new(
      family: @family,
      source_account_id: @card.id,
      destination_account_id: accounts(:depository).id,
      date: Date.current,
      amount: 200
    ).create

    # Cash went up $200 and it's borrowed, so the reserve has to rise with it
    # or the pool hands the user $200 it doesn't have.
    assert_equal 200, reserve
  end

  test "budget-excluded kinds still count on a card" do
    charge(500, kind: "one_time")

    assert_equal 500, reserve
  end

  test "converts foreign charges at the entry date rate" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.5)

    create_transaction(account: @card, amount: 100, currency: "EUR", category: @category)

    assert_equal 150, reserve
  end

  # --- Parity with IncomeStatement::Totals -------------------------------

  test "an excluded entry leaves both the reserve and expense totals" do
    entry = charge(100)
    assert_equal [ 100, 100 ], [ reserve, expense_for(@category) ]

    entry.update!(excluded: true)

    assert_equal [ 0, 0 ], [ reserve, expense_for(@category) ]
  end

  test "an account excluded from reports leaves both the reserve and expense totals" do
    charge(100)
    assert_equal [ 100, 100 ], [ reserve, expense_for(@category) ]

    @card.update!(exclude_from_reports: true)

    assert_equal [ 0, 0 ], [ reserve, expense_for(@category) ]
  end

  test "a disabled account leaves both the reserve and expense totals" do
    charge(100)
    assert_equal [ 100, 100 ], [ reserve, expense_for(@category) ]

    @card.update!(status: "disabled")

    assert_equal [ 0, 0 ], [ reserve, expense_for(@category) ]
  end

  test "a pending transaction is absent from both the reserve and expense totals" do
    entry = charge(100)
    assert_equal [ 100, 100 ], [ reserve, expense_for(@category) ]

    entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    assert_equal [ 0, 0 ], [ reserve, expense_for(@category) ]
  end

  test "a tax-advantaged account leaves both the reserve and expense totals" do
    charge(100)
    assert_equal [ 100, 100 ], [ reserve, expense_for(@category) ]

    # Only Investment accounts can actually be tax-advantaged today, so stub
    # rather than contrive one — the point is that both queries read the same
    # id list and drop the same rows.
    @family.stubs(:tax_advantaged_account_ids).returns([ @card.id ])

    assert_equal [ 0, 0 ], [ reserve, expense_for(@category) ]
  end

  test "an account outside the viewing user's finances leaves both the reserve and expense totals" do
    charge(100)

    guest = family_guest
    AccountShare.create!(
      account: accounts(:depository), user: guest,
      permission: "read_only", include_in_finances: true
    )

    # The owner sees the charge in both figures...
    assert_equal [ 100, 100 ], [ reserve(user: users(:family_admin)), expense_for(@category, user: users(:family_admin)) ]

    # ...and the guest, who has no access to the card, sees it in neither.
    assert_equal [ 0, 0 ], [ reserve(user: guest), expense_for(@category, user: guest) ]
  end

  private
    def charge(amount, account: @card, kind: "standard")
      create_transaction(account: account, amount: amount, category: @category, kind: kind)
    end

    # Fresh statement per read: IncomeStatement memoizes per instance, and
    # these tests mutate the data between reads.
    def statement(user: nil)
      IncomeStatement.new(@family, user: user)
    end

    def reserve(user: nil)
      statement(user: user).liability_reserve_total(period: @period)
    end

    def expense_for(category, user: nil)
      total = statement(user: user)
        .expense_totals(period: @period)
        .category_totals
        .find { |ct| ct.category.id == category.id }
        &.total

      (total || 0).to_d
    end
end
