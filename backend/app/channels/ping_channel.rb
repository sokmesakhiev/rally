# frozen_string_literal: true

# TEMPORARY — delete with Ticket D of support-chat-tickets.md, once ChatChannel
# exists and can prove the same things.
#
# This exists to answer Ticket 0's go/no-go question against real
# infrastructure, which unit tests cannot: does a connection survive the ALB,
# does the origin allowlist match what CloudFront actually sends, does a
# broadcast from one ECS task reach a subscriber on the other, and what does
# holding N connections cost. Drive it with scripts/cable-smoke.mjs.
#
# ## Why this is off by default
#
# **rack-attack cannot see channel actions.** Rack::Attack is Rack middleware,
# and ActionCable hijacks the socket at connect time — every message after that
# never traverses the Rack stack again. So none of the throttles in
# config/initializers/rack_attack.rb apply here, and there is no middleware
# layer where they could be added.
#
# That matters because #echo broadcasts through Solid Cable, and every
# broadcast INSERTs a row into solid_cable_messages (retained a day). Left
# reachable, any authenticated user could loop it and write to the cable
# database as fast as their connection allows, with nothing in the request path
# able to stop them.
#
# So it is unreachable by ordinary accounts. Two ways in:
#
#   * **current_user.admin?** — the normal path, and how the smoke run
#     authenticates. Admin is granted only from a console, and it's the same
#     audience already trusted to suspend users and delete events; a
#     diagnostic echo is not the sharpest tool they hold.
#   * **ENABLE_PING_CHANNEL=true** — opens it to every authenticated user.
#     Only needed for a load run large enough to need several non-admin
#     accounts, because the cable-ticket throttle is keyed per user.
#
# The admin path exists because the env var turned out to be awkward *and*
# weaker. Awkward: aws_ecs_task_definition.app carries
# `ignore_changes = [container_definitions]`, so Terraform won't push env
# changes at all, and scripts/deploy.sh only forces a new deployment of the
# existing revision — setting it means hand-registering a task definition
# revision and undoing it afterwards. Weaker: while it's on, every
# authenticated user can reach this channel. The admin gate never widens the
# surface at all.
#
# The same constraint applies to the real ChatChannel: message rate limiting
# has to live *in the channel*, not in rack-attack. See Ticket H.
class PingChannel < ApplicationCable::Channel
  def self.enabled_for?(user)
    user&.admin? || ENV["ENABLE_PING_CHANNEL"] == "true"
  end

  def subscribed
    return reject unless self.class.enabled_for?(current_user)

    stream_from "ping:#{current_user.id}"
  end

  # Round-trips through the pub/sub adapter rather than replying directly, so a
  # successful echo proves Solid Cable is actually working — a direct
  # `transmit` would look identical while the adapter was misconfigured, which
  # is precisely the failure this is meant to catch.
  #
  # Re-checks rather than trusting `subscribed` to have rejected: actions are
  # dispatched per message, and a subscription opened while the flag was on —
  # or before an admin flag was revoked — would otherwise keep working.
  def echo(data)
    return unless self.class.enabled_for?(current_user)

    ActionCable.server.broadcast(
      "ping:#{current_user.id}",
      { sent_at: data["sent_at"], echoed_at: Time.current.to_f, from: Socket.gethostname }
    )
  end
end
