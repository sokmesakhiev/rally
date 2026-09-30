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
    # Its own capability, and deliberately **not** four-eyes, even though
    # suspending is. Undoing a suspension is the restorative act: making it
    # wait for a second signature means a wrongly-suspended organization —
    # every event it presents, every registration in flight — stays down until
    # somebody else is awake. Same reasoning that keeps event suspension out
    # of the four-eyes list: the control belongs on the destructive direction,
    # never on the recovery.
    #
    # Same audience as suspending, though. Reversing another admin's
    # moderation decision isn't a moderator's call.
    unsuspend_organization: %i[admin],
    issue_refund:           %i[admin],
    waive_plan_payment:     %i[admin],

    # ── Impersonation. Support included, deliberately — D6 has the argument.
    # Opening a session is one capability; oversight of everyone else's
    # sessions is another, and that one is admin's.
    impersonate:            %i[support moderator admin],
    audit_impersonations:   %i[admin],

    # Anyone on staff may see the four-eyes queue; whether they may sign a
    # given row depends on the capability *that row* asks for, which is
    # checked per-request in StaffApprovalsController#approvable!.
    read_staff_approvals:   %i[support moderator admin],
    # ── Staff membership (D10). Two capabilities, not one, and the split is
    # the same lesson `unsuspend_organization` taught: a capability covering
    # both an action and its undo drags the four-eyes requirement onto the
    # undo. Granting somebody the console deserves a second opinion; taking it
    # away at 2am from a compromised account must not wait for one.
    #
    # Neither can touch `admin` — that stays console-only, so a stolen admin
    # session cannot mint another admin. See D10 for why four-eyes is not a
    # substitute for that: it defends against one *person* acting alone, not
    # one *session* being stolen.
    grant_staff_role:       %i[admin],
    revoke_staff_role:      %i[admin],
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

    unless staff_permits?(capability)
      # 404, not 403: a staff surface shouldn't confirm its own existence to
      # someone who goes looking for it. Same reasoning as the old
      # require_admin!, and as EventAuthorization's 404-for-strangers.
      render json: { error: "Not found" }, status: :not_found
      return false
    end

    require_second_signature!(capability)
  end

  # Four-eyes, checked **here** rather than in a filter of its own.
  #
  # That placement is the point (D9's sixth property). A separate
  # `before_action :require_approval!` would have to be remembered and ordered
  # correctly in every controller that needs it, and the one that forgot would
  # be a silent hole in exactly the actions least able to afford one. Running
  # it inside the thing that already decides "may you do this" means an action
  # declared four-eyes cannot be reached by a route that didn't ask.
  #
  # Unlike the capability refusal above, this answers 403 with a machine-
  # readable code: the caller *is* staff and *does* hold the capability, so
  # pretending the endpoint doesn't exist would be a lie, and the client needs
  # to tell "you can't" from "not yet — go and get a signature".
  # `payload_override` is for the callers whose pinned value isn't simply a
  # request parameter. A refund's amount defaults to the payment's remaining
  # refundable balance when the caller omits it, and the threshold has to be
  # judged on the figure that will actually be refunded — not on whether
  # somebody typed it.
  def require_second_signature!(capability, **payload_override)
    payload = four_eyes_payload(capability).merge(payload_override)
    return true unless StaffApproval.required_for?(capability, payload)

    # Nothing to protect, so nothing to approve — let the action answer with
    # its own 404.
    #
    # Without this the gate runs first and refuses with `approval_required`
    # for an id that doesn't exist, which is wrong twice over. It tells a
    # legitimate admin to go and get a signature for a record that isn't
    # there — and `StaffApproval`'s `belongs_to :target` would then refuse to
    # create one, leaving them at a dead end with no explanation.
    #
    # It hides nothing either: anyone holding a four-eyes capability can
    # already enumerate the targets through the console's own index endpoints,
    # so 403-before-404 buys no secrecy and costs a truthful answer.
    return true unless four_eyes_target_exists?(capability)

    approval = usable_staff_approval(capability, payload)
    unless approval
      render json: {
        error: "This action needs approval from another staff member.",
        code: "approval_required",
        capability: capability
      }, status: :forbidden
      return false
    end

    # Held for the action to consume once it has actually succeeded — see
    # Admin::BaseController#consume_staff_approval!. Consuming here would burn
    # the approval on a request that then 422s for an unrelated reason, and the
    # requester would have to go back for a second signature they already had.
    @staff_approval = approval
    true
  end

  # Writes the audit row and spends the approval that authorised it, in that
  # order and in one place so the two can't drift apart.
  #
  # The approval records *intent* — two people agreed this should happen. The
  # AdminAction records that it *did*. Conflating them would lose the
  # difference between "asked" and "did", which is most of what an audit trail
  # is for; linking them means either can be followed to the other.
  #
  # **Consumed after the action succeeds, not before**, and the trade-off is
  # worth stating. Burning the approval on attempt would close a
  # double-submit race completely, but it would also mean a 422 for an
  # unrelated reason — a reason too short, a validation tripped — costs the
  # requester a second signature they already had, and a control that
  # punishes ordinary mistakes is one people route around. The residual
  # window is two identical requests arriving before either consumes; the
  # second `consume!` returns false, but its side effect has already run.
  # Each of the four gated actions carries its own guard against that
  # (`discard!` is idempotent, `Refunds::IssueRefund` checks
  # `remaining_refundable_cents`, a re-waive re-publishes an already-published
  # event), which is what keeps the practical exposure small rather than
  # theoretical.
  def record_staff_action!(action, target, **metadata)
    approval = @staff_approval
    metadata = metadata.merge(staff_approval_id: approval.id) if approval
    AdminAction.log!(admin: current_user, action: action, target: target, metadata: metadata)
    approval&.consume!
  end

  # The parameters an approval is pinned to, per capability.
  #
  # Kept beside the matrix rather than scattered across controllers, so that
  # "what does approving this actually authorise" is answerable from one file.
  # `fetch`-free on purpose: a capability with no entry pins target alone,
  # which is the right default for an action whose only variable is what it
  # points at.
  def four_eyes_payload(capability)
    case capability
    when :issue_refund        then { amount_cents: params[:amount_cents].to_i }
    when :waive_plan_payment  then { plan: params[:plan].to_s }
    else {}
    end
  end

  # Whether the record this capability would act on is actually there.
  #
  # Rescues rather than trusting the parameter: a malformed UUID makes
  # Postgres raise on the comparison, and a gate that 500s on a junk id is a
  # worse answer than the 404 the action was going to give anyway. Every
  # failure mode here resolves to "no target", which skips the gate and lets
  # the action speak for itself.
  def four_eyes_target_exists?(capability)
    target_type, target_id = four_eyes_target(capability)
    return false if target_type.blank? || target_id.blank?

    target_type.constantize.exists?(id: target_id)
  rescue ActiveRecord::StatementInvalid, NameError
    false
  end

  def usable_staff_approval(capability, payload)
    target_type, target_id = four_eyes_target(capability)
    return nil if target_id.blank?

    digest = StaffApproval.digest_for(
      action: capability, target_type: target_type, target_id: target_id, payload: payload
    )

    StaffApproval
      .where(requester_id: current_user&.id, action: capability, status: "approved")
      .find { |candidate| candidate.usable_by?(current_user, digest) }
  end

  # Which record the capability acts on. Reads the route's own id parameter
  # rather than loading the record: the action loads it moments later, and a
  # gate that hits the database twice for the same row invites the two reads
  # to disagree.
  def four_eyes_target(capability)
    case capability
    when :delete_event        then [ "Event", params[:id] ]
    when :suspend_organization then [ "Organization", params[:id] ]
    when :waive_plan_payment  then [ "Event", params[:event_id] ]
    when :issue_refund        then [ "Payment", params[:payment_id] ]
    end
  end
end
