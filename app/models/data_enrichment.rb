class DataEnrichment < ApplicationRecord
  belongs_to :enrichable, polymorphic: true

  enum :source, {
    rule: "rule",
    plaid: "plaid",
    simplefin: "simplefin",
    lunchflow: "lunchflow",
    akahu: "akahu",
    up: "up",
    synth: "synth",
    ai: "ai",
    enable_banking: "enable_banking",
    coinstats: "coinstats",
    mercury: "mercury",
    brex: "brex",
    indexa_capital: "indexa_capital",
    sophtron: "sophtron",
    ibkr: "ibkr",
    questrade: "questrade",
    redbark: "redbark",
    # Not a provider: TransactionReconciliation::Merger attributes gap-filling
    # backfills to the merge itself, so the audit trail distinguishes "the user
    # approved a match" from "a provider sync wrote this".
    reconciliation: "reconciliation"
  }
end
