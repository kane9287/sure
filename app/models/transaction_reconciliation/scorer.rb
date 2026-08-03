# Scores how likely it is that a user's manual point-of-sale capture and an
# incoming provider transaction describe the same purchase.
#
# Pure computation: no database access, no ActiveRecord. Both sides arrive as
# `Side` values, so every case in the scoring table is testable in isolation and
# threshold tuning can be argued against fixtures rather than production data.
#
# The single most important property of the weights below: a manual entry with
# no merchant and no discriminating name maxes out at
#   0.45 + 0.25 + (0.35 * 0.30) = 0.805
# which is structurally under AUTO_MERGE no matter how perfect the amount and
# date are. People type "Lunch" at the register; that must always reach a human.
# The weights were chosen so that inequality holds — changing any of them
# without re-checking it reintroduces silent merges on unidentifiable entries.
class TransactionReconciliation::Scorer
  # Normalized view of one side of a candidate pair. `amount` is signed, in the
  # side's own currency; sign equality is a hard gate, magnitude drives scoring.
  Side = Data.define(:amount, :currency, :date, :name, :merchant_id) do
    def initialize(amount:, currency:, date:, name: nil, merchant_id: nil)
      super(amount: amount.to_d, currency: currency, date: date.to_date,
            name: name, merchant_id: merchant_id)
    end
  end

  Result = Data.define(:score, :decision, :breakdown, :gate_failure) do
    def auto?   = decision == :auto
    def review? = decision == :review
    def ignore? = decision == :ignore
  end

  WEIGHT_AMOUNT = 0.45
  WEIGHT_DATE   = 0.25
  WEIGHT_NAME   = 0.30

  AUTO_MERGE       = 0.90
  REVIEW_FLOOR     = 0.70
  REVIEW_CEILING   = 0.89
  AMBIGUITY_MARGIN = 0.10
  CROWDED_FIELD    = 3

  CROSS_ACCOUNT_MULTIPLIER = 0.75
  CROWDED_FIELD_CAP        = 0.75

  # Hard gates. Any failure short-circuits to 0.0 / :ignore.
  AMOUNT_RATIO_RANGE = (0.85..1.35)
  DATE_DELTA_RANGE   = (-1..5)

  # Authorization precedes settlement, so manual_date <= provider_date is the
  # physical expectation. A table rather than a fitted curve: every cell is
  # individually arguable in review. The +5 cap sits between the existing
  # 8-day exact-amount and 3-day fuzzy-amount windows, since we are fuzzy on
  # both axes at once.
  DATE_SCORE = {
    -1 => 0.60, 0 => 1.00, 1 => 0.98, 2 => 0.92,
     3 => 0.84, 4 => 0.70, 5 => 0.55
  }.freeze

  NAME_EXACT        = 1.00
  NAME_PREFIX       = 0.90
  NAME_DICE_FLOOR   = 0.50
  NAME_UNIDENTIFIED = 0.35
  NAME_DISAGREE     = 0.10

  # Words people write when they are recording that they spent money, not who
  # they spent it with. Present in both sides constantly, so they carry no
  # matching signal.
  GENERIC_TOKENS = %w[
    lunch dinner breakfast coffee food groceries gas cash misc
    snack drinks restaurant store shop parking tip
  ].freeze

  # Payment-processor and card-network noise that prefixes the real merchant.
  PROCESSOR_PREFIXES = /\A(sq|tst|py|pp|ppd|sp|tsl)\s*\*+\s*/i
  NETWORK_NOISE      = /\b(pos|debit|credit|purchase|card|visa|mastercard|amex|authorization|auth|recurring|payment)\b/i

  # Shared with the fuzzy finders in Account::ProviderImportAdapter and
  # Entry — the first three tokens are what survives provider name churn.
  NAME_TOKEN_PREFIX_LENGTH = 3

  class << self
    def score(manual:, provider:, cross_account: false, runner_up_score: nil, viable_count: 1)
      new(manual:, provider:, cross_account:, runner_up_score:, viable_count:).call
    end
  end

  def initialize(manual:, provider:, cross_account: false, runner_up_score: nil, viable_count: 1)
    @manual          = manual
    @provider        = provider
    @cross_account   = cross_account
    @runner_up_score = runner_up_score
    @viable_count    = viable_count
  end

  def call
    failure = gate_failure
    return Result.new(score: 0.0, decision: :ignore, breakdown: {}, gate_failure: failure) if failure

    raw = (WEIGHT_AMOUNT * amount_score) +
          (WEIGHT_DATE   * date_score) +
          (WEIGHT_NAME   * name_score)

    final = apply_penalties(raw)

    Result.new(score: final, decision: decide(final), breakdown: breakdown(raw, final), gate_failure: nil)
  end

  private
    attr_reader :manual, :provider, :cross_account, :runner_up_score, :viable_count

    # ---- Hard gates -------------------------------------------------------

    def gate_failure
      return "currency_mismatch" unless manual.currency == provider.currency
      return "sign_mismatch"     unless same_sign?
      return "amount_ratio_out_of_range" unless AMOUNT_RATIO_RANGE.cover?(amount_ratio)
      return "date_delta_out_of_range"   unless DATE_DELTA_RANGE.cover?(date_delta)

      nil
    end

    # A $40 refund is not a $40 charge.
    def same_sign?
      manual.amount.negative? == provider.amount.negative? && !manual.amount.zero? && !provider.amount.zero?
    end

    def amount_ratio
      @amount_ratio ||= begin
        base = manual.amount.abs
        base.zero? ? 0.0 : (provider.amount.abs / base).to_f
      end
    end

    def date_delta
      @date_delta ||= (provider.date - manual.date).to_i
    end

    # ---- Signals ----------------------------------------------------------

    # Asymmetric on purpose. Card networks permit restaurant settlement well
    # above the authorized amount, so "posted higher than I recorded" has one
    # dominant benign cause: gratuity. "Posted lower" more often means a
    # genuinely different, smaller charge at the same merchant — hence a
    # downside slope 2.25x steeper than the upside.
    def amount_score
      r = amount_ratio

      if r >= 1.30
        0.80 - ((r - 1.30) / 0.05) * 0.30   # 1.30 -> 0.80, 1.35 -> 0.50
      elsif r >= 1.00
        1.0 - ((r - 1.00) / 0.30) * 0.20    # 1.00 -> 1.00, 1.30 -> 0.80
      else
        1.0 - ((1.00 - r) / 0.15) * 0.45    # 1.00 -> 1.00, 0.85 -> 0.55
      end
    end

    def date_score
      DATE_SCORE.fetch(date_delta)
    end

    # Tiered, best signal wins. Order matters: a one-token name like "Chipotle"
    # is not "unidentified" when it matches the provider exactly, so the
    # equality tiers are consulted before the generic-token floor.
    def name_score
      return NAME_EXACT if merchants_match?

      manual_name   = normalize_name(manual.name)
      provider_name = normalize_name(provider.name)

      return NAME_UNIDENTIFIED if manual_name.blank? || provider_name.blank?
      return NAME_EXACT        if manual_name == provider_name
      return NAME_PREFIX       if prefix_match?(manual_name, provider_name)
      return NAME_PREFIX       if token_prefix(manual_name) == token_prefix(provider_name)

      dice = dice_coefficient(manual_name, provider_name)
      return dice if dice >= NAME_DICE_FLOOR
      return NAME_UNIDENTIFIED if unidentified?(manual_name)

      NAME_DISAGREE
    end

    def merchants_match?
      manual.merchant_id.present? && provider.merchant_id.present? &&
        manual.merchant_id == provider.merchant_id
    end

    def prefix_match?(left, right)
      return false if left.length < 4 || right.length < 4

      left.start_with?(right) || right.start_with?(left)
    end

    # The user recorded that money left, but not who took it. Nothing here can
    # distinguish this purchase from any other at any merchant.
    def unidentified?(manual_name)
      tokens = manual_name.split
      return true if tokens.all? { |token| GENERIC_TOKENS.include?(token) }

      tokens.size <= 1 && manual.merchant_id.blank?
    end

    def normalize_name(name)
      return "" if name.blank?

      name.to_s
          .downcase
          .sub(PROCESSOR_PREFIXES, "")
          .gsub(NETWORK_NOISE, " ")
          .gsub(/#\d+/, " ")
          .gsub(/\b\d{3,}\b/, " ")
          .gsub(/[^a-z0-9\s]/, " ")
          .squish
    end

    def token_prefix(normalized)
      normalized.split.first(NAME_TOKEN_PREFIX_LENGTH).join(" ")
    end

    def dice_coefficient(left, right)
      left_tokens  = left.split.to_set
      right_tokens = right.split.to_set
      return 0.0 if left_tokens.empty? || right_tokens.empty?

      (2.0 * (left_tokens & right_tokens).size) / (left_tokens.size + right_tokens.size)
    end

    # ---- Penalties --------------------------------------------------------

    # Hard caps, not multipliers. A smooth penalty would still let a three-way
    # tie of near-1.0 scores clear the auto threshold, which is precisely the
    # case where picking one of them is a coin flip. This generalizes the
    # existing "only match if EXACTLY ONE candidate" rule from a boolean into
    # a margin.
    def apply_penalties(raw)
      score = raw

      if cross_account
        score = [ score * CROSS_ACCOUNT_MULTIPLIER, REVIEW_CEILING ].min
      end

      if viable_count >= CROWDED_FIELD
        score = [ score, CROWDED_FIELD_CAP ].min
      end

      if runner_up_score.present? && (raw - runner_up_score) < AMBIGUITY_MARGIN
        score = [ score, REVIEW_CEILING ].min
      end

      score.round(4)
    end

    def decide(score)
      return :auto   if score >= AUTO_MERGE
      return :review if score >= REVIEW_FLOOR

      :ignore
    end

    def breakdown(raw, final)
      {
        "amount" => {
          "ratio" => amount_ratio.round(4),
          "score" => amount_score.round(4),
          "weighted" => (WEIGHT_AMOUNT * amount_score).round(4)
        },
        "date" => {
          "delta_days" => date_delta,
          "score" => date_score,
          "weighted" => (WEIGHT_DATE * date_score).round(4)
        },
        "name" => {
          "score" => name_score.round(4),
          "weighted" => (WEIGHT_NAME * name_score).round(4),
          "merchant_match" => merchants_match?
        },
        "raw" => raw.round(4),
        "final" => final,
        "cross_account" => cross_account,
        "viable_count" => viable_count,
        "runner_up" => runner_up_score&.round(4)
      }
    end
end
