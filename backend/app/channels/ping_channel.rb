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
# It is safe to leave in place briefly because it exposes nothing: it streams
# only from a stream keyed by the connected user's own id, and echoes back the
# payload the same user just sent.
class PingChannel < ApplicationCable::Channel
  def subscribed
    stream_from "ping:#{current_user.id}"
  end

  # Round-trips through the pub/sub adapter rather than replying directly, so a
  # successful echo proves Solid Cable is actually working — a direct
  # `transmit` would look identical while the adapter was misconfigured, which
  # is precisely the failure this is meant to catch.
  def echo(data)
    ActionCable.server.broadcast(
      "ping:#{current_user.id}",
      { sent_at: data["sent_at"], echoed_at: Time.current.to_f, from: Socket.gethostname }
    )
  end
end
