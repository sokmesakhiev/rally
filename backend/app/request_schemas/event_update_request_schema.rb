# frozen_string_literal: true

# Validates PATCH /api/v1/events/:id (EventsController#update). A sibling
# of EventRequestSchema, not a subclass — PATCH semantics are genuinely
# different, not just "the same fields, less strict":
#
#   * Every field is optional here (vs. title/category/start_at being
#     required on create), because a PATCH may only touch one field (e.g.
#     the manage-event page's branding save only ever sends brand_color/
#     banner_url/logo_url — see dashboard_.events.$eventId.tsx). A key that
#     dry-schema doesn't see in the input is simply absent from
#     `validated_params[:event]` too, so @event.update(...) only ever
#     touches the fields actually submitted — it never nils out unrelated
#     columns the way including every optional key with a null default
#     would.
#   * capacity, plan, and is_published are excluded for the same reason as
#     EventRequestSchema: only EventPlanPaymentsController's #mark_paid! and
#     #unpublish may ever set them.
#   * event_types_attributes additionally accepts `id` (to update an
#     existing type) and `_destroy` (to remove one) — create never needs
#     either since there's nothing to reference yet.
#
# The rules below only catch the common case where both sides of a
# cross-field check are submitted together in the same request — they
# can't see the rest of the record. Event's own validations
# (end_after_start, lat_lng_present_together, capacity_covers_event_types)
# remain the real backstop, since they run against the record's full state
# after assignment, partial update or not.
class EventUpdateRequestSchema < ApplicationRequestSchema
  params do
    required(:event).hash do
      optional(:title).filled(:string)
      optional(:description).maybe(:string)
      optional(:category).filled(:string)
      optional(:location).maybe(:string)
      optional(:latitude).maybe(:float)
      optional(:longitude).maybe(:float)
      optional(:route_map_url).maybe(:string)
      optional(:start_at).filled(:string)
      optional(:end_at).maybe(:string)
      optional(:price_cents).maybe(:integer)
      optional(:currency).maybe(:string)
      optional(:brand_color).maybe(:string)
      optional(:banner_url).maybe(:string)
      optional(:logo_url).maybe(:string)
      optional(:certificate_template_url).maybe(:string)
      # events.survey_id is a uuid column (see db/schema.rb), not an integer.
      optional(:survey_id).maybe(:string)
      optional(:event_types_attributes).array(:hash) do
        optional(:id).filled(:string)
        optional(:name).filled(:string)
        optional(:description).maybe(:string)
        optional(:capacity).maybe(:integer)
        optional(:price_cents).maybe(:integer)
        optional(:position).filled(:integer)
        optional(:_destroy).maybe(:bool)
      end
    end
  end

  rule(event: %i[start_at end_at]) do
    start_at = values[:event][:start_at]
    end_at = values[:event][:end_at]
    if start_at && end_at && start_at >= end_at
      key([ :event, :start_at ]).failure("must be before end_at")
    end
  end

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
