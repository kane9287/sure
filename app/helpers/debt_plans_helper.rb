module DebtPlansHelper
  # "3 yrs 4 mos" / "8 mos" / "5 yrs". Purely a display concern — the engine
  # only ever reports a month count.
  def debt_payoff_duration(result)
    return nil unless result.paid_off?

    years = result.years_to_payoff
    months = result.remainder_months

    if years.zero?
      t("debt_plans.duration.months", count: months)
    elsif months.zero?
      t("debt_plans.duration.years", count: years)
    else
      t("debt_plans.duration.years_months",
        years: t("debt_plans.duration.years", count: years),
        months: t("debt_plans.duration.months", count: months))
    end
  end

  def debt_payoff_status_tone(result)
    result.paid_off? ? :success : :warning
  end
end
