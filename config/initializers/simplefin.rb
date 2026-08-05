Rails.application.configure do
  truthy = %w[1 true yes on]
  falsy = %w[0 false no off]

  config.x.simplefin ||= ActiveSupport::OrderedOptions.new
  # Default to true - always fetch pending transactions so they can be:
  # - Displayed with a "Pending" badge
  # - Excluded from budgets (but included in net worth)
  # - Reconciled when posted versions arrive (avoiding duplicates)
  # - Auto-excluded after 8 days if they remain stale
  # Set SIMPLEFIN_INCLUDE_PENDING=0 to disable if a bank's integration causes issues
  pending_env = ENV["SIMPLEFIN_INCLUDE_PENDING"].to_s.strip.downcase
  config.x.simplefin.include_pending = pending_env.blank? ? true : !falsy.include?(pending_env)
  config.x.simplefin.debug_raw = truthy.include?(ENV["SIMPLEFIN_DEBUG_RAW"].to_s.strip.downcase)

  # Default to true - preserves the long-standing behaviour of storing SimpleFIN's memo
  # on the transaction's notes field. Set SIMPLEFIN_IMPORT_NOTES=0 if you reserve notes
  # for your own annotations and don't want a provider memo on every transaction.
  import_notes_env = ENV["SIMPLEFIN_IMPORT_NOTES"].to_s.strip.downcase
  config.x.simplefin.import_notes = import_notes_env.blank? ? true : !falsy.include?(import_notes_env)

  # Common money market fund tickers that should be treated as cash equivalents
  # These are settlement funds that users consider "cash available to invest"
  # SimpleFIN doesn't provide is_cash_equivalent metadata like Plaid does,
  # so we detect by ticker symbol and description patterns
  config.x.simplefin.money_market_tickers = %w[
    VMFXX VMMXX VMRXX VUSXX
    SPAXX FDRXX SPRXX FZFXX FDLXX
    SWVXX SNVXX SNOXX
    TTTXX PRTXX
  ].freeze

  # Patterns that indicate money market funds (case-insensitive)
  config.x.simplefin.money_market_patterns = [
    /money\s*market/i,
    /settlement\s*fund/i,
    /cash\s*reserve/i
  ].freeze
end
