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
# So it stays disabled unless ENABLE_PING_CHANNEL is explicitly set — never in
# infrastructure/ecs.tf. Turn it on for the duration of a smoke run and off
# again afterwards.
#
# The same constraint applies to the real ChatChannel: message rate limiting
# has to live *in the channel*, not in rack-attack. See Ticket H.
class PingChannel < ApplicationCable::Channel
  def self.enabled?
    ENV["ENABLE_PING_CHANNEL"] == "true"
  end

  def subscribed
    return reject unless self.class.enabled?

    stream_from "ping:#{current_user.id}"
  end

  # Round-trips through the pub/sub adapter rather than replying directly, so a
  # successful echo proves Solid Cable is actually working — a direct
  # `transmit` would look identical while the adapter was misconfigured, which
  # is precisely the failure this is meant to catch.
  #
  # Re-checks `enabled?` rather than trusting `subscribed` to have rejected:
  # actions are dispatched per message, and a subscription established while
  # the flag was on would otherwise keep working after it was turned off.
  def echo(data)
    return unless self.class.enabled?

    ActionCable.server.broadcast(
      "ping:#{current_user.id}",
      { sent_at: data["sent_at"], echoed_at: Time.current.to_f, from: Socket.gethostname }
    )
  end
end
