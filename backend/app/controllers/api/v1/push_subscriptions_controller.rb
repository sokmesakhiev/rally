module Api
  module V1
    # Browser push subscriptions — see PushSubscription and
    # Notifications::DeliverPush.
    class PushSubscriptionsController < BaseController
      # #vapid_public_key is deliberately open: it is a public key, the browser
      # needs it *before* it can subscribe, and gating it behind auth would
      # mean a signed-out visitor couldn't be offered notifications later
      # without a round trip.
      before_action :authenticate_user!, except: [ :vapid_public_key ]

      # GET /api/v1/push/vapid_public_key
      #
      # Served from the API rather than baked into the bundle as a VITE_ var,
      # on purpose. The frontend is a static SPA built once and cached on
      # CloudFront, so a compiled-in key could only change with a rebuild and
      # a cache invalidation — and would silently disagree with the backend in
      # the window between the two. One source of truth, fetched at runtime.
      #
      # `enabled: false` tells the frontend to hide the whole feature rather
      # than prompt for a permission it can't act on.
      def vapid_public_key
        if Notifications::Vapid.configured?
          render json: { enabled: true, public_key: Notifications::Vapid.public_key }
        else
          render json: { enabled: false, public_key: nil }
        end
      end

      # POST /api/v1/push/subscriptions
      #
      # Idempotent by endpoint: browsers hand back the same endpoint when you
      # subscribe again with the same VAPID key, so this must update rather
      # than duplicate. It also un-expires — a device that went quiet and has
      # now re-subscribed is alive again.
      def create
        validate_params_with_schema(PushSubscriptionRequestSchema) do |validated_params|
          attrs = validated_params[:subscription]

          # Scoped to current_user, NOT PushSubscription.find_or_initialize_by.
          # An unscoped finder here would let anyone who learned another user's
          # endpoint reassign that row to themselves — their device would then
          # receive this caller's notifications and stop receiving its own.
          subscription = current_user.push_subscriptions.find_or_initialize_by(
            endpoint: attrs[:endpoint]
          )
          subscription.assign_attributes(
            p256dh_key: attrs[:p256dh_key],
            auth_key: attrs[:auth_key],
            user_agent: request.user_agent&.truncate(255),
            expired_at: nil
          )

          if save_claiming_endpoint(subscription, attrs[:endpoint])
            render json: { subscription: subscription_json(subscription) }, status: :created
          else
            render json: { error: subscription.errors.full_messages.join(", ") },
              status: :unprocessable_entity
          end
        end
      end

      # POST /api/v1/push/unsubscribe
      #
      # A POST, not a DELETE, and the endpoint travels in the body.
      #
      # The endpoint is a long, opaque, vendor-controlled URL, so it wants to
      # be in a body rather than a path or query string — nesting one URL in
      # another invites escaping bugs, and a query string would put a specific
      # person's device address into every access log along the way. But a
      # body on DELETE is poorly supported end to end (Rails' parsing of it,
      # and any proxy in between), so POST removes the ambiguity entirely.
      #
      # Scoped to current_user's own subscriptions: without that, knowing an
      # endpoint would be enough to unsubscribe someone else's device.
      # Deleting rather than expiring, because this is a deliberate opt-out and
      # there's nothing to diagnose later.
      def unsubscribe
        endpoint = params[:endpoint].presence
        return render json: { error: "endpoint is required" }, status: :bad_request if endpoint.nil?

        current_user.push_subscriptions.where(endpoint: endpoint).destroy_all
        # 204 whether or not a row existed — unsubscribing something already
        # gone is a success from the caller's point of view, and reporting 404
        # would leak whether an endpoint is registered.
        head :no_content
      end

      private

      # One transaction so a subscription can never be half-transferred: either
      # the previous owner's row is gone and this one exists, or neither
      # happened. Without it, a validation failure after the destroy would
      # leave the device subscribed to nobody.
      def save_claiming_endpoint(subscription, endpoint)
        ActiveRecord::Base.transaction do
          claim_endpoint_from_other_users!(endpoint)
          subscription.save!
        end
        true
      rescue ActiveRecord::RecordInvalid
        false
      end

      # Push endpoints are per browser *and per VAPID key* — not per user. On a
      # shared browser, the second person to sign in and subscribe gets the
      # exact same endpoint back, and genuinely needs this row: there is only
      # one device behind it, and it now belongs to them.
      #
      # So the transfer is real behaviour, not an attack to block. What the
      # unscoped finder got wrong was doing it silently, as a side effect of a
      # missing scope. Here it's deliberate and logged.
      #
      # Being precise about what this does and doesn't buy: the keys are taken
      # on trust, so anyone who learns an endpoint can still claim it. The
      # residual risk is a denial of service — the victim's device stops
      # receiving their notifications and starts receiving the claimant's —
      # not exfiltration, since nothing flows back to whoever made the call.
      # Endpoints are high-entropy vendor URLs that only appear in
      # #subscription_json to their own owner, so obtaining one is the hard
      # part. If that ever stops being true, the fix is to require proof of
      # possession (a signed challenge), not to block the transfer.
      def claim_endpoint_from_other_users!(endpoint)
        PushSubscription.where(endpoint: endpoint)
          .where.not(user_id: current_user.id)
          .find_each do |other|
            Rails.logger.info(
              "[push] endpoint reclaimed from user=#{other.user_id} by user=#{current_user.id} " \
              "— shared device, or a re-subscribe after switching accounts"
            )
            other.destroy!
          end
      end

      def subscription_json(subscription)
        {
          id: subscription.id,
          endpoint: subscription.endpoint,
          user_agent: subscription.user_agent,
          created_at: subscription.created_at
        }
      end
    end
  end
end
