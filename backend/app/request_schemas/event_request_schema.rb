# frozen_string_literal: true

# Validates POST /api/v1/events (EventsController#create) before the
# params ever reach the model. Deliberately mirrors — not duplicates —
# app/models/event.rb's own validations for the fields that matter at
# creation time (see class comment in events_controller.rb):
#
#   * capacity, plan, and is_published are NOT accepted here at all. They're
#     only ever set via the paid publish flow (EventPlanPaymentsController)
#     or #unpublish — accepting them from this endpoint would let any
#     authenticated user publish an uncapped event for free, bypassing
#     Event::PLANS entirely. Keep it that way if this schema is ever
#     extended to more fields.
#   * Most fields are optional/nilable because the frontend (events.new.tsx)
#     sends null for anything the organizer left blank (description,
#     location, latitude/longitude when the Google Maps picker fell back to
#     plain text, route_map_url, survey_id, banner/logo before upload).
#     Model-level validation (presence/format) still applies underneath —
#     this schema exists to catch bad shapes early and cheaply, not to
#     replace the model's validations, so EventsController#create still
#     rescues ActiveRecord::RecordInvalid.
class EventRequestSchema < ApplicationRequestSchema
  params do
    required(:event).hash do
      required(:title).filled(:string)
      optional(:description).value(:string)
      required(:category).filled(:string)
      optional(:location).maybe(:string)
      optional(:latitude).maybe(:float)
      optional(:longitude).maybe(:float)
      optional(:route_map_url).maybe(:string)
      # Refund policy tiers (platform-payments-tickets.md Ticket D). Shape is
      # checked here; the ordering/range rules live in RefundPolicy and are
      # surfaced by Event#refund_policy_well_formed, so there is one source of
      # truth for what a valid policy is rather than two that can drift.
      # `maybe` because clearing a policy back to "unset" is a legitimate edit.
      optional(:refund_policy_tiers).maybe(:array).each do
        hash do
          required(:hours_before).filled(:integer)
          required(:refund_percent).filled(:integer)
        end
      end
      required(:start_at).filled(:string)
      optional(:end_at).maybe(:string)
      optional(:price_cents).maybe(:integer)
      optional(:currency).maybe(:string)
      optional(:brand_color).maybe(:string)
      optional(:banner_url).maybe(:string)
      optional(:logo_url).maybe(:string)
      # events.survey_id is a uuid column (see db/schema.rb), not an integer.
      optional(:survey_id).maybe(:string)
      # OPTIONAL only transitionally. The end state is required — a user may
      # administer several organizations, so the caller should say which one
      # presents the event rather than have the server guess.
      #
      # It can't be required *yet*: the frontend doesn't send it until Ticket
      # G (#336) adds the org selector, and flipping this to required first
      # would break event creation for everyone in the meantime — not just
      # during the deploy window, but until #336 actually ships.
      # EventsController#resolve_organization_for_create! handles the absent
      # case and documents exactly what to delete here when #336 lands. Also
      # a uuid column, hence :string.
      optional(:organization_id).maybe(:string)
      # Matches accepts_nested_attributes_for :event_types on Event — the
      # association setter is event_types_attributes=, not event_types=, so
      # using the wrong key here would raise ActiveRecord::AssociationTypeMismatch
      # instead of building nested EventType records.
      optional(:event_types_attributes).array(:hash) do
        optional(:name).filled(:string)
        optional(:description).maybe(:string)
        optional(:capacity).maybe(:integer)
        optional(:price_cents).maybe(:integer)
        optional(:position).filled(:integer)
      end
    end
  end

  # Nested-key rules below use `values[:event][...]` (the full result hash)
  # rather than any parent-scoped shorthand — dry-validation's automatic
  # rule-skipping-on-upstream-failure is best documented for flat top-level
  # keys, so these guard against nil explicitly instead of assuming a
  # failed required(:start_at) already short-circuited the rule.
  rule(event: %i[start_at end_at]) do
    start_at = values[:event][:start_at]
    end_at = values[:event][:end_at]
    if start_at && end_at && start_at >= end_at
      key([ :event, :start_at ]).failure("must be before end_at")
    end
  end

  # Both-or-neither, matching Event#lat_lng_present_together — a half-set
  # pin should never reach the model as a "valid-shaped but wrong" request.
  rule(event: %i[latitude longitude]) do
    lat = values[:event][:latitude]
    lng = values[:event][:longitude]
    if lat.nil? != lng.nil?
      key([ :event, :latitude ]).failure("latitude and longitude must both be set, or both left blank")
    end
  end

  rule(event: :event_types_attributes) do
    event_types = values[:event][:event_types_attributes]
    next if event_types.blank?

    event_types.each_with_index do |event_type, index|
      capacity = event_type[:capacity]
      if capacity && capacity <= 0
        key([ :event, :event_types_attributes, index, :capacity ]).failure("must be greater than 0")
      end
    end
  end
end
