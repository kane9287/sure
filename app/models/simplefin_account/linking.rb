# frozen_string_literal: true

module SimplefinAccount::Linking
  # Points a SimpleFin account at an existing Account instead of a freshly created one.
  # The mirror of SimplefinItem::Unlinking — same transactional, idempotent shape.
  #
  # Extracted from SimplefinItemsController#link_existing_account so the setup wizard
  # and the account-first "Link provider" menu run the same code. Dedupe only works
  # within a single Account (Account::ProviderImportAdapter#find_duplicate_transaction
  # and TransactionReconciliation::Matcher are both account-scoped), so linking rather
  # than creating is what lets a manually tracked month survive the connection.
  extend ActiveSupport::Concern

  Error                 = Class.new(StandardError)
  ForeignProviderError  = Class.new(Error)
  WrongFamilyError      = Class.new(Error)
  CurrencyMismatchError = Class.new(Error)

  LINKABLE_ACCOUNTABLE_TYPES = %w[Depository CreditCard Investment Loan Crypto OtherAsset].freeze

  # Balances have to agree to the cent to count as a match. Someone who kept a manual
  # account current will agree with the bank exactly, which makes this a near-zero
  # false-positive signal — strong enough to preselect a dropdown, never strong enough
  # to link without the user submitting.
  BALANCE_MATCH_TOLERANCE = 0.01.to_d

  # Attach this SimpleFin account to `target_account`, moving the link off whatever
  # it pointed at before. Returns the AccountProvider.
  #
  # destroy_orphaned_previous_account: when the provider is moved off an account that
  # is left with no provider links at all, queue that leftover for deletion. True
  # preserves the account-first relink behavior, where the orphan is a duplicate the
  # user is consolidating away. The setup wizard passes false: it only ever links SFAs
  # that have no account yet, so a non-nil previous_account there would mean the
  # candidate query had gone wrong, and deleting a real account is not the way to find out.
  def link_to_account!(target_account, destroy_orphaned_previous_account: true)
    # Cross-provider guard: we only support swapping SimpleFIN-to-SimpleFIN links here.
    # If the account is linked to a different provider type (Plaid, Binance, etc.),
    # require an explicit unlink first so users don't silently lose cross-provider data.
    # Same-provider relinks (e.g. a Citi fraud replacement swapping to a new card) are fine.
    has_foreign_provider = target_account.account_providers
      .where.not(provider_type: "SimplefinAccount").exists? ||
      target_account.plaid_account_id.present?
    raise ForeignProviderError if has_foreign_provider

    raise WrongFamilyError unless target_account.family_id == simplefin_item.family_id

    # SimplefinAccount::Processor writes `currency: simplefin_account.currency` onto the
    # account on every sync, so linking across currencies would silently re-denominate
    # whatever history the account already holds.
    raise CurrencyMismatchError unless currency.to_s.casecmp?(target_account.currency.to_s)

    provider_link = nil

    Account.transaction do
      lock!

      # Detach the account's EXISTING SimpleFIN link (if any) before attaching the new
      # one. This is the fraud-replacement path: the user is swapping from sfa_old (dead
      # card) to sfa_new. Without this the account ends up with two AccountProviders and
      # the old sfa's data still flows in on every sync.
      target_account.account_providers.where(provider_type: "SimplefinAccount").find_each do |existing_ap|
        # Skip the one we're about to (re)assign — avoid deleting what we then recreate.
        next if existing_ap.provider_id == id
        existing_ap.destroy
      end
      target_account.update!(simplefin_account_id: nil) if target_account.simplefin_account_id.present?

      # Clear the legacy association if present. `self.account` (not the `account` local
      # of the old controller code) is the Account whose simplefin_account_id points here.
      if (legacy_account = account)
        legacy_account.update!(simplefin_account_id: nil)
      end

      # Upsert the AccountProvider mapping deterministically
      provider_link = AccountProvider.find_or_initialize_by(provider: self)
      previous_account = provider_link.account
      provider_link.account_id = target_account.id
      provider_link.save!

      if destroy_orphaned_previous_account
        discard_orphaned_account(previous_account, target_account)
      end

      reload_account_provider
    end

    provider_link
  end

  # Accounts this SimpleFin account could be attached to.
  #
  # `visible_manual` is load-bearing: it left-joins account_providers requiring id IS NULL
  # plus nil plaid_account_id/simplefin_account_id, so every account it returns is provably
  # incapable of violating the account_providers [account_id, provider_type] unique index.
  # The candidate list is the guard.
  #
  # candidates: lets a caller load the family's manual accounts once and filter in Ruby
  # across many SFAs rather than issuing one query each.
  def linkable_accounts(candidates: nil)
    candidates ||= simplefin_item.family.accounts.visible_manual.alphabetically.to_a

    candidates.select do |candidate|
      LINKABLE_ACCOUNTABLE_TYPES.include?(candidate.accountable_type) &&
        currency.to_s.casecmp?(candidate.currency.to_s)
    end
  end

  # The one linkable account whose balance already agrees with the provider, or nil.
  # Deliberately no name matching: there is no string-distance helper in this repo to
  # reuse, and "Chase Checking" vs "CHASE COLLEGE CHECKING XXXX4421" is exactly where
  # fuzzy name matches go wrong.
  def balance_matched_account(candidates: nil)
    provider_balance = (current_balance || available_balance || 0).to_d

    linkable_accounts(candidates: candidates).find do |candidate|
      # Account.create_from_simplefin_account flips liability signs on create, so
      # compare against the balance we would have stored.
      expected = if %w[CreditCard Loan].include?(candidate.accountable_type)
        provider_balance.abs
      else
        provider_balance
      end

      (candidate.balance.to_d - expected).abs < BALANCE_MATCH_TOLERANCE
    end
  end

  private

    # If the provider was previously linked to a different account in this family, and
    # that account is now orphaned, quietly retire it so it disappears from the visible
    # manual list. Mirrors the unified flow expectation that the provider follows the
    # chosen account.
    def discard_orphaned_account(previous_account, target_account)
      return if previous_account.nil?
      return if previous_account.id == target_account.id
      return unless previous_account.family_id == target_account.family_id

      previous_account.reload

      # Only retire the previous account if it is truly orphaned (no other provider links)
      unless previous_account.account_providers.none?
        Rails.logger.info("Skipped disabling account ##{previous_account.id} after relink because it still has active provider links")
        return
      end

      # Disabled accounts still appear (greyed-out) in the manual list; for relink
      # consolidation we want the duplicate to disappear from the UI. Use the app's
      # standard deletion path (async) so the "pending_deletion" state stays truthful.
      previous_account.destroy_later if previous_account.may_mark_for_deletion?
    rescue => e
      Rails.logger.warn("Failed disabling-orphan check for account ##{previous_account&.id}: #{e.class} - #{e.message}")
    end
end
