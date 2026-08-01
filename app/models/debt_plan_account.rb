class DebtPlanAccount < ApplicationRecord
  belongs_to :debt_plan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :debt_plan_id }
  validates :apr_override, numericality: { greater_than_or_equal_to: 0, less_than: 1000 }, allow_nil: true
  validates :minimum_payment_override, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  def debt
    DebtPlan::Debt.from_link(self)
  end
end
