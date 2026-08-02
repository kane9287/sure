class AddInBudgetToAccounts < ActiveRecord::Migration[7.2]
  def change
    # Whether this account's cash counts toward the family's envelope
    # Unassigned pool (Family#unassigned_pool_balance). Distinct from
    # exclude_from_reports: an account can be excluded from net-worth/report
    # rollups but still fund the budget, or vice versa (e.g. an escrow
    # account included in reports but not spendable budget cash).
    add_column :accounts, :in_budget, :boolean, default: true, null: false
  end
end
