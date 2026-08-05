require "test_helper"

class SimplefinAccount::LinkingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access"
    )

    @sfa = build_simplefin_account("sf_new", "SimpleFin Checking")
  end

  test "links an unlinked simplefin account to a manual account" do
    assert_includes @family.accounts.visible_manual, @account

    provider_link = @sfa.link_to_account!(@account)

    assert_equal @account.id, provider_link.account_id
    assert_equal @sfa, provider_link.provider
    assert_equal @account, @sfa.reload.linked_account
    # The whole point: the account stops being a manual candidate, so the wizard
    # can't offer it twice and the unique index can't be violated.
    assert_not_includes @family.accounts.visible_manual.to_a, @account
  end

  test "linking twice yields exactly one account provider" do
    @sfa.link_to_account!(@account)

    assert_no_difference "AccountProvider.count" do
      @sfa.link_to_account!(@account)
    end

    assert_equal 1, @account.reload.account_providers.count
  end

  test "relinking moves the provider off the previous account and clears legacy foreign keys" do
    old_account = build_manual_account("Old Checking")
    AccountProvider.create!(account: old_account, provider: @sfa)
    old_account.update!(simplefin_account_id: @sfa.id)

    @sfa.link_to_account!(@account)

    assert_equal @account.id, @sfa.reload.account_provider.account_id
    assert_equal 1, AccountProvider.where(provider: @sfa).count
    assert_nil old_account.reload.simplefin_account_id
    assert_nil @account.reload.simplefin_account_id
  end

  test "detaches the target account's existing simplefin link before attaching the new one" do
    # Fraud-replacement path: swapping a dead card's sfa for its replacement.
    old_sfa = build_simplefin_account("sf_old", "Old Card")
    AccountProvider.create!(account: @account, provider: old_sfa)

    @sfa.link_to_account!(@account)

    assert_nil AccountProvider.find_by(provider: old_sfa)
    assert_equal [ @sfa.id ], @account.reload.account_providers.pluck(:provider_id)
  end

  test "raises ForeignProviderError when the account is linked to another provider type" do
    plaid_item = PlaidItem.create!(
      family: @family, plaid_id: "test_plaid_item", access_token: "test_token", name: "Test Bank"
    )
    plaid_account = PlaidAccount.create!(
      plaid_item: plaid_item, name: "Plaid Checking", plaid_id: "plaid_123",
      plaid_type: "depository", currency: "USD", current_balance: 1000
    )
    AccountProvider.create!(account: @account, provider: plaid_account)

    assert_raises(SimplefinAccount::Linking::ForeignProviderError) do
      @sfa.link_to_account!(@account)
    end
  end

  test "raises ForeignProviderError when the account carries a legacy plaid foreign key" do
    assert_raises(SimplefinAccount::Linking::ForeignProviderError) do
      @sfa.link_to_account!(accounts(:connected))
    end
  end

  test "raises WrongFamilyError for an account in another family" do
    other_family_account = Account.create!(
      family: families(:empty), name: "Someone Else's Checking", balance: 100,
      currency: "USD", accountable: Depository.new, status: "active"
    )

    assert_raises(SimplefinAccount::Linking::WrongFamilyError) do
      @sfa.link_to_account!(other_family_account)
    end
  end

  test "raises CurrencyMismatchError when the currencies differ" do
    # SimplefinAccount::Processor rewrites account.currency on every sync, so a
    # cross-currency link would silently re-denominate existing history.
    eur_sfa = build_simplefin_account("sf_eur", "Euro Checking", currency: "EUR")

    assert_raises(SimplefinAccount::Linking::CurrencyMismatchError) do
      eur_sfa.link_to_account!(@account)
    end
  end

  test "retires the orphaned previous account by default" do
    old_account = build_manual_account("Old Checking")
    AccountProvider.create!(account: old_account, provider: @sfa)

    @sfa.link_to_account!(@account)

    assert_equal "pending_deletion", old_account.reload.status
  end

  test "leaves the previous account alone when orphan cleanup is disabled" do
    # Regression guard for the setup-wizard path, which must never delete an account.
    old_account = build_manual_account("Old Checking")
    AccountProvider.create!(account: old_account, provider: @sfa)

    @sfa.link_to_account!(@account, destroy_orphaned_previous_account: false)

    assert_equal "active", old_account.reload.status
  end

  test "keeps a previous account that still has other provider links" do
    # account_providers is unique on [account_id, provider_type], so the leftover
    # link has to be a different provider type.
    old_account = build_manual_account("Old Checking")
    AccountProvider.create!(account: old_account, provider: @sfa)
    plaid_item = PlaidItem.create!(
      family: @family, plaid_id: "test_plaid_item", access_token: "test_token", name: "Test Bank"
    )
    plaid_account = PlaidAccount.create!(
      plaid_item: plaid_item, name: "Plaid Checking", plaid_id: "plaid_123",
      plaid_type: "depository", currency: "USD", current_balance: 1000
    )
    AccountProvider.create!(account: old_account, provider: plaid_account)

    @sfa.link_to_account!(@account)

    assert_equal "active", old_account.reload.status
  end

  test "linkable_accounts returns manual accounts of linkable types in matching currency" do
    results = @sfa.linkable_accounts

    assert_includes results, accounts(:depository)
    assert_includes results, accounts(:credit_card)
    assert_includes results, accounts(:crypto)
    assert_not_includes results, accounts(:connected)
    assert_not_includes results, accounts(:property)
    assert_not_includes results, accounts(:vehicle)
  end

  test "linkable_accounts excludes accounts in a different currency" do
    accounts(:depository).update!(currency: "EUR")

    assert_not_includes @sfa.linkable_accounts, accounts(:depository)
  end

  test "linkable_accounts excludes accounts already claimed by a provider" do
    @sfa.link_to_account!(@account)

    other_sfa = build_simplefin_account("sf_other", "Other Card")

    assert_not_includes other_sfa.linkable_accounts, @account
  end

  test "linkable_accounts filters a caller-supplied candidate list" do
    candidates = [ accounts(:depository), accounts(:property) ]

    assert_equal [ accounts(:depository) ], @sfa.linkable_accounts(candidates: candidates)
  end

  private

    def build_simplefin_account(external_id, name, currency: "USD")
      SimplefinAccount.create!(
        simplefin_item: @item,
        name: name,
        account_id: external_id,
        account_type: "checking",
        currency: currency,
        current_balance: 100
      )
    end

    def build_manual_account(name)
      Account.create!(
        family: @family,
        name: name,
        balance: 100,
        currency: "USD",
        accountable: Depository.new,
        status: "active"
      )
    end
end
