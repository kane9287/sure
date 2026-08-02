class AddEnvelopeTargetsToGoals < ActiveRecord::Migration[7.2]
  def change
    # The category envelope this goal is saved into. Funding that envelope is
    # what moves money toward the goal, so the goal itself never withholds cash
    # from the Unassigned pool (see Family#unassigned_pool_balance). NULL keeps
    # the account-backed behaviour goals shipped with.
    add_column :goals, :category_id, :uuid, null: true
    add_foreign_key :goals, :categories
    add_index :goals, :category_id

    # User-declared "save this much per month", YNAB-target style. NULL means
    # derive it from the target amount and date, which is what
    # Goal#monthly_target_amount has always done — and which returns nil for an
    # open-ended goal. A declared amount gives those a monthly figure too.
    add_column :goals, :monthly_contribution, :decimal, precision: 19, scale: 4, null: true

    # "envelope": progress is the linked category's rolling envelope balance
    # rather than an account balance. Third value alongside the existing
    # "balance" / "contributions" (see AddProgressBasisToGoals).
    remove_check_constraint :goals, name: "chk_goals_progress_basis_enum"
    add_check_constraint :goals,
                         "progress_basis IN ('balance','contributions','envelope')",
                         name: "chk_goals_progress_basis_enum"
  end
end
