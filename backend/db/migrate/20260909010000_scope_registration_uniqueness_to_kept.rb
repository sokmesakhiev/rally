class ScopeRegistrationUniquenessToKept < ActiveRecord::Migration[8.1]
  # The unique index on (event_id, user_id) was total, so it counted
  # soft-deleted rows. Since Registration#discard! only sets deleted_at (and
  # status: "cancelled") rather than removing the row, that meant **a
  # participant who was removed from an event could never register for it
  # again** — the insert failed on an index entry for a registration that no
  # longer exists as far as the rest of the app is concerned.
  #
  # That is a live bug today via RegistrationsController#destroy (an organizer
  # removing a participant). It becomes a much bigger one the moment
  # Registrations::ReleaseAbandoned starts discarding rows automatically:
  # someone who fumbles a KHQR payment would be locked out of the event
  # permanently, with nothing in the UI to explain why.
  #
  # A partial index is the fix — "at most one *live* registration per person
  # per event" is what the rule always meant. Widening a unique index can only
  # ever permit more rows, never conflict with existing data, so this needs no
  # backfill or dedupe pass.
  #
  # Built CONCURRENTLY: a plain CREATE INDEX takes an ACCESS EXCLUSIVE lock for
  # the duration of the build, and this migration runs on container boot
  # (bin/docker-entrypoint's db:prepare), so on a large registrations table it
  # would block every registration write mid-deploy.
  disable_ddl_transaction!

  KEPT_INDEX = "index_registrations_on_event_id_and_user_id_kept".freeze
  LEGACY_INDEX = "index_registrations_on_event_id_and_user_id".freeze

  def up
    # Order matters: the new index is created BEFORE the old one is dropped, so
    # there is never a moment without a uniqueness guarantee. Dropping first —
    # the obvious reading of "replace the index" — would open a window in which
    # duplicate live registrations could be inserted, and the concurrent build
    # would then fail on the duplicates it just allowed.
    add_index :registrations, [ :event_id, :user_id ],
      unique: true,
      where: "deleted_at IS NULL",
      name: KEPT_INDEX,
      algorithm: :concurrently,
      if_not_exists: true

    remove_index :registrations,
      name: LEGACY_INDEX,
      algorithm: :concurrently,
      if_exists: true
  end

  def down
    add_index :registrations, [ :event_id, :user_id ],
      unique: true,
      name: LEGACY_INDEX,
      algorithm: :concurrently,
      if_not_exists: true

    remove_index :registrations, name: KEPT_INDEX, algorithm: :concurrently, if_exists: true
  end

  # Note on rollback: re-adding the total index fails if any (event_id,
  # user_id) pair now has both a discarded row and a live one — exactly what
  # this migration exists to allow. Deliberately not "handled" by deleting
  # rows: losing a participant's history to a rollback would be far worse than
  # a rollback that stops and tells you to look.
  #
  # Because disable_ddl_transaction! is set, these steps are not atomic. A
  # failure between them leaves both indexes present (harmless — the stricter
  # one simply still applies) or an INVALID index behind, which Postgres will
  # report and which is safe to drop and rebuild. if_not_exists/if_exists make
  # the migration re-runnable after such a failure rather than dying on
  # "already exists".
end
