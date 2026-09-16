require "rails_helper"

# The shape of a 422 from ValidateParams#build_error_response.
#
# This exists because the body used to be actively unhelpful: `errors` collapsed
# to ["general_error"] for any message without a `meta[:code]` (which is most of
# them — every stock dry-schema message), and `error` was the bare text, so a
# real response looked like:
#
#   { "errors": ["general_error"], "error": "must be a string" }
#
# Both true, neither actionable. Finding out *which* of seventeen fields was
# meant required reading the schema source.
RSpec.describe "Schema validation error bodies", type: :request do
  let(:user) { create(:user) }
  let(:organization) { create(:organization, owner: user) }

  def create_event(event_attrs)
    post "/api/v1/events",
         params: { event: event_attrs },
         headers: auth_headers(user),
         as: :json
  end

  let(:base) do
    { title: "Sunrise 10K", category: "running",
      start_at: 1.week.from_now.iso8601, organization_id: organization.id }
  end

  describe "the human-readable `error`" do
    it "names the field that failed, not just what was wrong with it" do
      create_event(base.merge(price_cents: "not-a-number"))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to include("price_cents")
    end

    it "keeps the underlying message alongside the field" do
      create_event(base.merge(title: nil))

      expect(json["error"]).to match(/title.*must be/i)
    end

    it "lists every failure, not only the first" do
      create_event(base.merge(title: nil, price_cents: "nope"))

      expect(json["error"]).to include("title").and include("price_cents")
    end
  end

  describe "the structured `details`" do
    it "gives field and message separately, so a form can mark the input" do
      create_event(base.merge(price_cents: "not-a-number"))

      expect(json["details"]).to include(
        hash_including("field" => "event.price_cents")
      )
      expect(json["details"].first["message"]).to be_present
    end

    # Losing the index would point an organizer at the wrong row of the form.
    it "includes the array index for a failure inside event_types_attributes" do
      create_event(base.merge(
        event_types_attributes: [
          { name: "5K", position: 0 },
          { name: "10K", position: 1, capacity: 0 }
        ]
      ))

      expect(json["details"]).to include(
        hash_including("field" => "event.event_types_attributes.1.capacity")
      )
    end
  end

  describe "what deliberately did not change" do
    # api-client.ts reads only `.error` and `.code`; `errors` predates this and
    # something may still consume it.
    it "still returns the machine-readable errors array" do
      create_event(base.merge(title: nil))

      expect(json["errors"]).to be_an(Array).and be_present
    end

    it "still uses 422 and the standard envelope" do
      create_event(base.merge(title: nil))

      expect(response).to have_http_status(:unprocessable_content)
      expect(json).to include("success" => false, "code" => 422)
    end

    # Tested against a throwaway contract rather than a real endpoint, because
    # **no schema in this app currently sets a code**: `meta[:code]` is empty on
    # every message, which is exactly why `errors` is always ["general_error"]
    # and why `details` had to be added. ApplicationRequestSchema registers a
    # `validate_email` macro that does set one — and nothing uses it. The branch
    # is still live code, so it gets a test; the day a schema starts using it,
    # this is what says whether it survived.
    it "preserves a schema's own error code when one is set" do
      contract = Class.new(ApplicationRequestSchema) do
        params { required(:email).filled(:string) }

        rule(:email) do
          key.failure(text: "is not an email", code: ErrorCodes::EMAIL_FORMAT_IS_INVALID)
        end
      end

      request = ActiveSupport::OrderedOptions.new
      request.params = { email: "not-an-email" }
      errors = contract.new(request: request).errors

      body = Class.new { include ValidateParams }.new.build_error_response(errors)

      expect(body["errors"]).to eq([ ErrorCodes::EMAIL_FORMAT_IS_INVALID ])
      expect(body["error"]).to eq("email is not an email")
    end
  end
end
