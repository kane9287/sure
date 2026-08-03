require "test_helper"

class TransactionReconciliation::ScorerTest < ActiveSupport::TestCase
  Scorer = TransactionReconciliation::Scorer

  MERCHANT_ID = "11111111-1111-1111-1111-111111111111".freeze
  OTHER_MERCHANT_ID = "22222222-2222-2222-2222-222222222222".freeze
  BASE_DATE = Date.new(2026, 8, 1)

  # Bands, not exact floats. The weights are meant to be tunable; pinning them
  # to four decimals would turn every tuning pass into a test rewrite, which is
  # the opposite of what these tests are for.
  test "scores the worked cases into the intended decision bands" do
    cases = [
      # [ description, manual, provider, expected_decision ]
      [ "tip on a matched merchant, posted 2 days later",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 47.20, date: BASE_DATE + 2, merchant_id: MERCHANT_ID },
        :auto ],

      [ "same, posted 3 days later",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 47.20, date: BASE_DATE + 3, merchant_id: MERCHANT_ID },
        :auto ],

      [ "same, posted 4 days later — the date drift alone drops it to review",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 47.20, date: BASE_DATE + 4, merchant_id: MERCHANT_ID },
        :review ],

      [ "exact amount 4 days later still auto-merges",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 40, date: BASE_DATE + 4, merchant_id: MERCHANT_ID },
        :auto ],

      [ "posted slightly lower",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 38, date: BASE_DATE, merchant_id: MERCHANT_ID },
        :auto ],

      [ "posted at the bottom of the range — a different, smaller charge is plausible",
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 34, date: BASE_DATE, merchant_id: MERCHANT_ID },
        :review ]
    ]

    cases.each do |description, manual, provider, expected|
      result = score(side(**manual), side(**provider))

      assert_equal expected, result.decision,
        "#{description}: expected #{expected}, got #{result.decision} at #{result.score}"
    end
  end

  # The property the whole safety argument rests on. People write "Lunch" at the
  # register; with no merchant and no discriminating name, a perfect amount and
  # a perfect date still cannot reach the auto threshold.
  test "an unidentifiable manual entry never auto-merges, even on a perfect amount and date" do
    result = score(
      side(amount: 40, date: BASE_DATE, name: "Lunch"),
      side(amount: 40, date: BASE_DATE, name: "CHIPOTLE 1234", merchant_id: MERCHANT_ID)
    )

    assert_predicate result, :review?
    assert_operator result.score, :<, Scorer::AUTO_MERGE
  end

  test "a generic name with a tip and date drift lands in review" do
    result = score(
      side(amount: 40, date: BASE_DATE, name: "Lunch"),
      side(amount: 47.20, date: BASE_DATE + 2, name: "CHIPOTLE 1234", merchant_id: MERCHANT_ID)
    )

    assert_predicate result, :review?
  end

  # A single-token name is only "unidentified" when nothing else agrees with it.
  # If it matches the provider outright it is the strongest signal on the card.
  test "a single-token name that matches the provider is not treated as generic" do
    generic = score(
      side(amount: 40, date: BASE_DATE, name: "Lunch"),
      side(amount: 40, date: BASE_DATE, name: "Chipotle")
    )

    matching = score(
      side(amount: 40, date: BASE_DATE, name: "Chipotle"),
      side(amount: 40, date: BASE_DATE, name: "Chipotle")
    )

    assert_operator matching.score, :>, generic.score
    assert_predicate matching, :auto?
  end

  # A merchant mismatch is not a veto. Providers mint their own ProviderMerchant
  # rows, so a user who picked a family merchant will disagree with the provider
  # on id far more often than they disagree on who they paid — the ids only ever
  # promote a pair, never sink one.
  test "differing merchant ids fall through to the name signal instead of vetoing" do
    result = score(
      side(amount: 40, date: BASE_DATE, name: "Chipotle", merchant_id: MERCHANT_ID),
      side(amount: 40, date: BASE_DATE, name: "Chipotle", merchant_id: OTHER_MERCHANT_ID)
    )

    assert_predicate result, :auto?
    assert_not result.breakdown.dig("name", "merchant_match")
  end

  test "processor prefixes and card-network noise are stripped before comparison" do
    result = score(
      side(amount: 40, date: BASE_DATE, name: "Blue Bottle Coffee"),
      side(amount: 40, date: BASE_DATE, name: "SQ *BLUE BOTTLE COFFEE #4471")
    )

    assert_predicate result, :auto?
  end

  # Regression for a missed real-world pair: "payment" wasn't stripped as
  # network noise, so "affirm - direct payment" kept a token "samsung affirm"
  # didn't have, dropping the Dice coefficient below NAME_DICE_FLOOR and
  # scoring the pair as an active mismatch instead of a partial match.
  test "network-noise 'payment' is stripped so a partial merchant match still reaches review" do
    [ 1, -1 ].each do |date_delta|
      result = score(
        side(amount: 40, date: BASE_DATE, name: "samsung affirm"),
        side(amount: 40, date: BASE_DATE + date_delta, name: "affirm - direct payment")
      )

      assert_predicate result, :review?, "date_delta #{date_delta}: expected review, got #{result.decision} at #{result.score}"
    end
  end

  test "hard gates ignore pairs outside the envelope" do
    gate_cases = {
      "amount ratio above the ceiling" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 56, date: BASE_DATE, merchant_id: MERCHANT_ID }
      ],
      "amount ratio below the floor" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 30, date: BASE_DATE, merchant_id: MERCHANT_ID }
      ],
      "posted too long after" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 40, date: BASE_DATE + 6, merchant_id: MERCHANT_ID }
      ],
      "posted too long before" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 40, date: BASE_DATE - 2, merchant_id: MERCHANT_ID }
      ],
      "a refund is not a charge" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: -40, date: BASE_DATE, merchant_id: MERCHANT_ID }
      ],
      "different currencies" => [
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID },
        { amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID, currency: "EUR" }
      ]
    }

    gate_cases.each do |description, (manual, provider)|
      result = score(side(**manual), side(**provider))

      assert_predicate result, :ignore?, "#{description} should have been gated out"
      assert_equal 0.0, result.score
      assert_not_nil result.gate_failure, "#{description} should record why it was gated"
    end
  end

  test "a close runner-up caps an otherwise perfect match below the auto threshold" do
    manual   = side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID)
    provider = side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID)

    uncontested = score(manual, provider)
    contested   = score(manual, provider, runner_up_score: 0.97)

    assert_predicate uncontested, :auto?
    assert_predicate contested, :review?
    assert_operator contested.score, :<=, Scorer::REVIEW_CEILING
  end

  test "a crowded field caps the winner harder than a single close rival" do
    result = score(
      side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID),
      side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID),
      viable_count: 3
    )

    assert_operator result.score, :<=, Scorer::CROWDED_FIELD_CAP
  end

  test "cross-account pairs never auto-merge even when otherwise perfect" do
    result = score(
      side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID),
      side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID),
      cross_account: true
    )

    assert_predicate result, :review?
    assert_operator result.score, :<, Scorer::AUTO_MERGE
  end

  test "names that genuinely disagree drop the pair out of review entirely" do
    result = score(
      side(amount: 40, date: BASE_DATE + 0, name: "Blue Bottle Coffee"),
      side(amount: 34.5, date: BASE_DATE + 4, name: "SHELL OIL")
    )

    assert_predicate result, :ignore?
  end

  test "breakdown explains every signal it used" do
    result = score(
      side(amount: 40, date: BASE_DATE, merchant_id: MERCHANT_ID),
      side(amount: 47.20, date: BASE_DATE + 2, merchant_id: MERCHANT_ID)
    )

    assert_equal 2, result.breakdown.dig("date", "delta_days")
    assert result.breakdown.dig("name", "merchant_match")
    assert_in_delta 1.18, result.breakdown.dig("amount", "ratio"), 0.0001
    assert_equal result.score, result.breakdown["final"]
  end

  private
    def side(amount:, date:, name: nil, merchant_id: nil, currency: "USD")
      Scorer::Side.new(amount: amount, currency: currency, date: date, name: name, merchant_id: merchant_id)
    end

    def score(manual, provider, **options)
      Scorer.score(manual: manual, provider: provider, **options)
    end
end
