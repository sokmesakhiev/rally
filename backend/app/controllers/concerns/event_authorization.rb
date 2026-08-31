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
# ── Role gating is live (issue #278) ────────────────────────────────────────
# #277 introduced this concern with CAPABILITIES granting everything to
# :owner and nobody else, so the refactor itself changed no behaviour.
# #278 (this state) fills in CAPABILITIES per the matrix in
# event-membership-tickets.md — #event_role_for already resolved
# EventMembership rows from day one, so this was purely a data change plus
# `events#my_events` learning to list member events too (see
# Api::V1::EventsController#my_events — without that, an invited member has
# no way to reach the event they just joined).
#
# The 404-vs-403 split predates membership and is preserved as-is here: 404
# when the caller has no relationship with the event at all (don't confirm
# its existence to a stranger — matches ApplicationController#require_admin!'s
# philosophy), 403 when they're on the team but their role doesn't cover this
# action. Every call site already picked the right one of the two entry
# points below for its own reasons; role gating doesn't change which endpoints
# use which.
module EventAuthorization
  extend ActiveSupport::Concern

  # The permission matrix, as data. Each capability lists the roles that may
  # perform it; :owner is the event's creator (Event#creator_id), the others
  # are EventMembership::ROLES. See event-membership-tickets.md for the full
  # reasoning table this mirrors.
  #
  # Three capabilities are deliberately owner-only even for Manager — the
  # role that otherwise covers almost everything else — because they either
  # spend the owner's money or change who controls the event:
  #   * manage_plan   — plan payments charge the owner's own card.
  #   * unpublish_event / delete_event — hide or destroy work that isn't the
  #     manager's to take down.
  #   * manage_members — letting a Manager add/remove Managers would let the
  #     owner get diluted out of their own event with no audit trail they'd
  #     notice.
  #
  # CSV export (export_participants) is Manager-only, not Viewer, even though
  # a Viewer can already page through the same participants in the UI — bulk
  # export is a different risk (one click, the whole attendee list, off
  # platform), and Viewer is the role handed to a sponsor or a board member.
  CAPABILITIES = {
    view_event: [ :owner, :manager, :check_in, :viewer ],
    view_participants: [ :owner, :manager, :check_in, :viewer ],
    export_participants: [ :owner, :manager ],
    check_in: [ :owner, :manager, :check_in ],
    update_registration: [ :owner, :manager ],
    remove_participant: [ :owner, :manager ],
    issue_refund: [ :owner, :manager ],
    view_waitlist: [ :owner, :manager, :viewer ],
    manage_results: [ :owner, :manager ],
    view_survey_responses: [ :owner, :manager, :viewer ],
    view_activity: [ :owner, :manager, :viewer ],
    update_event: [ :owner, :manager ],
    manage_plan: [ :owner ],
    unpublish_event: [ :owner ],
    delete_event: [ :owner ],
    manage_members: [ :owner ]
  }.freeze

  # Capabilities that stay usable on a suspended event (event-freeze-and-terms-tickets.md's
  # Ticket A — the columns/methods behind this are named to match
  # User#suspend!, see Event#suspend!'s comment) — everything else is denied
  # to every role, including :owner, the moment event.suspended? is true. The
  # point of a suspension is that it isn't the owner's call to reverse or
  # work around; letting them keep editing, unpublishing (to "clean up"
  # before anyone notices), or managing the team would defeat that. Read
  # access is preserved so the owner can still see the event and the reason
  # it was suspended.
  SUSPENDED_ALLOWED_CAPABILITIES = %i[
    view_event view_participants view_waitlist view_survey_responses view_activity
  ].freeze

  # The caller's role on `event`: :owner, one of EventMembership::ROLES as a
  # symbol, or nil for no relationship at all.
  #
  # Creator is checked first and short-circuits, so the common case costs no
  # extra query — the membership lookup only runs for people who aren't the
  # owner, which today is exactly the set about to be denied anyway.
  def event_role_for(event)
    return nil if event.nil? || current_user.nil?
    return :owner if event.creator_id == current_user.id
    # Anyone who can act for the presenting organization gets owner-level
    # access to its events — see organization-identity-tickets.md's Ticket C
    # (#332). Without this, a club's second admin couldn't manage an event a
    # colleague created, which is most of the point of organizations.
    #
    # Deliberately owner/admin only: a plain org `member` gets nothing here
    # and still needs an explicit EventMembership, same as anyone else.
    return :owner if event.organization&.administered_by?(current_user)

    membership = EventMembership.find_by(event_id: event.id, user_id: current_user.id)
    membership&.role&.to_sym
  end

  # Predicate form — no rendering, no raising. Use when you need to branch
  # rather than reject (e.g. deciding what to include in a payload).
  def event_permits?(event, capability)
    allowed = CAPABILITIES.fetch(capability)
    role = event_role_for(event)
    return false if role.nil?
    return false unless allowed.include?(role)

    !event.suspended? || SUSPENDED_ALLOWED_CAPABILITIES.include?(capability)
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
  # The default scope preloads organization: :owner because #event_permits?
  # below calls Event#suspended?, which since Ticket J (#339) walks
  # event → organization → owner. Callers passing their own `scope:` should
  # include it too if they're loading more than one event.
  def find_authorized_event!(event_id, capability, scope: Event.includes(organization: :owner))
    event = scope.find(event_id)
    raise ActiveRecord::RecordNotFound unless event_permits?(event, capability)

    event
  end
end
