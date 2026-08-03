# Finds the manual point-of-sale capture, if any, that an incoming provider
# transaction represents.
#
# Called inline from Account::ProviderImportAdapter#import_transaction, at the
# point where the provider row does not exist yet. That timing is what makes
# the whole design cheap: there is nothing to destroy and nothing to suppress
# on re-import, because the manual entry simply absorbs the provider's
# identity and is then found by the ordinary find_or_initialize_by path on
# every subsequent sync.
class TransactionReconciliation::Matcher
  Scorer = TransactionReconciliation::Scorer

  # Everything the caller needs to either act on the match or record it for
  # review, without going back to the database.
  Decision = Data.define(:manual_entry, :outcome, :result, :provider, :payload, :cross_account) do
    def auto?   = outcome == :auto
    def review? = outcome == :review
    def confidence = result.score
  end

  def initialize(account:, mode: "review_only")
    @account = account
    @mode    = mode
  end

  def call(external_id:, source:, amount:, currency:, date:, name: nil, merchant_id: nil)
    return nil if @mode == "off"

    provider = Scorer::Side.new(
      amount: amount, currency: currency, date: date, name: name, merchant_id: merchant_id
    )

    scored = candidates(provider, source: source, external_id: external_id)
               .map { |entry| [ entry, Scorer.score(manual: side_for(entry), provider: provider) ] }
               .reject { |(_entry, result)| result.ignore? }
               .sort_by { |(_entry, result)| -result.score }

    return nil if scored.empty?

    winner, = scored.first
    runner_up = scored.dig(1, 1)&.score

    # Second pass. The first pass measures each candidate on its own merits;
    # only now, knowing how crowded the field is and how close the runner-up
    # came, can the ambiguity caps be applied. Scoring once with the caps baked
    # in would need the runner-up before it existed.
    result = Scorer.score(
      manual: side_for(winner),
      provider: provider,
      cross_account: false,
      runner_up_score: runner_up,
      viable_count: scored.size
    )

    return nil if result.ignore?

    Decision.new(
      manual_entry: winner,
      outcome: outcome_for(result),
      result: result,
      provider: provider,
      payload: payload_for(provider, external_id: external_id, source: source),
      cross_account: false
    )
  end

  private
    attr_reader :account, :mode

    # Silent mutation is a family-level opt-in. Under "review_only" a match
    # good enough to auto-merge is still recorded, at its true confidence, and
    # routed to a human — which is what lets the thresholds be argued against
    # real data before anything fires on its own.
    def outcome_for(result)
      return :auto if result.auto? && mode == "auto"

      :review
    end

    # Narrowed in SQL to the envelope the scorer's hard gates would accept
    # anyway, so the common case loads a handful of rows rather than a month.
    def candidates(provider, source:, external_id:)
      magnitude = provider.amount.abs

      scope = account.entries
                     .manual_capture
                     .where(currency: provider.currency)
                     .where(date: date_window(provider.date))
                     .where("ABS(entries.amount) BETWEEN ? AND ?",
                            magnitude / Scorer::AMOUNT_RATIO_RANGE.max,
                            magnitude / Scorer::AMOUNT_RATIO_RANGE.min)
                     .where(provider.amount.negative? ? "entries.amount < 0" : "entries.amount > 0")
                     .where.not(id: open_review_entry_ids)
                     .where.not(id: blocked_entry_ids(source: source, external_id: external_id))
                     .select("entries.*, transactions.merchant_id AS reconciliation_merchant_id")

      scope.to_a
    end

    # provider_date - manual_date must land in DATE_DELTA_RANGE, so the manual
    # entry sits from five days before the posting to one day after it.
    def date_window(provider_date)
      (provider_date - Scorer::DATE_DELTA_RANGE.max)..(provider_date - Scorer::DATE_DELTA_RANGE.min)
    end

    # One open question per manual entry. Without this, a provider that sends a
    # pending row and then a posted row under a *different* external id would
    # raise a second card for the same purchase, since the posted row is a new
    # record at this point in the import and the pending→posted claim happens
    # further down.
    def open_review_entry_ids
      TransactionReconciliation
        .actionable
        .where(family_id: account.family_id)
        .select(:manual_entry_id)
    end

    # A pair the user already rejected, or a merge they already undid. Keyed on
    # provider source + external id rather than entry ids, because undo
    # recreates the provider row with a fresh UUID.
    def blocked_entry_ids(source:, external_id:)
      TransactionReconciliation
        .blocking
        .where(provider_source: source, provider_external_id: external_id)
        .select(:manual_entry_id)
    end

    def side_for(entry)
      Scorer::Side.new(
        amount: entry.amount,
        currency: entry.currency,
        date: entry.date,
        name: entry.name,
        merchant_id: entry.reconciliation_merchant_id
      )
    end

    # Enough of the provider payload to rebuild the row on undo, and to render
    # the "they posted this" side of the review card without a second query.
    def payload_for(provider, external_id:, source:)
      {
        "external_id" => external_id,
        "source" => source,
        "amount" => provider.amount.to_s,
        "currency" => provider.currency,
        "date" => provider.date.to_s,
        "name" => provider.name,
        "merchant_id" => provider.merchant_id
      }
    end
end
