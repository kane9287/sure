require "test_helper"

class DebtPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
    @debt_plan = debt_plans(:card_payoff)
    @credit_card = accounts(:credit_card)
    @other_liability = accounts(:other_liability)
    ensure_tailwind_build
  end

  test "index lists the family's plans" do
    get debt_plans_url

    assert_response :success
    assert_match @debt_plan.name, response.body
  end

  test "show renders the plan" do
    get debt_plan_url(@debt_plan)

    assert_response :success
    assert_match @debt_plan.name, response.body
  end

  test "show honors the strategy query param without changing the saved strategy" do
    get debt_plan_url(@debt_plan, strategy: "snowball")

    assert_response :success
    assert_equal "avalanche", @debt_plan.reload.strategy
  end

  test "show falls back to the saved strategy for an unknown param" do
    get debt_plan_url(@debt_plan, strategy: "lasso")

    assert_response :success
  end

  test "new preselects every liability except mortgages" do
    accounts(:loan).update!(subtype: "mortgage")

    get new_debt_plan_url

    assert_response :success
    assert_select "input#debt_plan_account_ids_#{@credit_card.id}[checked]"
    assert_select "input#debt_plan_account_ids_#{accounts(:loan).id}"
    assert_select "input#debt_plan_account_ids_#{accounts(:loan).id}[checked]", count: 0
  end

  test "creates a plan with per-account overrides" do
    assert_difference [ "DebtPlan.count", "DebtPlanAccount.count" ], 1 do
      post debt_plans_url, params: {
        debt_plan: {
          name: "Clear the cards",
          strategy: "snowball",
          monthly_budget: 400,
          account_ids: [ @credit_card.id ],
          overrides: { @credit_card.id => { apr: "12.5", minimum: "75" } }
        }
      }
    end

    plan = DebtPlan.order(:created_at).last
    assert_redirected_to debt_plan_url(plan)
    assert_equal "snowball", plan.strategy
    assert_equal 12.5.to_d, plan.debt_plan_accounts.first.apr_override
    assert_equal 75.to_d, plan.debt_plan_accounts.first.minimum_payment_override
  end

  test "blank overrides are stored as nil rather than zero" do
    post debt_plans_url, params: {
      debt_plan: {
        name: "No overrides",
        strategy: "avalanche",
        monthly_budget: 400,
        account_ids: [ @credit_card.id ],
        overrides: { @credit_card.id => { apr: "", minimum: "  " } }
      }
    }

    link = DebtPlan.order(:created_at).last.debt_plan_accounts.first
    assert_nil link.apr_override
    assert_nil link.minimum_payment_override
  end

  test "create rejects a plan with no debts" do
    assert_no_difference "DebtPlan.count" do
      post debt_plans_url, params: {
        debt_plan: { name: "Empty", strategy: "avalanche", monthly_budget: 400, account_ids: [] }
      }
    end

    assert_response :unprocessable_entity
  end

  test "create ignores a submitted family_id" do
    other_family = families(:empty)

    post debt_plans_url, params: {
      debt_plan: {
        name: "Strong params",
        strategy: "avalanche",
        monthly_budget: 400,
        family_id: other_family.id,
        account_ids: [ @credit_card.id ]
      }
    }

    assert_equal families(:dylan_family).id, DebtPlan.order(:created_at).last.family_id
  end

  test "create ignores accounts that are not liabilities" do
    assert_no_difference "DebtPlan.count" do
      post debt_plans_url, params: {
        debt_plan: {
          name: "Not a debt",
          strategy: "avalanche",
          monthly_budget: 400,
          account_ids: [ accounts(:depository).id ]
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "updates the plan and syncs its debts" do
    patch debt_plan_url(@debt_plan), params: {
      debt_plan: {
        name: "Renamed",
        strategy: "snowball",
        monthly_budget: 600,
        account_ids: [ @credit_card.id ]
      }
    }

    assert_redirected_to debt_plan_url(@debt_plan)
    @debt_plan.reload
    assert_equal "Renamed", @debt_plan.name
    assert_equal "snowball", @debt_plan.strategy
    assert_equal [ @credit_card.id ], @debt_plan.debt_plan_accounts.map(&:account_id)
  end

  # Rack drops a genuinely empty array, so the form always submits a blank
  # sentinel id — that is what "I unchecked everything" looks like on the wire.
  test "update rejects clearing every debt" do
    patch debt_plan_url(@debt_plan), params: {
      debt_plan: { name: "Renamed", strategy: "avalanche", monthly_budget: 600, account_ids: [ "" ] }
    }

    assert_response :unprocessable_entity
    assert_equal 2, @debt_plan.reload.debt_plan_accounts.count
  end

  test "destroys the plan" do
    assert_difference "DebtPlan.count", -1 do
      delete debt_plan_url(@debt_plan)
    end

    assert_redirected_to debt_plans_url
  end

  # Plans are always looked up through Current.family, so a plan belonging to
  # another family is indistinguishable from one that never existed.
  test "a plan outside the current family is not found" do
    get debt_plan_url(id: SecureRandom.uuid)

    assert_redirected_to debt_plans_url
    assert_match(/couldn't be found/i, flash[:alert])
  end
end
