module TransactionReconciliationsHelper
  # Green reads as "this is fine, go ahead"; amber as "look closer". Low
  # confidence gets neutral rather than red — a weak match is not an error, and
  # colouring it as one would push people to reject good pairs on sight.
  CONFIDENCE_TONES = { high: :success, medium: :warning, low: :neutral }.freeze

  def reconciliation_confidence_tone(reconciliation)
    CONFIDENCE_TONES.fetch(reconciliation.confidence_band, :neutral)
  end

  def reconciliation_confidence_label(reconciliation)
    t("transaction_reconciliations.confidence.#{reconciliation.confidence_band}")
  end

  # One line saying why these two were paired, from the two strongest signals.
  # Without it the card is asking the user to trust a number they can't inspect.
  def reconciliation_reason(reconciliation)
    signals = reconciliation.top_signals.map { |key| t("transaction_reconciliations.signals.#{key}") }
    return nil if signals.empty?

    t("transaction_reconciliations.reconciliation_card.reason", signals: signals.to_sentence)
  end

  def reconciliation_date_delta_label(reconciliation)
    days = reconciliation.date_delta_days
    return nil if days.blank? || days.to_i.zero?

    key = days.to_i.negative? ? "date_delta_earlier" : "date_delta_later"
    t("transaction_reconciliations.reconciliation_card.#{key}", count: days.to_i.abs)
  end

  # A charge that posted higher than the receipt is the norm at restaurants, so
  # the delta is labelled rather than left to read as a discrepancy.
  def reconciliation_amount_delta_label(reconciliation)
    return nil unless reconciliation.amount_delta?

    key = if reconciliation.likely_gratuity?
      "amount_delta_gratuity"
    elsif reconciliation.provider_higher?
      "amount_delta_higher"
    else
      "amount_delta_lower"
    end

    t("transaction_reconciliations.reconciliation_card.#{key}",
      amount: format_money(reconciliation.amount_delta))
  end
end
