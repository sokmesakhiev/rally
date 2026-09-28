# frozen_string_literal: true

module Notifications
  # Tells somebody their staff access changed — D10.
  #
  # The reasoning is `ImpersonationNotifier`'s, not `ModerationNotifier`'s:
  # a change to what a person can do, that they were never told about, should
  # not be a state the database can hold. Writing to one named person about
  # their own account is also why this isn't a method on ModerationNotifier,
  # which fans out to a pool about somebody else's event.
  #
  # **Revocation notifies too**, and the counter-argument deserves stating:
  # it tells an insider being quietly removed that they have been spotted.
  # It goes in anyway. They find out the moment the console 404s — staff
  # access is checked live on every request — so the silence buys minutes at
  # most, while costing the honest case (a role changed by mistake, or an
  # offboarding somebody should be able to query) any record they can see.
  #
  # No push and no `notify_*` preference. Those are a participant's controls
  # over announcements they may reasonably mute; this is not an announcement.
  # Same call as ImpersonationNotifier.
  module StaffRoleNotifier
    module_function

    GRANTED_KIND = "staff_role_granted"
    REVOKED_KIND = "staff_role_revoked"

    def granted(user, role:, by:)
      return if user.nil? || role.blank?

      record(
        user: user,
        kind: GRANTED_KIND,
        title: "You've been given #{role} access",
        body: "#{actor_name(by)} gave you #{role} access to the Rally staff console."
      )
    end

    def revoked(user, previous_role:, by:)
      return if user.nil?

      record(
        user: user,
        kind: REVOKED_KIND,
        title: "Your staff access was removed",
        body: "#{actor_name(by)} removed your #{previous_role} access to the Rally staff console."
      )
    end

    def actor_name(actor)
      actor&.profile&.display_name.presence || "A Rally administrator"
    end

    # **Deliberately not swallowed**, unlike every notifier that writes about a
    # registration or a report. There, losing a bell row beats losing the
    # thing itself. Here the notification *is* half the feature: a role change
    # nobody was told about is precisely what D10 exists to stop, so if the
    # row can't be written the change shouldn't stand either — so the caller
    # wraps the update, the audit row and this in one transaction, and a
    # raise here takes all three back. Rails does not wrap a controller action
    # in a transaction on its own; that has to be, and is, explicit.
    def record(user:, kind:, title:, body:)
      Notification.create!(
        user_id: user.id,
        kind: kind,
        title: title,
        body: body,
        # No deep link. The console is the natural destination for a grant,
        # but a revoked user 404s there — pointing them at a door that no
        # longer opens is a worse experience than no link at all.
        url: nil
      )
    end
  end
end
