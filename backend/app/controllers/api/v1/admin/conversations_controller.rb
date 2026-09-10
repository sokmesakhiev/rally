# frozen_string_literal: true

module Api
  module V1
    module Admin
      # Staff side of support chat. Inherits Admin::BaseController, so
      # authenticate_user! + require_admin! (which renders 404, not 403, so this
      # surface doesn't advertise itself) apply to every action.
      #
      # Unlike the participant side, every route here takes an `:id` — staff
      # read *other people's* conversations, which is exactly why the admin gate
      # is the whole authorization story and why the state changes are audited.
      class ConversationsController < BaseController
        # Every action looks a conversation up by id, so a mistyped one should
        # read as "not found" rather than an unhandled 500.
        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Conversation not found" }, status: :not_found
        end

        # How much of the participant's history to put beside the thread.
        # Enough for an agent to recognise what the person is talking about
        # without turning the sidebar into a second product.
        CONTEXT_REGISTRATIONS = 5
        MESSAGE_PAGE_SIZE = 100

        # GET /api/v1/admin/conversations
        def index
          validate_params_with_schema(AdminConversationIndexRequestSchema) do |query|
            page     = query[:page] || 1
            per_page = query[:per_page] || AdminConversationIndexRequestSchema::DEFAULT_PER_PAGE

            scope = filtered(query)
            total = scope.count

            conversations = scope
              .includes(user: :profile)
              .newest_activity_first
              .offset((page - 1) * per_page)
              .limit(per_page)
              .to_a

            # One query for the page's unread flags, not one per row.
            unread_ids = Conversation.unread_ids_among(conversations)

            render json: {
              conversations: conversations.map { |c| summary_json(c, unread: unread_ids.include?(c.id)) },
              meta: pagination_meta(page, per_page, total),
              # The inbox badge. Counted independently of the current filter,
              # since it's "how much is waiting on us" rather than "how many
              # rows are on this screen".
              awaiting_count: Conversation.awaiting_staff.count
            }
          end
        end

        # GET /api/v1/admin/conversations/:id
        #
        # Returns the thread plus the participant context that motivated
        # building this rather than buying a hosted widget: an agent can see
        # which events this person registered for and whether they paid,
        # without leaving the page or looking them up by email.
        def show
          conversation = find_conversation

          render json: {
            conversation: detail_json(conversation),
            participant: participant_json(conversation.user),
            # reorder, not order: the has_many carries a default ascending
            # order that `order` would append to rather than replace. Newest
            # page, flipped back to reading order.
            # includes(sender: :profile) because message_json names the sender,
            # and without it a 100-message thread walks sender and profile per
            # row — up to 200 extra queries to render one page. Most of those
            # rows share two or three senders, so preloading collapses the
            # whole lot into two queries.
            messages: conversation.messages
              .includes(sender: :profile)
              .reorder(created_at: :desc, id: :desc)
              .limit(MESSAGE_PAGE_SIZE)
              .to_a.reverse.map { |m| message_json(m) }
          }
        end

        # POST /api/v1/admin/conversations/:id/messages
        #
        # Deliberately *not* audited. The message row is itself a permanent,
        # attributed record of what this admin did — duplicating every reply
        # into admin_actions would drown the moderation history that table
        # exists to make queryable.
        #
        # Also deliberately not given its own rack-attack throttle, unlike the
        # participant endpoint. That one is exposed to arbitrary internet users;
        # this one requires `users.admin`, which is granted only from a console.
        # A per-user limit here would mostly punish an agent working through a
        # backlog, and singling out chat replies would be odd when suspending a
        # user or deleting an event — far more destructive, same audience — are
        # not throttled either. The blanket `req/ip` limit still applies.
        def reply
          conversation = find_conversation

          validate_params_with_schema(SupportMessageCreateRequestSchema) do |output|
            message = ::Conversations::PostMessage.call(
              conversation: conversation,
              sender: current_user,
              body: output[:body].strip
            )

            render json: {
              message: message_json(message),
              conversation: detail_json(conversation.reload)
            }, status: :created
          end
        end

        # POST /api/v1/admin/conversations/:id/assign
        #
        # A soft claim — "I'm looking at this" — not exclusive ownership.
        # Anyone can take a thread someone else holds; the value is visibility,
        # not locking, and enforcing exclusivity would just mean threads
        # stranded on whoever went on holiday.
        #
        # Claiming for *yourself* only. Assigning work to another admin is a
        # routing feature, and Open Question 1 in support-chat-tickets.md
        # ("how many staff, and are they concurrent?") is unanswered — with one
        # or two people it's pure overhead. Easy to add once that's known.
        # Refused on a resolved thread: a claim means "I'm working this", and
        # there is no work left on a closed conversation. Allowing it would
        # write an audit row for something that can never be acted on, and put
        # a dead thread in someone's "mine" filter.
        def assign
          conversation = find_conversation

          if conversation.resolved?
            render json: { error: "This conversation is already resolved.", code: "conversation_resolved" },
                   status: :unprocessable_entity
            return
          end

          conversation.update!(assigned_admin: current_user)
          log_admin_action("assign_conversation", conversation)

          render json: { conversation: detail_json(conversation) }
        end

        # POST /api/v1/admin/conversations/:id/unassign
        #
        # Deliberately *not* subject to the resolved check above. Releasing a
        # claim on a thread that got resolved while it was assigned is exactly
        # the stale state worth cleaning up, so the asymmetry is the point:
        # taking on dead work is meaningless, letting go of it isn't.
        def unassign
          conversation = find_conversation
          conversation.update!(assigned_admin: nil)
          log_admin_action("unassign_conversation", conversation)

          render json: { conversation: detail_json(conversation) }
        end

        # POST /api/v1/admin/conversations/:id/resolve
        #
        # Audited: this ends the thread and frees the participant's one live
        # slot, so it's a state change someone may need to account for later.
        def resolve
          conversation = find_conversation
          changed = ::Conversations::Resolve.call(conversation: conversation)
          log_admin_action("resolve_conversation", conversation) if changed

          render json: { conversation: detail_json(conversation.reload) }
        end

        # POST /api/v1/admin/conversations/:id/read
        #
        # Not audited — reading something isn't a moderation action, and an
        # agent scrolling an inbox would otherwise generate more audit rows
        # than every other admin action combined.
        def read
          conversation = find_conversation
          conversation.mark_read_for_staff!

          render json: { conversation: detail_json(conversation) }
        end

        private

        def find_conversation
          Conversation.find(params[:id])
        end

        def filtered(query)
          scope = Conversation.all

          case query[:status]
          when "live"     then scope = scope.live
          when "open"     then scope = scope.where(status: Conversation::OPEN)
          when "pending"  then scope = scope.where(status: Conversation::PENDING)
          when "resolved" then scope = scope.resolved
          end

          case query[:assignment]
          when "mine"       then scope = scope.assigned_to(current_user)
          when "unassigned" then scope = scope.unassigned
          end

          # The bare predicate rather than `awaiting_staff`, which would also
          # drag in that scope's `live` constraint and silently override an
          # explicit `status=resolved`. Filters should compose, not fight.
          #
          # Only filters *down* to unread — `unread=false` would mean "threads
          # we've already read", which nobody asks an inbox for.
          scope = scope.with_unread_from_participant if query[:unread]

          scope
        end

        # Shapes live in Support::Serializers — shared with the participant
        # controller and, since Ticket D, with the WebSocket broadcast.
        #
        # `unread:` is passed in for a page (computed once for all rows by
        # Conversation.unread_ids_among) and falls back to the per-row query for
        # a single conversation, where one extra query is cheaper than the
        # plumbing to avoid it.
        def summary_json(conversation, unread: nil)
          ::Support::Serializers.staff_conversation(conversation, unread: unread)
        end

        def detail_json(conversation)
          ::Support::Serializers.staff_conversation_detail(conversation)
        end

        def message_json(message)
          ::Support::Serializers.staff_message(message)
        end

        def participant_json(user)
          {
            id: user.id,
            email: user.email,
            display_name: user.profile&.display_name,
            suspended: user.suspended?,
            created_at: user.created_at,
            registrations: registration_context(user)
          }
        end

        # The whole argument for building this in-house rather than embedding a
        # hosted widget: the agent sees the person's actual Rally state next to
        # what they're asking about.
        def registration_context(user)
          registrations = user.registrations
            .includes(:event)
            .order(created_at: :desc)
            .limit(CONTEXT_REGISTRATIONS)
            .to_a

          refunded = refunded_cents_by_registration(registrations.map(&:id))

          registrations.map do |registration|
            {
              id: registration.id,
              event_title: registration.event&.title,
              status: registration.status,
              payment_status: registration.payment_status,
              amount_paid_cents: registration.amount_paid_cents,
              refunded_cents: refunded[registration.id].to_i,
              created_at: registration.created_at
            }
          end
        end

        # One grouped query rather than a refund lookup per registration —
        # this sidebar renders on every thread an agent opens.
        def refunded_cents_by_registration(registration_ids)
          return {} if registration_ids.empty?

          Refund
            .joins(:payment)
            .where(payments: { registration_id: registration_ids }, status: "succeeded")
            .group("payments.registration_id")
            .sum(:amount_cents)
        end

        def pagination_meta(page, per_page, total)
          {
            page: page,
            per_page: per_page,
            total_count: total,
            total_pages: total.zero? ? 0 : (total.to_f / per_page).ceil
          }
        end
      end
    end
  end
end
