class BudgetAllocation < ApplicationRecord
  include Monetizable

  belongs_to :family
  belongs_to :category

  monetize :amount

  validates :amount, presence: true, numericality: { other_than: 0 }
  validates :date, :currency, :kind, presence: true
  validate :category_belongs_to_family
  validate :amount_sign_matches_kind

  scope :funds, -> { where(kind: "fund") }
  scope :sweeps, -> { where(kind: "sweep") }
  scope :for_category, ->(category) { where(category: category) }
  scope :since, ->(date) { where("budget_allocations.date >= ?", date) }

  # Net amount funded into `category` since `since_date` (fund - sweep), the
  # building block for the envelope's rolling balance (see
  # BudgetCategory#envelope_available_to_spend).
  def self.net_allocated(family:, category:, since_date:)
    family.budget_allocations.for_category(category).since(since_date).sum(:amount)
  end

  # Net amount funded across all categories since `since_date`, used to
  # compute the family's Unassigned pool (Family#unassigned_pool_balance).
  def self.total_allocated(family:, since_date:)
    family.budget_allocations.since(since_date).sum(:amount)
  end

  private
    def category_belongs_to_family
      return if category.nil? || family.nil?
      errors.add(:category, :must_belong_to_family) unless category.family_id == family_id
    end

    # "fund" moves money Unassigned -> envelope (positive); "sweep" moves it
    # back (negative). Enforcing the sign here keeps net_allocated a simple
    # sum instead of needing to branch on kind at every call site.
    def amount_sign_matches_kind
      return if amount.blank? || kind.blank?

      if kind == "fund" && amount.to_d <= 0
        errors.add(:amount, :must_be_positive_for_fund)
      elsif kind == "sweep" && amount.to_d >= 0
        errors.add(:amount, :must_be_negative_for_sweep)
      end
    end
end
