# frozen_string_literal: true

# Live support activity for the staff console.
#
# Receive-only, for the same reason as ChatChannel: staff reply through
# `POST /api/v1/admin/conversations/:id/messages`, and this only delivers.
#
# ## One stream for all staff
#
# Every admin console subscribes to the same `support:inbox` stream and
# receives every support message, filtering client-side for whichever thread is
# open. Per-conversation streams would be tidier, but they'd mean a
# subscribe/unsubscribe round trip every time an agent clicks a different
# thread, for a volume of traffic that is currently a handful of messages a
# day among a handful of staff.
#
# No privacy cost: an admin can already read every conversation through
# Api::V1::Admin::ConversationsController, so this exposes nothing new. If
# staff headcount or message volume grows enough that the fan-out matters,
# splitting into `conversation:<id>` streams is the escape hatch — and
# Conversations::Broadcast is the only place that would change.
#
# ## Authorization
#
# `connect` runs once per socket and there is no `before_action` equivalent, so
# the admin check has to happen here, per subscription. `reject` closes the
# subscription without ever registering the stream.
class SupportInboxChannel < ApplicationCable::Channel
  STREAM = "support:inbox"

  # How long a revoked admin can keep receiving.
  #
  # `subscribed` runs exactly once, and a socket lives for hours — so without
  # this, revoking someone's admin flag would leave them streaming *every
  # support conversation on the platform* until they closed the tab or a deploy
  # severed the connection. Offboarding is precisely when that matters.
  #
  # Re-checked on a timer rather than per delivery because this channel is
  # receive-only by design and so has no per-message hook. One query per
  # subscribed admin per interval, against a handful of staff, to bound
  # exposure to five minutes.
  #
  # ChatChannel deliberately has no equivalent: its stream carries only that
  # user's own messages, so a stale permission there exposes nothing the person
  # wasn't already entitled to. Here it exposes everyone else's.
  ACCESS_RECHECK = 5.minutes

  periodically every: ACCESS_RECHECK do
    stop_all_streams unless still_staff?
  end

  private

  # `stop_all_streams` unsubscribes from pubsub, so delivery stops even though
  # the socket itself stays open — the client simply stops receiving. A
  # deleted account can't be reloaded at all, which counts as "no longer
  # staff" rather than an error worth raising on a timer thread.
  def still_staff?
    current_user.reload.admin?
  rescue ActiveRecord::RecordNotFound
    false
  end

  # `private` is load-bearing — see the note in ChatChannel. A public
  # `subscribed` is remotely callable, and repeated calls stack duplicate
  # `stream_from` handlers.
  def subscribed
    return reject unless current_user.admin?

    stream_from STREAM
  end
end
