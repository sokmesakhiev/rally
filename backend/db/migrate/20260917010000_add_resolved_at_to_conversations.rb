# frozen_string_literal: true

# When a support thread was closed, so that retention can be enforced against
# it (Conversation::RETENTION_PERIOD — 12 months after resolution, swept by
# Conversations::SweepResolved).
#
# A dedicated column rather than reusing something that already exists:
#
#   * `updated_at` moves on every touch — a read stamp, an assignment, an
#     unassignment — so a thread nobody has looked at in a year could still
#     look freshly updated because an agent scrolled past it.
#   * `last_message_at` is *activity*, not resolution, and it is nullable. It
#     also moves again if the participant writes into an already-resolved
#     thread, which is allowed (Conversations::PostMessage leaves resolved
#     threads resolved).
#
# The privacy policy states a specific number, so the column it's enforced
# against has to mean exactly what the policy says.
class AddResolvedAtToConversations < ActiveRecord::Migration[8.1]
  def up
    add_column :conversations, :resolved_at, :datetime

    # Backfill: existing resolved threads have no record of when they closed.
    # `last_message_at` is the closest available proxy — Conversations::Resolve
    # writes a system notice as the final act of resolving, so for anything
    # resolved through the app it *is* the resolution time to within a second.
    # COALESCE to updated_at for the handful with no messages at all.
    #
    # Backfilling rather than leaving NULL is deliberate: the sweep only
    # purges rows whose resolved_at is old, so NULL would mean these threads
    # are never purged — silently exempting exactly the oldest data from the
    # retention policy it most needs to apply to.
    execute <<~SQL.squish
      UPDATE conversations
         SET resolved_at = COALESCE(last_message_at, updated_at)
       WHERE status = 'resolved'
         AND resolved_at IS NULL
    SQL

    # Partial: the sweep only ever looks at resolved rows, and live threads are
    # the majority.
    add_index :conversations, :resolved_at, where: "resolved_at IS NOT NULL"
  end

  def down
    remove_column :conversations, :resolved_at
  end
end
