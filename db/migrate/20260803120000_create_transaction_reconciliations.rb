class CreateTransactionReconciliations < ActiveRecord::Migration[8.1]
  def change
    # Pair record linking a user's manual point-of-sale capture to the provider
    # transaction representing the same purchase. Serves three roles: the review
    # queue row when confidence is below the auto-merge threshold, the reversible
    # audit record when the merge happened silently, and the tombstone that stops
    # a rejected or undone pair from being re-proposed.
    #
    # The survivor is always the manual entry, so its UUID is stable and
    # everything keyed to it (tags, attachments, splits) survives untouched.
    create_table :transaction_reconciliations, id: :uuid do |t|
      # Denormalized from manual_entry -> account -> family. The nav badge counts
      # pending rows on every page render; a three-table join there is not viable.
      # index: false — the composite indexes below all lead with family_id.
      t.references :family, null: false, type: :uuid,
                   foreign_key: { on_delete: :cascade }, index: false

      t.references :manual_entry, null: false, type: :uuid,
                   foreign_key: { to_table: :entries, on_delete: :cascade }

      # NULL for silent auto-merges, where the provider transaction claimed the
      # manual row before any row was created for it — its payload lives in
      # `snapshot`. Nullify, not cascade: losing the provider row must not erase
      # the audit trail.
      t.references :provider_entry, null: true, type: :uuid,
                   foreign_key: { to_table: :entries, on_delete: :nullify }

      # NOT NULL by design: a reconciliation can only exist because a real
      # provider transaction arrived. This is the structural guarantee that the
      # feature never nags on an unlinked account, where no counterpart will come.
      t.string :provider_external_id, null: false
      t.string :provider_source,      null: false

      t.string :status, null: false, default: "pending"

      # 0..1 from TransactionReconciliation::Scorer. Not money, so not 19,4.
      t.decimal :confidence, precision: 5, scale: 4, null: false

      # Per-signal contributions plus runners-up, so the UI can explain "why"
      # and threshold tuning is debuggable from production data.
      t.jsonb :score_breakdown, null: false, default: {}

      # Everything needed to reverse the merge: the manual entry's pre-merge
      # attributes (including locked_attributes verbatim) and the full provider
      # payload, so undo can restore one side and recreate the other.
      t.jsonb :snapshot, null: false, default: {}

      # Two sides on different accounts in the same family. Suggestion-only.
      t.boolean :cross_account, null: false, default: false

      t.datetime :matched_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :resolved_at
      t.references :resolved_by_user, null: true, type: :uuid,
                   foreign_key: { to_table: :users, on_delete: :nullify }

      t.timestamps
    end

    add_check_constraint :transaction_reconciliations,
      "status IN ('pending','auto_merged','confirmed','rejected','undone','expired')",
      name: "chk_transaction_reconciliations_status_enum"

    add_check_constraint :transaction_reconciliations,
      "confidence >= 0 AND confidence <= 1",
      name: "chk_transaction_reconciliations_confidence_range"

    add_index :transaction_reconciliations, [ :family_id, :status ]

    add_index :transaction_reconciliations,
              [ :manual_entry_id, :provider_source, :provider_external_id ],
              unique: true,
              name: "index_transaction_reconciliations_on_pair"
  end
end
