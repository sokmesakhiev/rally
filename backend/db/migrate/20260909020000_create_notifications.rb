class CreateNotifications < ActiveRecord::Migration[8.1]
  # In-app notifications — what the header bell counts and lists.
  #
  # A third channel alongside the mailers and web push, not a replacement for
  # either. Email reaches everyone, push reaches devices that opted in, and
  # this is the one that persists: a badge needs a count that survives a page
  # reload, which a web push (fire-and-forget, gone once dismissed) can't
  # provide.
  def change
    create_table :notifications, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid, index: false

      # Which kind of thing happened — mirrors the mailer/push trigger names
      # (payment_received, promoted_from_waitlist, ...). Kept as a string
      # rather than an enum column so adding a kind needs no migration; the
      # allowed set lives in Notification::KINDS.
      t.string :kind, null: false

      # Rendered server-side at write time rather than stored as a template
      # plus data. The wording of a notification should be whatever was true
      # when it happened — re-rendering later against a changed event would
      # rewrite history ("Your payment for X is confirmed" shouldn't change
      # when the organizer renames the event).
      t.string :title, null: false
      t.string :body
      t.string :url

      # Where it came from, for deep links and for cleanup when an event goes
      # away. Nullable: not every notification is about an event.
      t.references :event, foreign_key: true, type: :uuid, null: true, index: false

      t.datetime :read_at

      t.timestamps
    end

    # The badge's query: this user's unread count. Partial on read_at so the
    # index only carries rows that can contribute to it — unread is a small
    # and roughly constant slice, while read rows accumulate forever.
    add_index :notifications, [ :user_id, :created_at ],
      where: "read_at IS NULL",
      name: "index_notifications_unread_by_user"

    # The dropdown's query: this user's most recent, read or not.
    add_index :notifications, [ :user_id, :created_at ]

    add_index :notifications, :event_id
  end
end
