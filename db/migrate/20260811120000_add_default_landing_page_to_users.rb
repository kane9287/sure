class AddDefaultLandingPageToUsers < ActiveRecord::Migration[7.2]
  def change
    # Which screen "/" sends the user to. Defaults to "home" so existing users
    # keep landing on the dashboard. No check constraint: the sibling
    # preferences (theme, default_period, default_account_order) are all
    # validated in the model only, and the allowed set lives in
    # LandingPage::PAGES where the nav can change without a migration.
    add_column :users, :default_landing_page, :string, default: "home", null: false
  end
end
