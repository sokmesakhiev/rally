# frozen_string_literal: true

# One place to answer "may this staff member do X?".
#
# Deliberately the same shape as EventAuthorization, which answers the same
# question for events: capabilities as a frozen hash keyed by role, a
# predicate form for branching, and a rendering gate for rejecting. A third
# instance of a familiar pattern is cheaper to hold in your head than a new
# mechanism, and the event matrix has already proved the shape survives
# contact with real permission questions.
#
# See docs/staff-roles-design.md — D1 for why this is a hash rather than a
# permissions system, D3 for the default-deny lookup, D4 for the matrix.
#
# ── Phase 1 grants admin exactly what the boolean granted ───────────────────
# Every capability below includes :admin. That is the point of the phase: the
# mechanism changes, the answer doesn't, and the existing admin request specs
# are what prove it. :support and :moderator appear here from the start
# because writing the matrix twice — once empty, once real — would mean
# reviewing it twice and getting a different answer the second time.
module StaffAuthorization
  extend ActiveSupport::Concern

  # Roles are User::STAFF_ROLES as symbols. `nil` (not staff) is never in an
  # allow-list, so a non-staff account is refused by every capability without
  # any of them having to say so.
  CAPABILITIES = {
    # ── Support chat — all three roles. This is the job support was hired
    # for, and moderators and admins answer threads too.
    read_support_chat:      %i[support moderator admin],
    handle_support_chat:    %i[support moderator admin],

    # ── The report queue. Not support: resolving a report is a moderation
    # decision about whether an event stays up, not a customer conversation.
    read_event_reports:     %i[moderator admin],
    resolve_event_reports:  %i[moderator admin],

    # ── Reading people and events. Support needs both to make sense of a
    # ticket; neither exposes anything the participant couldn't be told.
    read_users:             %i[support moderator admin],
    read_events:            %i[support moderator admin],
    # Organizations are a moderation surface rather than ticket context, so
    # support is left off. Revisit if support tickets turn out to be about
    # organizations often enough that the omission costs an escalation.
    read_organizations:     %i[moderator admin],

    # ── Reversible moderation. Suspension is the protective action and the
    # intended outcome of a report, so it sits with the role that works the
    # queue.
    suspend_user:           %i[moderator admin],
    suspend_event:          %i[moderator admin],
    # Verification is queue work in practice, even though it is what unlocks
    # charging money — and unlike the capabilities below it is reversible and
    # audited.
    verify_user:            %i[moderator admin],
    verify_organization:    %i[moderator admin],

    # ── Irreversible, or money. Admin only. `delete_event`,
    # `suspend_organization` and a large `issue_refund` additionally require a
    # second person from Phase 4 — see D9.
    unpublish_event:        %i[admin],
    delete_event:           %i[admin],
    suspend_organization:   %i[admin],
    issue_refund:           %i[admin],
    waive_plan_payment:     %i[admin],

    # ── Impersonation. Support included, deliberately — D6 has the argument.
    # Opening a session is one capability; oversight of everyone else's
    # sessions is another, and that one is admin's.
    impersonate:            %i[support moderator admin],
    audit_impersonations:   %i[admin],

    read_analytics:         %i[moderator admin],
    read_audit_log:         %i[admin],
    # PingChannel, the Ticket 0 diagnostic. Its `echo` action INSERTs into
    # solid_cable_messages and nothing in the request path can rate-limit a
    # loop over a WebSocket — see .claude/rules/realtime.md.
    use_diagnostics:        %i[admin]
  }.freeze

  # The rule itself, as a module function, because ActionCable channels need
  # the same answer and have no controller to mix a concern into. One
  # implementation, three callers: controllers via #staff_permits? below,
  # SupportInboxChannel, and PingChannel.
  #
  # `fetch`, so a typo'd or undeclared capability raises here rather than
  # returning a quiet false that reads as "denied" and ships as a permissions
  # bug nobody can reproduce.
  def self.permits?(capability, user)
    allowed = CAPABILITIES.fetch(capability)
    role = user&.staff_role&.to_sym
    return false if role.nil?

    allowed.include?(role)
  end

  # Predicate form — no rendering, no raising. Use when you need to branch
  # rather than reject, e.g. deciding what to put in a payload.
  def staff_permits?(capability, user = current_user)
    StaffAuthorization.permits?(capability, user)
  end

  # The gate. Renders and returns false when denied, so callers read:
  #
  #     return unless require_staff!(:suspend_event)
  #
  def require_staff!(capability)
    # Checked *before* the capability, exactly as require_admin! checked it
    # before `admin?`, and for the same reason: impersonating a staff member
    # would launder one person's actions through another's identity and the
    # audit trail would name the wrong one. Under an impersonation token the
    # console 404s for everybody, which makes impersonating staff pointless
    # rather than merely forbidden.
    #
    # Starting a session against a staff account is additionally refused at
    # the endpoint (Admin::ImpersonationsController#refusal_for), so the
    # intent lands in the audit log rather than being inferred from a 404.
    # Two mechanisms on purpose: this is the privilege escalation.
    return head :not_found if impersonating?
    return true if staff_permits?(capability)

    # 404, not 403: a staff surface shouldn't confirm its own existence to
    # someone who goes looking for it. Same reasoning as the old
    # require_admin!, and as EventAuthorization's 404-for-strangers.
    render json: { error: "Not found" }, status: :not_found
    false
  end
end
