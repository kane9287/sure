# A proposed or completed pairing between a manual point-of-sale capture and
# the provider transaction representing the same purchase.
#
# One row plays three roles over its life:
#   - the review queue item, while status is `pending`
#   - the audit record of a merge, once `confirmed` or `auto_merged`
#   - the tombstone that stops a `rejected` or `undone` pair from being
#     re-proposed on the next sync
#
# The survivor of a merge is always the manual entry, so its UUID never
# changes and everything keyed to it — tags, attachments, splits, transfer
# links — comes through untouched.
class TransactionReconciliation < ApplicationRecord
  belongs_to :family
  belongs_to :manual_entry,     class_name: "Entry"
  belongs_to :provider_entry,   class_name: "Entry", optional: true
  belongs_to :resolved_by_user, class_name: "User",  optional: true

  enum :status, {
    pending: "pending",
    auto_merged: "auto_merged",
    confirmed: "confirmed",
    rejected: "rejected",
    undone: "undone",
    expired: "expired"
  }

  REVIEW_TTL_DAYS      = 30
  RECENTLY_MERGED_DAYS = 14

  scope :actionable,      -> { where(status: :pending) }
  scope :blocking,        -> { where(status: %i[rejected undone]) }
  scope :recently_merged, -> { auto_merged.where(matched_at: RECENTLY_MERGED_DAYS.days.ago..) }
  scope :ordered,         -> { order(confidence: :desc, matched_at: :desc) }

  validates :provider_external_id, :provider_source, presence: true
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }

  # How far apart the two amounts are, as a positive magnitude. Direction is
  # `provider_higher?` rather than the sign, so a refund pair reads the same way
  # as a purchase pair instead of inverting.
  def amount_delta
    return nil unless provider_amount && manual_entry

    Money.new((provider_amount.abs - manual_entry.amount.abs).abs, manual_entry.currency)
  end

  def amount_delta?
    amount_delta.present? && !amount_delta.amount.zero?
  end

  def amount_ratio
    score_breakdown.dig("amount", "ratio")
  end

  def provider_higher?
    amount_ratio.to_f > 1.0
  end

  def provider_money
    return nil unless provider_amount

    Money.new(provider_amount, snapshot.dig("provider_payload", "currency") || manual_entry.currency)
  end

  def date_delta_days
    score_breakdown.dig("date", "delta_days")
  end

  # The overwhelmingly common reason a restaurant charge posts higher than the
  # amount on the receipt. Worth saying out loud in the UI so the delta doesn't
  # read as an error.
  def likely_gratuity?
    amount_ratio.present? && amount_ratio > 1.0 && amount_ratio <= 1.30
  end

  def confidence_band
    return :high   if confidence >= 0.90
    return :medium if confidence >= 0.80

    :low
  end

  # The two signals that contributed most, so the card can explain itself in
  # one line rather than dumping the whole breakdown.
  def top_signals
    %w[amount date name]
      .filter_map { |key| [ key, score_breakdown.dig(key, "weighted") ] if score_breakdown[key].is_a?(Hash) }
      .sort_by { |(_key, weighted)| -weighted.to_f }
      .first(2)
      .map(&:first)
  end

  def provider_amount
    value = snapshot.dig("provider_payload", "amount")
    value&.to_d
  end

  def provider_date
    value = snapshot.dig("provider_payload", "date")
    value.present? ? Date.parse(value.to_s) : nil
  end

  def provider_name
    snapshot.dig("provider_payload", "name")
  end

  def resolvable?
    pending?
  end

  def resolve!(status:, user:)
    update!(status: status, resolved_at: Time.current, resolved_by_user: user)
  end
end
