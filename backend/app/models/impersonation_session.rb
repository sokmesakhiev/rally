# frozen_string_literal: true

# One staff member looking at one account, read-only, for at most 30 minutes.
# See docs/impersonation-design.md for the whole design; the parts that live
# here are lifetime, revocation and the token payload.
#
# ── Why a row at all ────────────────────────────────────────────────────────
# The token could have carried everything it needs. It doesn't, because a
# stateless credential cannot be withdrawn, and thirty minutes is long enough
# to matter when the reason for withdrawing it is "that laptop was stolen".
# Every impersonated request re-reads this row by `sid` — one indexed lookup,
# and only for impersonated requests. That's the same trade
# `ApplicationController` already makes for `user.suspended?`: a token that
# keeps working after the fact it depended on has changed is the bug.
class ImpersonationSession < ApplicationRecord
  belongs_to :admin, class_name: "User"
  belongs_to :user
  belongs_to :revoked_by, class_name: "User", optional: true

  # Long enough to reproduce a publish failure, short enough that nobody works
  # a whole ticket from inside someone's account. Never extended: a longer look
  # is a new session, with its own audit row and its own notification.
  DURATION = 30.minutes

  # Free text, not a dropdown — a dropdown is a list of excuses to click
  # through. The minimum is what stops "asdf"; the maximum is what stops the
  # notification email becoming a wall.
  REASON_MIN = 10
  REASON_MAX = 500

  validates :reason, presence: true, length: { minimum: REASON_MIN, maximum: REASON_MAX }
  validates :expires_at, presence: true

  # Matches the partial unique index. `live` here is the *stored* half of the
  # predicate only — expiry is deliberately left out, because a uniqueness
  # validation that ignored expiry would let an admin open a second session
  # the index would then reject, and one that included it would make the two
  # disagree. Expired-but-unended rows are still "the admin's row" until
  # something stamps ended_at, which is what the index says too.
  validates :admin_id,
            uniqueness: {
              conditions: -> { where(ended_at: nil, revoked_at: nil) },
              message: "already has a live impersonation session"
            },
            on: :create

  scope :newest_first, -> { order(created_at: :desc) }
  # The SQL counterpart of #live?, for the admin console's "currently open"
  # view. A spec pins the two against each other: two definitions of one
  # predicate in two languages drift, and nobody notices which one is wrong.
  scope :live, lambda {
    where(ended_at: nil, revoked_at: nil).where(arel_table[:expires_at].gt(Time.current))
  }

  # Evaluated, never stored. See the migration.
  def live?
    ended_at.nil? && revoked_at.nil? && expires_at > Time.current
  end

  def expired? = ended_at.nil? && revoked_at.nil? && expires_at <= Time.current

  def end!
    update!(ended_at: Time.current)
  end

  def revoke!(by:)
    update!(revoked_at: Time.current, revoked_by: by)
  end

  # How the session is told apart from an ordinary sign-in.
  #
  # **`user_id` is the *target*, deliberately.** That one choice is what keeps
  # this feature small: `authenticate_user!` sets `current_user` to the target,
  # so every existing controller, every `authorize_creator!` and every
  # `publicly_visible` scope answers "what may this person see" with no changes
  # at all — which is exactly the question impersonation is asking. Threading a
  # separate `impersonated_user` through the app instead would mean editing
  # every authorization site in the codebase, and the first one missed would be
  # a hole.
  #
  # `act` ("actor") is who is really driving, and is what the audit log, the
  # per-request log line and Sentry record.
  def token
    JsonWebToken.encode(
      { user_id: user_id, act: admin_id, imp: true, sid: id },
      expires_at
    )
  end

  def self.start!(admin:, user:, reason:, ip: nil, user_agent: nil)
    create!(
      admin: admin,
      user: user,
      reason: reason,
      expires_at: DURATION.from_now,
      ip: ip,
      user_agent: user_agent
    )
  end
end
