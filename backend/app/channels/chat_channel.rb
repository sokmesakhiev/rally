# frozen_string_literal: true

# Live support messages for one participant.
#
# ## Receive-only, on purpose
#
# This channel has no public action methods, so a client can never send
# anything over the socket — messages are posted through
# `POST /api/v1/support/messages` and only *delivered* here.
#
# That is not an oversight, it removes a whole problem. rack-attack is Rack
# middleware and ActionCable hijacks the socket at connect, so nothing sent
# over an established WebSocket can be throttled by the request stack. A
# channel that accepted messages would need its own rate limiter (the plan in
# Ticket H). One that only broadcasts needs none: every write still goes
# through the throttled REST endpoint, and REST stays the single write path.
#
# ## No parameters, so nothing to authorize
#
# The stream name is derived from `current_user`, which the connection
# established from a single-use ticket. There is no `conversation_id` param for
# a caller to tamper with, so "can this person read this stream" cannot be
# gotten wrong — you are only ever able to stream your own.
#
# This is a deliberate simplification of Ticket D's wording ("a participant may
# stream from their own conversation"). Keying on the *user* rather than the
# conversation also means the subscription survives a thread being resolved and
# a new one starting, which happens whenever staff close a conversation.
class ChatChannel < ApplicationCable::Channel
  def self.stream_name_for(user_id)
    "support:user:#{user_id}"
  end

  private

  # `private` is load-bearing, not style.
  #
  # ActionCable::Channel::Base declares `subscribed` private, and
  # `.action_methods` is computed as "public methods of this class, minus the
  # public methods of Base, plus this class's own public methods". Defining
  # `subscribed` as public — which every Rails example does — therefore puts it
  # straight back into the callable set, and a client can send
  # `{"action":"subscribed"}` at will. Each call runs `stream_from` again,
  # appending another handler, so a loop earns N copies of every message from
  # then on. Nothing in the request path can throttle that.
  #
  # Matching Base's visibility removes it from `action_methods` entirely, which
  # is what the spec asserts. `subscribe_to_channel` calls it with an implicit
  # receiver, so private works.
  def subscribed
    stream_from self.class.stream_name_for(current_user.id)
  end
end
