class CreateConversationsAndMessages < ActiveRecord::Migration[8.1]
  # Support chat: a participant talks to Rally staff. See
  # support-chat-tickets.md, Ticket A.
  #
  # Organizer <-> participant chat is explicitly out of scope, and nothing here
  # is built "generically" in anticipation of it — a conversation belongs to
  # one user, and staff are whoever holds `users.admin`.
  def change
    create_table :conversations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # The participant. Staff are deliberately NOT modelled as members of the
      # conversation: any admin can answer any thread, so there is no
      # membership to record, only an optional soft claim (below).
      t.references :user, null: false, foreign_key: true, type: :uuid, index: false

      # open      — needs an answer
      # pending   — answered, waiting on the participant
      # resolved  — closed; frees the participant to open a new thread
      #
      # A string rather than a Postgres enum, matching notifications.kind: the
      # allowed set lives in Conversation::STATUSES so adding one needs no
      # migration. The CHECK below still stops a typo from an `update_column`
      # or a console session writing a status nothing can read.
      t.string :status, null: false, default: "open"

      # Optional one-line summary. Nullable: the first message is usually
      # enough context, and forcing a subject line on someone who wants help
      # is friction at exactly the wrong moment.
      t.string :subject

      # A soft claim — "someone is looking at this" — not exclusive ownership.
      # Nullable, and nullified rather than cascaded if that admin's account
      # goes away, because the conversation itself must survive.
      t.references :assigned_admin, type: :uuid, null: true, index: false,
                                    foreign_key: { to_table: :users, on_delete: :nullify }

      # Denormalised from messages purely so the staff inbox can sort without
      # a correlated subquery or a join per row. Maintained by Message's
      # `touch:` — see that model.
      t.datetime :last_message_at

      # Read state as two timestamps rather than a join table. There is exactly
      # one participant, and staff act as a *pool* rather than as individuals
      # subscribed to a thread, so "has the participant seen this" and "has
      # anyone on the team seen this" are the only two questions anyone asks.
      # A per-user read-receipts table would answer questions nobody has, and
      # would fan out a row per admin per conversation.
      #
      # Revisit only if staff ever need per-agent receipts, which is a
      # different product.
      t.datetime :participant_last_read_at
      t.datetime :staff_last_read_at

      t.timestamps
    end

    # The staff inbox: open threads, most recently active first.
    add_index :conversations, [ :status, :last_message_at ],
      order: { last_message_at: :desc },
      name: "index_conversations_on_status_and_last_message_at"

    # "My queue" for an admin who has claimed threads.
    add_index :conversations, :assigned_admin_id, where: "assigned_admin_id IS NOT NULL"

    # One live thread per participant. Partial so a resolved thread doesn't
    # block them from ever asking anything again — the same shape, and the same
    # reasoning, as the registrations kept-index (see
    # 20260909010000_scope_registration_uniqueness_to_kept.rb). Conversation
    # carries a matching `conditions:` on its uniqueness validation, because a
    # model that rejects what the database allows (or vice versa) is the more
    # confusing half of that class of bug.
    #
    # Not built CONCURRENTLY, unlike that migration: this table is being
    # created in the same change, so there is nothing to lock and no existing
    # rows to conflict.
    add_index :conversations, :user_id,
      unique: true,
      where: "status <> 'resolved'",
      name: "index_conversations_one_live_per_user"

    # Every participant-facing lookup is "my thread(s)", newest first.
    add_index :conversations, [ :user_id, :created_at ]

    add_check_constraint :conversations,
      "status IN ('open', 'pending', 'resolved')",
      name: "conversations_status_valid"

    create_table :messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :conversation, null: false, foreign_key: true, type: :uuid, index: false

      # Nullable, and nullified at the database level when that account is
      # destroyed. The case this exists for is a *staff* account being deleted:
      # their replies live inside some participant's conversation, so they must
      # outlive the person who wrote them or the thread becomes unreadable for
      # someone who did nothing wrong.
      #
      # A NULL sender therefore means "account gone", and renders as such.
      # There is deliberately no CHECK requiring a sender on non-system
      # messages: that constraint and ON DELETE SET NULL are mutually
      # exclusive, and it would turn deleting a staff account into a foreign
      # key error at exactly the moment someone is trying to leave.
      t.references :sender, type: :uuid, null: true, index: false,
                            foreign_key: { to_table: :users, on_delete: :nullify }

      # Which side sent it, snapshotted at write time rather than derived from
      # `users.admin` at read time.
      #
      # Revoking someone's admin flag must not silently rewrite months of
      # history so their past replies render as if a participant sent them —
      # and a nulled sender_id would erase the distinction entirely. When a
      # fact is part of the record of what happened, it belongs on the record.
      # Same reasoning as Registration#snapshot_refund_policy.
      #
      # "system" is reserved for messages the app writes itself (e.g. "this
      # conversation was resolved"); nothing generates them yet.
      t.string :sender_role, null: false

      t.text :body, null: false

      t.timestamps
    end

    # The thread itself: one conversation's messages in order. Covers both the
    # initial history fetch and the `?after=<id>` reconnect catch-up.
    add_index :messages, [ :conversation_id, :created_at ]

    add_check_constraint :messages,
      "sender_role IN ('participant', 'staff', 'system')",
      name: "messages_sender_role_valid"

    # A body cap belongs in the schema as well as the model: the model
    # validation is the one that produces a decent error message, and this is
    # the one that still holds when something writes around it.
    add_check_constraint :messages,
      "char_length(body) <= 5000",
      name: "messages_body_length"

    # Empty and whitespace-only bodies, rejected in the schema as well as the
    # model. `body` is NOT NULL already, but "" and "   " both satisfy that
    # while being just as meaningless in a thread.
    add_check_constraint :messages,
      "btrim(body) <> ''",
      name: "messages_body_not_blank"
  end
end
