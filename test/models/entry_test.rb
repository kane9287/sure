require "test_helper"

class EntryTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "chronological ordering uses id as final tie breaker" do
    account = accounts(:depository)
    timestamp = Time.zone.parse("2026-05-05 12:00:00")

    entries = 3.times.map do |index|
      create_transaction(
        account: account,
        name: "Same timestamp transaction #{index}",
        date: Date.new(2026, 5, 5),
        created_at: timestamp,
        updated_at: timestamp
      )
    end

    entry_ids = entries.map(&:id)

    assert_equal entry_ids.sort, Entry.where(id: entry_ids).chronological.pluck(:id)
    assert_equal entry_ids.sort.reverse, Entry.where(id: entry_ids).reverse_chronological.pluck(:id)
  end

  test "notes_merged_with keeps the user note when the provider sends nothing" do
    entry = create_transaction(notes: "split with Sam")

    assert_equal "split with Sam", entry.notes_merged_with(nil)
    assert_equal "split with Sam", entry.notes_merged_with("   ")
  end

  test "notes_merged_with takes the provider memo when there is no user note" do
    entry = create_transaction

    assert_equal "CHIPOTLE 1234 PORTLAND OR", entry.notes_merged_with("CHIPOTLE 1234 PORTLAND OR")
  end

  test "notes_merged_with appends the provider memo below the user note" do
    entry = create_transaction(notes: "split with Sam")

    assert_equal "split with Sam\n\nCHIPOTLE 1234", entry.notes_merged_with("CHIPOTLE 1234")
  end

  # The guard that keeps a nightly sync from growing the note forever.
  test "notes_merged_with does not append a memo it already contains" do
    entry = create_transaction(notes: "split with Sam\n\nCHIPOTLE 1234")

    assert_equal "split with Sam\n\nCHIPOTLE 1234", entry.notes_merged_with("CHIPOTLE 1234")
  end
end
