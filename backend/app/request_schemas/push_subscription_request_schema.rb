# frozen_string_literal: true

# Validates POST /api/v1/push/subscriptions.
#
# The three fields come straight from the browser's PushSubscription object
# (endpoint, plus keys.p256dh and keys.auth), flattened by the frontend before
# sending. Flattened client-side rather than accepting the browser's nested
# `keys` shape so the wire format is ours and doesn't have to track whatever
# the Push API adds to that object later.
class PushSubscriptionRequestSchema < ApplicationRequestSchema
  params do
    required(:subscription).hash do
      required(:endpoint).filled(:string)
      required(:p256dh_key).filled(:string)
      required(:auth_key).filled(:string)
    end
  end

  # Endpoints are URLs at a push service the browser chose (FCM, Mozilla,
  # Windows Notification Service). We can't allowlist hosts without breaking
  # on the next browser, but we can insist on https — this value is later
  # used to make an outbound request from our own server, so accepting an
  # arbitrary scheme would hand a caller a request-forgery primitive.
  rule(subscription: :endpoint) do
    endpoint = values[:subscription][:endpoint]
    next if endpoint.blank?

    uri = begin
      URI.parse(endpoint)
    rescue URI::InvalidURIError
      nil
    end

    unless uri.is_a?(URI::HTTPS) && uri.host.present?
      key([ :subscription, :endpoint ]).failure("must be an https URL")
    end
  end
end
