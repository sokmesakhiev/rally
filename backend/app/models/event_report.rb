# frozen_string_literal: true

# Someone telling Rally staff to look at an event.
#
# ── Why this, and not a classifier ──────────────────────────────────────────
# The four purposes Rally refuses to host — political gathering, gambling,
# violence, discrimination — are also the four with the worst legitimate
# overlap on a sports platform: boxing and MMA, charity casino nights and
# raffles, women-only races and masters/para categories, charity runs with a
# cause. A model scoring event text would block paying organizers constantly,
# and would still miss anyone who words a prohibited event innocuously. A
# person reading the page has the local context to tell those apart.
#
# This is notice-and-takedown, and it is deliberately **reactive**: the harm
# window is time-to-report plus time-to-act. Two consequences are worth
# stating rather than discovering:
#
#   * **An unlisted event has no reporters.** `visibility: "unlisted"` hides an
#     event from the catalogue and search, so there is no audience to notice
#     it — and "invite-only, not listed, carefully worded" is exactly the
#     profile of the events this exists to catch. That segment is covered
#     separately, by requiring a verified organization above a size threshold
#     (Event::UNLISTED_VERIFICATION_THRESHOLD, enforced by
#     Event#unlisted_scale_requires_verified_organization and pre-charge in
#     EventPlanPaymentsController), not by anything here.
#   * **Low traffic means few reports.** On an early platform a public event
#     with a handful of views is unlikely to be reported at all. This control
#     scales with audience, not with event count.
class EventReport < ApplicationRecord
  belongs_to :event
  # Optional both times, and for different reasons: `reporter` because
  # anonymous reports are allowed, `reviewed_by` because it's unset until
  # someone picks the report up.
  belongs_to :reporter, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  # Mirrors the four purposes in Rally's terms, plus an escape hatch. `other`
  # exists because a fixed list always misses something, and a reporter who
  # can't find their category either picks the nearest wrong one — poisoning
  # the only signal this table carries — or gives up.
  REASONS = %w[political gambling violence discrimination other].freeze

  OPEN = "open"
  REVIEWING = "reviewing"
  ACTIONED = "actioned"
  DISMISSED = "dismissed"
  STATUSES = [ OPEN, REVIEWING, ACTIONED, DISMISSED ].freeze
  LIVE_STATUSES = [ OPEN, REVIEWING ].freeze

  validates :reason, inclusion: { in: REASONS }
  validates :status, inclusion: { in: STATUSES }
  validates :details, length: { maximum: 2_000 }

  # Matches the partial unique index. Same pairing as the registrations and
  # conversations indexes: a model that rejects what the database allows, or
  # allows what it rejects, is the more confusing half of the bug.
  validates :event_id,
            uniqueness: {
              scope: :reporter_id,
              conditions: -> { where(status: LIVE_STATUSES) },
              message: "has already been reported by you"
            },
            if: -> { reporter_id.present? && live? }

  scope :live, -> { where(status: LIVE_STATUSES) }
  scope :newest_first, -> { order(created_at: :desc) }

  def live? = LIVE_STATUSES.include?(status)

  # Report count raises an event's position in the queue and nothing else.
  #
  # **No number of reports ever hides an event.** Auto-hiding on a threshold
  # hands anyone with a few accounts a button that takes down a competitor's
  # paying event, and it is the single most abused mechanism on every platform
  # that has shipped it. Only a human calling Event#suspend! hides anything,
  # and that writes an attributed row to admin_actions.
  URGENT_THRESHOLD = 10
  HIGH_THRESHOLD = 3

  def self.priority_for(count)
    return "urgent" if count >= URGENT_THRESHOLD
    return "high" if count >= HIGH_THRESHOLD

    "normal"
  end

  def resolve!(by:, status:, note: nil)
    update!(status: status, reviewed_by: by, reviewed_at: Time.current, reviewer_note: note.presence)
  end
end
