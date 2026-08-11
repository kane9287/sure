require "test_helper"

class LandingPageTest < ActiveSupport::TestCase
  # Guards the merge hazard called out in the plan: if upstream renames or drops
  # a nav destination, #path raises here rather than in production.
  test "every key resolves to a real route" do
    LandingPage.all.each do |page|
      assert_match %r{\A/}, page.path(preview_features_enabled: true)
      assert_match %r{\A/}, page.path(preview_features_enabled: false)
    end
  end

  test "every key resolves to a translated nav label" do
    LandingPage.all.each do |page|
      assert page.label(preview_features_enabled: true).present?
      assert page.label(preview_features_enabled: false).present?
    end
  end

  test "home resolves to the dashboard rather than root" do
    assert_equal "/dashboard", LandingPage.find("home").path(preview_features_enabled: false)
  end

  test "plan falls back to budgets without preview features" do
    plan = LandingPage.find("plan")

    assert_equal "/plan", plan.path(preview_features_enabled: true)
    assert_equal "Plan", plan.label(preview_features_enabled: true)

    assert_equal "/budgets", plan.path(preview_features_enabled: false)
    assert_equal "Budgets", plan.label(preview_features_enabled: false)
  end

  test "keys without a fallback ignore the preview flag" do
    transactions = LandingPage.find("transactions")

    assert_equal transactions.path(preview_features_enabled: true),
                 transactions.path(preview_features_enabled: false)
  end

  test "find returns nil for an unknown key" do
    assert_nil LandingPage.find("not_a_page")
    assert_nil LandingPage.find(nil)
  end

  test "default is home" do
    assert_equal "home", LandingPage.default.key
  end
end
