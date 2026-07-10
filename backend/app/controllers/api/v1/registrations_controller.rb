module Api
  module V1
    class RegistrationsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_event, only: [ :create ]

      # GET /api/v1/registrations — current user's registrations with event data
      def index
        registrations = current_user.registrations
          .includes(event: :registrations, event_types: [])
          .order(created_at: :desc)

        render json: {
          registrations: registrations.map { |r| registration_json(r, include_event: true, include_types: true) }
        }
      end

      # GET /api/v1/events/:event_id/registrations — organizer view of participants
      def event_registrations
        event = current_user.events.find(params[:event_id])
        regs = event.registrations
          .includes({ user: :profile }, :event_types)
          .order(created_at: :asc)

        render json: {
          registrations: regs.map { |r| registration_json(r, include_profile: true, include_types: true) }
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # POST /api/v1/events/:event_id/registrations
      # Accepts:
      #   answers:        [{ survey_question_id, answer_text?, answer_options? }]
      #   event_type_ids: ["uuid", ...]
      def create
        if current_user.registrations.exists?(event_id: @event.id)
          render json: { error: "Already registered" }, status: :unprocessable_entity
          return
        end

        Registration.transaction do
          # Calculate amount from selected types (or fall back to event price)
          amount = compute_amount(@event, params[:event_type_ids])

          registration = current_user.registrations.create!(
            event: @event,
            status: "confirmed",
            payment_status: amount == 0 ? "paid" : "unpaid",
            amount_paid_cents: 0
          )

          # Wire up event types
          if params[:event_type_ids].present?
            type_ids = Array(params[:event_type_ids])
            type_ids.each do |type_id|
              registration.registration_event_types.create!(event_type_id: type_id)
            end
          end

          # Wire up survey answers
          if @event.survey_id.present? && params[:answers].present?
            params[:answers].each do |ans|
              registration.registration_answers.create!(
                survey_question_id: ans[:survey_question_id],
                answer_text:        ans[:answer_text].presence,
                answer_options:     ans[:answer_options] || []
              )
            end
          end

          RegistrationMailer.confirmation(registration).deliver_later

          render json: { registration: registration_json(registration, include_types: true) }, status: :created
        end
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH /api/v1/registrations/:id — organizer updates payment status
      def update
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        if registration.update(payment_update_params)
          render json: { registration: registration_json(registration, include_profile: true, include_types: true) }
        else
          render json: { error: registration.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      # DELETE /api/v1/registrations/:id — organizer removes participant
      def destroy
        registration = Registration.find(params[:id])
        event = registration.event

        unless event.creator_id == current_user.id
          render json: { error: "Forbidden" }, status: :forbidden
          return
        end

        registration.destroy!
        render json: { message: "Participant removed" }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Registration not found" }, status: :not_found
      end

      private

      def set_event
        @event = Event.includes(:event_types).find(params[:event_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      def payment_update_params
        params.require(:registration).permit(:payment_status, :amount_paid_cents)
      end

      # Sum the effective price of each selected type; fall back to event price if no types
      def compute_amount(event, type_ids)
        ids = Array(type_ids).compact.reject(&:empty?)
        return event.price_cents if ids.empty? || event.event_types.empty?

        types = event.event_types.select { |t| ids.include?(t.id) }
        types.sum(&:effective_price_cents)
      end

      def registration_json(reg, include_event: false, include_profile: false, include_types: false)
        json = {
          id: reg.id,
          event_id: reg.event_id,
          user_id: reg.user_id,
          status: reg.status,
          payment_status: reg.payment_status,
          amount_paid_cents: reg.amount_paid_cents,
          created_at: reg.created_at
        }

        if include_event && reg.association(:event).loaded?
          json[:event] = {
            id:           reg.event.id,
            title:        reg.event.title,
            description:  reg.event.description,
            category:     reg.event.category,
            location:     reg.event.location,
            start_at:     reg.event.start_at,
            end_at:       reg.event.end_at,
            capacity:     reg.event.capacity,
            price_cents:  reg.event.price_cents,
            currency:     reg.event.currency,
            is_published: reg.event.is_published,
            brand_color:  reg.event.brand_color,
            banner_url:   reg.event.banner_url,
            logo_url:     reg.event.logo_url
          }
        end

        if include_profile && reg.user&.profile
          json[:profile] = {
            display_name: reg.user.profile.display_name,
            avatar_url:   reg.user.profile.avatar_url
          }
        end

        if include_types
          types = reg.association(:event_types).loaded? ? reg.event_types : reg.event_types.to_a
          json[:event_types] = types.map do |t|
            { id: t.id, name: t.name, price_cents: t.price_cents, position: t.position }
          end
        end

        json
      end
    end
  end
end
