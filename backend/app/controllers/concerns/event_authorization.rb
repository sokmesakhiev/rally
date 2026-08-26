# frozen_string_literal: true

# One place to answer "may this user do X to this event?".
#
# Before this concern, that decision was written out 20 times across 8
# controllers in two different idioms with two different failure modes:
#
#   * `current_user.events.find(id)` rescued into 404 "Event not found"
#   * `unless event.creator_id == current_user.id` → 403 "Forbidden"
#
# The split was never principled — it's just how each controller happened to
# get written. That was tolerable while "authorized" meant one thing
# (are you the creator?), but event membership adds a second dimension
# (which role do you hold?), and 20 hand-rolled checks means 20 chances to
# get the combination subtly wrong with no single place to read off the
# answer.
#
# ── Deliberately NO behaviour change ────────────────────────────────────────
# CAPABILITIES below grants every capability to :owner and nobody else, so
# with role gating not yet switched on, every endpoint answers exactly as it
# did before. #event_role_for already resolves EventMembership rows, so
# turning membership on later (issue #278) is a change to the CAPABILITIES
# data and nothing else.
#
# The existing 404-vs-403 inconsistency is also preserved on purpose, endpoint
# by endpoint, via the two entry points below. Unifying it would be a real
# behaviour change — the thing this refactor promises not to do — so it's
# deferred to #278, where the affected request specs are being touched anyway.
# The rule to apply then: 404 when the caller has no relationship with the
# event at all (don't confirm its existence to a stranger — matches
# ApplicationController#require_admin!'s philosophy), 403 when they're on the
# team but their role doesn't cover this action.
module EventAuthorization
  extend ActiveSupport::Concern

  # The permission matrix, as data. Each capability lists the roles that may
  # perform it; :owner is the event's creator (Event#creator_id), the others
  # are EventMembership::ROLES.
  #
  # Everything is :owner-only today. See event-membership-tickets.md for the
  # matrix #278 will replace this with, and why plan payments, delete/unpublish
  # and member management stay owner-only even then (they either spend the
  # owner's money or change who controls the event).
  CAPABILITIES = {
    view_event: [ :owner ],
    view_participants: [ :owner ],
    export_participants: [ :owner ],
    check_in: [ :owner ],
    update_registration: [ :owner ],
    remove_participant: [ :owner ],
    issue_refund: [ :owner ],
    view_waitlist: [ :owner ],
    manage_results: [ :owner ],
    view_survey_responses: [ :owner ],
    view_activity: [ :owner ],
    update_event: [ :owner ],
    manage_plan: [ :owner ],
    unpublish_event: [ :owner ],
    delete_event: [ :owner ],
    manage_members: [ :owner ]
  }.freeze

  # The caller's role on `event`: :owner, one of EventMembership::ROLES as a
  # symbol, or nil for no relationship at all.
  #
  # Creator is checked first and short-circuits, so the common case costs no
  # extra query — the membership lookup only runs for people who aren't the
  # owner, which today is exactly the set about to be denied anyway.
  def event_role_for(event)
    return nil if event.nil? || current_user.nil?
    return :owner if event.creator_id == current_user.id

    membership = EventMembership.find_by(event_id: event.id, user_id: current_user.id)
    membership&.role&.to_sym
  end

  # Predicate form — no rendering, no raising. Use when you need to branch
  # rather than reject (e.g. deciding what to include in a payload).
  def event_permits?(event, capability)
    allowed = CAPABILITIES.fetch(capability)
    role = event_role_for(event)
    return false if role.nil?

    allowed.include?(role)
  end

  # 403-style gate, for endpoints that already have the event in hand
  # (typically reached via a Registration or Payment id, so the resource's own
  # existence has already been established and a 404 here would just confuse).
  #
  # Renders "Forbidden" and returns false when denied, so callers read:
  #
  #     return unless authorize_event!(event, :remove_participant)
  #
  def authorize_event!(event, capability)
    return true if event_permits?(event, capability)

    render json: { error: "Forbidden" }, status: :forbidden
    false
  end

  # 404-style gate, for endpoints addressed by event_id. Mirrors what
  # `current_user.events.find(params[:event_id])` did: raises
  # ActiveRecord::RecordNotFound both when the event doesn't exist and when
  # the caller may not touch it, so the existing `rescue` blocks in each
  # controller keep rendering their own "Event not found" unchanged.
  #
  # `scope` lets callers keep their own eager-loading and #kept filtering
  # (they differ per endpoint — see EventsController#activity vs
  # EventPlanPaymentsController#create).
  def find_authorized_event!(event_id, capability, scope: Event.all)
    event = scope.find(event_id)
    raise ActiveRecord::RecordNotFound unless event_permits?(event, capability)

    event
  end
end
