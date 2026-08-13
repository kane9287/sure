# Applies a family's active rules after a sync brings in new data.
#
# Unlike ApplyAllRulesJob (the manual "Apply all" button), this runs automatically,
# so it only touches active rules and respects attribute locks — a user's manual
# edits are never overwritten by a background run.
#
# The unique lock is keyed on the family and released once the job starts, so
# overlapping syncs collapse into a single queued pass while a sync that finishes
# later still gets a fresh run.
class ApplyFamilyRulesJob < ApplicationJob
  queue_as :medium_priority
  sidekiq_options lock: :until_executing, lock_args: ->(args) { [ args.first ] }, on_conflict: :log

  def perform(family, execution_type: "scheduled")
    family.rules.where(active: true).find_each do |rule|
      RuleJob.perform_now(rule, execution_type: execution_type)
    end
  end
end
