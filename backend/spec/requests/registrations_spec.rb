require "rails_helper"

RSpec.describe "Registrations API", type: :request do
  let(:organizer)    { create(:user) }
  let(:participant)  { create(:user) }
  let(:other)        { create(:user) }

  # ── GET /api/v1/registrations ────────────────────────────────────────────────
  describe "GET /api/v1/registrations" do
    let!(:my_reg)    { create(:registration, user: participant) }
    let!(:other_reg) { create(:registration, user: other) }

    it "returns only the current user's registrations with event data" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      expect(response).to have_http_status(:ok)
      ids = json["registrations"].map { |r| r["id"] }
      expect(ids).to include(my_reg.id)
      expect(ids).not_to include(other_reg.id)
    end

    it "includes nested event data" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json["event"]).to be_present
      expect(reg_json["event"]["id"]).to eq(my_reg.event_id)
    end

    it "returns 401 without a token" do
      get "/api/v1/registrations", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "omits certificate_url when no certificate has been generated yet" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json).not_to have_key("certificate_url")
    end

    it "includes certificate_url once a certificate has been generated" do
      create(:certificate, :with_file, registration: my_reg)

      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == my_reg.id }
      expect(reg_json["certificate_url"]).to be_present
    end
  end

  # ── POST /api/v1/events/:event_id/registrations ──────────────────────────────
  describe "POST /api/v1/events/:event_id/registrations" do
    let!(:event) { create(:event, creator: organizer) }

    it "registers the current user for the event" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:created)
      expect(json["registration"]["event_id"]).to eq(event.id)
      expect(json["registration"]["user_id"]).to eq(participant.id)
    end

    it "sets payment_status to paid for a free event" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(json["registration"]["payment_status"]).to eq("paid")
    end

    it "sets payment_status to unpaid for a paid event" do
      paid_event = create(:event, :paid, creator: organizer)
      post "/api/v1/events/#{paid_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(json["registration"]["payment_status"]).to eq("unpaid")
    end

    # See change-event-plan-tickets.md's "Ticket B" — amount_owed_cents is
    # snapshotted once at creation so it stays fixed even if the organizer
    # edits the price later while the registration is still unpaid (see
    # Registration#owed_amount_cents and spec/models/registration_spec.rb).
    it "snapshots amount_owed_cents at creation time from the event's price" do
      paid_event = create(:event, :paid, price_cents: 2500, creator: organizer)

      post "/api/v1/events/#{paid_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      registration = Registration.find(json["registration"]["id"])
      expect(registration.amount_owed_cents).to eq(2500)
    end

    it "snapshots amount_owed_cents from the selected event type's price, not the flat event price" do
      typed_event = create(:event, :paid, price_cents: 2500, creator: organizer)
      type = typed_event.event_types.create!(name: "10K", price_cents: 4000, position: 0)

      post "/api/v1/events/#{typed_event.id}/registrations",
           params: { event_type_ids: [ type.id ] },
           headers: auth_headers(participant),
           as: :json

      registration = Registration.find(json["registration"]["id"])
      expect(registration.amount_owed_cents).to eq(4000)
    end

    it "prevents double-registration" do
      create(:registration, event: event, user: participant)
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 422 with a clean message and code when the event is full" do
      full_event = create(:event, capacity: 1, creator: organizer)
      create(:registration, event: full_event)

      post "/api/v1/events/#{full_event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("This event is full")
      expect(json["code"]).to eq("full")
    end

    it "returns 422 with a clean message and code when the selected event type is full" do
      typed_event = create(:event, creator: organizer)
      full_type = typed_event.event_types.create!(name: "5K", capacity: 1, position: 0)
      create(:registration, event: typed_event).registration_event_types.create!(event_type: full_type)

      post "/api/v1/events/#{typed_event.id}/registrations",
           params: { event_type_ids: [ full_type.id ] },
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("5K is full")
      expect(json["code"]).to eq("full")
    end

    it "does not set a code for non-capacity failures" do
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json
      post "/api/v1/events/#{event.id}/registrations",
           headers: auth_headers(participant),
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to eq("Already registered")
      expect(json["code"]).to be_nil
    end

    # No token is no longer a hard 401 here — see the "guest checkout"
    # describe block below. Without a token *and* without guest info, it's
    # a 422 asking for one or the other.
    it "requires either a token or guest info when there's no session" do
      post "/api/v1/events/#{event.id}/registrations", as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("guest_info_required")
    end
  end

  # ── POST /api/v1/events/:event_id/registrations (guest checkout) ─────────────
  describe "POST /api/v1/events/:event_id/registrations — guest checkout" do
    let!(:event) { create(:event, creator: organizer) }

    it "creates a real account for a never-seen email and registers under it" do
      expect {
        post "/api/v1/events/#{event.id}/registrations",
          params: { guest: { name: "Dara Kim", email: "dara@example.com" } },
          as: :json
      }.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      user = User.find_by(email: "dara@example.com")
      expect(user).to be_present
      expect(user.profile.display_name).to eq("Dara Kim")
      expect(json["registration"]["user_id"]).to eq(user.id)
    end

    # Guest checkout never issues a session, whether the account is brand
    # new or an existing one — see Registrations::GuestCheckout's class
    # comment. Payment is authorized later via matching contact info
    # instead (see the Payments API spec).
    it "does not return an auth token for a brand-new guest registration" do
      post "/api/v1/events/#{event.id}/registrations",
        params: { guest: { name: "Dara Kim", email: "dara@example.com" } },
        as: :json

      expect(response).to have_http_status(:created)
      expect(json).not_to have_key("auth")
    end

    it "does not return an auth token for a signed-in request" do
      post "/api/v1/events/#{event.id}/registrations", headers: auth_headers(participant), as: :json

      expect(response).to have_http_status(:created)
      expect(json).not_to have_key("auth")
    end

    it "attaches to the existing account when the email matches, without creating a duplicate or a session" do
      # Force the lazy `let` to create participant *before* the count is
      # sampled — referencing it for the first time inside the `expect`
      # block would count participant's own creation as the change.
      existing_email = participant.email

      expect {
        post "/api/v1/events/#{event.id}/registrations",
          params: { guest: { name: "Someone Else", email: existing_email } },
          as: :json
      }.not_to change(User, :count)

      expect(response).to have_http_status(:created)
      expect(json["registration"]["user_id"]).to eq(participant.id)
      expect(json).not_to have_key("auth")
    end

    it "requires a name" do
      post "/api/v1/events/#{event.id}/registrations",
        params: { guest: { email: "dara@example.com" } },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "requires a phone number or email" do
      post "/api/v1/events/#{event.id}/registrations",
        params: { guest: { name: "Dara Kim" } },
        as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["code"]).to eq("contact_required")
    end

    it "sends the confirmation email with a claim-your-account nudge for a brand-new guest account" do
      perform_enqueued_jobs do
        post "/api/v1/events/#{event.id}/registrations",
          params: { guest: { name: "Dara Kim", email: "dara@example.com" } },
          as: :json
      end

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ "dara@example.com" ])
      expect(mail.body.encoded).to include("Set a password")
    end

    # Attaching to an existing account (see the "attaches to the existing
    # account" example above) is not the same as creating one — that
    # visitor already has an account, whether or not they remember it, so
    # the "you don't have a password yet" nudge would be actively
    # misleading.
    it "omits the claim-your-account nudge when attaching to an existing account" do
      perform_enqueued_jobs do
        post "/api/v1/events/#{event.id}/registrations",
          params: { guest: { name: "Someone Else", email: participant.email } },
          as: :json
      end

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq([ participant.email ])
      expect(mail.body.encoded).not_to include("Set a password")
    end

    # ── Phone-only — Cambodia's most common contact channel ──────────────────
    describe "registering with only a phone number" do
      it "creates an account with an auto-generated placeholder email" do
        expect {
          post "/api/v1/events/#{event.id}/registrations",
            params: { guest: { name: "Dara Kim", phone: "012 345 678" } },
            as: :json
        }.to change(User, :count).by(1)

        expect(response).to have_http_status(:created)
        user = User.find(json["registration"]["user_id"])
        expect(user.email_auto_generated?).to be(true)
        expect(user.email).to match(/@guest\.rally\.invalid\z/)
        expect(user.profile.phone).to eq("012 345 678")
      end

      it "does not return an auth token either" do
        post "/api/v1/events/#{event.id}/registrations",
          params: { guest: { name: "Dara Kim", phone: "012345678" } },
          as: :json

        expect(response).to have_http_status(:created)
        expect(json).not_to have_key("auth")
      end

      it "does not enqueue a confirmation email to the unreachable placeholder address" do
        expect {
          perform_enqueued_jobs do
            post "/api/v1/events/#{event.id}/registrations",
              params: { guest: { name: "Dara Kim", phone: "012345678" } },
              as: :json
          end
        }.not_to change { ActionMailer::Base.deliveries.count }
      end

      it "attaches to the existing account when the phone matches, without creating a duplicate" do
        participant.profile.update!(phone: "012345678")

        expect {
          post "/api/v1/events/#{event.id}/registrations",
            params: { guest: { name: "Someone Else", phone: "012345678" } },
            as: :json
        }.not_to change(User, :count)

        expect(response).to have_http_status(:created)
        expect(json["registration"]["user_id"]).to eq(participant.id)
      end
    end
  end

  # ── GET /api/v1/events/:event_id/registrations (organizer view) ──────────────
  describe "GET /api/v1/events/:event_id/registrations" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "returns participant list for the event organizer" do
      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registrations"].map { |r| r["id"] }).to include(reg.id)
    end

    it "excludes registrations the organizer has already removed" do
      removed = create(:registration, event: event)
      removed.discard!

      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(organizer),
          as: :json

      expect(response).to have_http_status(:ok)
      ids = json["registrations"].map { |r| r["id"] }
      expect(ids).to include(reg.id)
      expect(ids).not_to include(removed.id)
    end

    it "returns 404 when a non-organizer tries to access the list" do
      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(other),
          as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "includes certificate_url in the organizer view once generated" do
      create(:certificate, :with_file, registration: reg)

      get "/api/v1/events/#{event.id}/registrations",
          headers: auth_headers(organizer),
          as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["certificate_url"]).to be_present
    end
  end

  # ── GET /api/v1/events/:event_id/registrations/export ────────────────────────
  describe "GET /api/v1/events/:event_id/registrations/export" do
    let!(:event) { create(:event, creator: organizer, currency: "usd") }

    def csv_rows
      CSV.parse(response.body, headers: true)
    end

    it "returns a CSV with the base columns and a row per participant" do
      participant.profile.update!(phone: "012345678")
      registration = create(:registration, :paid, event: event, user: participant)
      registration.registration_event_types.create!(
        event_type: event.event_types.create!(name: "5K", position: 0)
      )
      registration.update!(checked_in_at: Time.zone.parse("2026-08-17 09:00:00 UTC"))

      get "/api/v1/events/#{event.id}/registrations/export", headers: auth_headers(organizer)

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("text/csv")
      expect(response.headers["Content-Disposition"]).to include("attachment")

      rows = csv_rows
      expect(rows.headers).to include(
        "Name", "Email", "Phone", "Event Type(s)", "Status", "Payment Status",
        "Amount Paid (USD)", "Checked In", "Checked In At", "Registered At"
      )
      row = rows.find { |r| r["Email"] == participant.email }
      expect(row["Phone"]).to eq("012345678")
      expect(row["Event Type(s)"]).to eq("5K")
      expect(row["Status"]).to eq("confirmed")
      expect(row["Payment Status"]).to eq("paid")
      expect(row["Amount Paid (USD)"]).to eq("25.00")
      expect(row["Checked In"]).to eq("Yes")
    end

    it "leaves Email blank rather than showing a phone-only guest's placeholder address" do
      checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Dara Kim")
      create(:registration, event: event, user: checkout.user)

      get "/api/v1/events/#{event.id}/registrations/export", headers: auth_headers(organizer)

      row = csv_rows.find { |r| r["Phone"] == "012345678" }
      expect(row["Email"]).to be_nil
      expect(row["Name"]).to eq("Dara Kim")
    end

    it "adds one column per survey question, with labels for choice answers" do
      survey = organizer.surveys.create!(title: "Race survey")
      text_q = survey.survey_questions.create!(
        question_text: "Anything else?", question_type: "text", position: 0
      )
      choice_q = survey.survey_questions.create!(
        question_text: "T-shirt size", question_type: "single_choice", position: 1,
        options: [ { "id" => "s", "label" => "Small" }, { "id" => "m", "label" => "Medium" } ]
      )
      event.update!(survey: survey)
      registration = create(:registration, event: event, user: participant)
      registration.registration_answers.create!(survey_question: text_q, answer_text: "See you there!")
      registration.registration_answers.create!(survey_question: choice_q, answer_options: [ "m" ])

      get "/api/v1/events/#{event.id}/registrations/export", headers: auth_headers(organizer)

      row = csv_rows.find { |r| r["Email"] == participant.email }
      expect(row["Anything else?"]).to eq("See you there!")
      expect(row["T-shirt size"]).to eq("Medium")
    end

    it "excludes registrations the organizer has already removed" do
      kept = create(:registration, event: event, user: participant)
      removed = create(:registration, event: event, user: other)
      removed.discard!

      get "/api/v1/events/#{event.id}/registrations/export", headers: auth_headers(organizer)

      emails = csv_rows.map { |r| r["Email"] }
      expect(emails).to include(kept.user.email)
      expect(emails).not_to include(removed.user.email)
    end

    it "returns 404 when a non-organizer requests the export" do
      get "/api/v1/events/#{event.id}/registrations/export", headers: auth_headers(other)

      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      get "/api/v1/events/#{event.id}/registrations/export"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ── PATCH /api/v1/registrations/:id ─────────────────────────────────────────
  describe "PATCH /api/v1/registrations/:id" do
    let!(:event) { create(:event, :paid, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "allows the organizer to mark a registration as paid" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "paid", amount_paid_cents: 2500 } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registration"]["payment_status"]).to eq("paid")
      expect(json["registration"]["amount_paid_cents"]).to eq(2500)
    end

    it "returns 403 when a non-organizer tries to update" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "paid", amount_paid_cents: 2500 } },
            headers: auth_headers(other),
            as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 422 for an unknown payment_status (schema)" do
      patch "/api/v1/registrations/#{reg.id}",
            params: { registration: { payment_status: "bogus" } },
            headers: auth_headers(organizer),
            as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to be_present
      expect(reg.reload.payment_status).not_to eq("bogus")
    end

    # No "missing registration wrapper key" case here: Rails' ParamsWrapper
    # (active by default for JSON requests, even with config.api_only = true)
    # auto-nests any flat top-level params matching a Registration attribute
    # name (payment_status, amount_paid_cents, ...) under a "registration"
    # key before the schema ever runs, so that key is guaranteed present on
    # every real JSON request here — there's no request shape that can
    # trigger required(:registration) failing in practice.
  end

  # ── DELETE /api/v1/registrations/:id ────────────────────────────────────────
  describe "DELETE /api/v1/registrations/:id" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "soft-deletes the registration rather than destroying the row" do
      # See Registration#discard! — the row (and any Payment/Refund history)
      # survives, just hidden and marked cancelled so it frees its capacity
      # slot.
      delete "/api/v1/registrations/#{reg.id}",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(Registration.kept.find_by(id: reg.id)).to be_nil
      reg.reload
      expect(reg.discarded?).to be(true)
      expect(reg.status).to eq("cancelled")
    end

    it "returns 403 when a non-organizer tries to remove" do
      delete "/api/v1/registrations/#{reg.id}",
             headers: auth_headers(other),
             as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "logs an EventActivity with the organizer as actor and the participant's name/email snapshotted" do
      reg.user.profile.update!(display_name: "Dara Kim")

      expect {
        delete "/api/v1/registrations/#{reg.id}", headers: auth_headers(organizer), as: :json
      }.to change(EventActivity, :count).by(1)

      activity = EventActivity.last
      expect(activity.event).to eq(event)
      expect(activity.actor).to eq(organizer)
      expect(activity.action).to eq("remove_participant")
      expect(activity.metadata["registration_id"]).to eq(reg.id)
      expect(activity.metadata["participant_name"]).to eq("Dara Kim")
      expect(activity.metadata["participant_email"]).to eq(reg.user.email)
    end

    it "omits participant_email for a phone-only guest's unreachable placeholder address" do
      checkout = Registrations::GuestCheckout.call(email: nil, phone: "012345678", name: "Dara Kim")
      guest_reg = create(:registration, event: event, user: checkout.user)

      delete "/api/v1/registrations/#{guest_reg.id}", headers: auth_headers(organizer), as: :json

      expect(EventActivity.last.metadata["participant_email"]).to be_nil
    end

    it "promotes the longest-waiting waitlist entry when removing a participant frees a spot" do
      full_event = create(:event, :full, creator: organizer)
      full_reg   = full_event.registrations.first
      waiter     = create(:waitlist_entry, event: full_event)

      delete "/api/v1/registrations/#{full_reg.id}",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(waiter.reload.status).to eq("promoted")
      expect(Registration.exists?(event_id: full_event.id, user_id: waiter.user_id)).to be(true)
    end
  end

  # ── POST /api/v1/registrations/:id/check_in ─────────────────────────────────
  describe "POST /api/v1/registrations/:id/check_in" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event) }

    it "marks the registration checked in" do
      post "/api/v1/registrations/#{reg.id}/check_in",
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:ok)
      expect(json["already_checked_in"]).to be(false)
      expect(json["registration"]["checked_in_at"]).to be_present
      expect(reg.reload.checked_in_at).to be_present
    end

    it "is idempotent — re-scanning reports already_checked_in without moving the timestamp" do
      post "/api/v1/registrations/#{reg.id}/check_in", headers: auth_headers(organizer), as: :json
      first_timestamp = reg.reload.checked_in_at

      post "/api/v1/registrations/#{reg.id}/check_in", headers: auth_headers(organizer), as: :json

      expect(response).to have_http_status(:ok)
      expect(json["already_checked_in"]).to be(true)
      expect(reg.reload.checked_in_at).to eq(first_timestamp)
    end

    it "returns 403 when a non-organizer tries to check someone in" do
      post "/api/v1/registrations/#{reg.id}/check_in",
           headers: auth_headers(other),
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "returns 401 without a token" do
      post "/api/v1/registrations/#{reg.id}/check_in", as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown registration" do
      post "/api/v1/registrations/00000000-0000-0000-0000-000000000000/check_in",
           headers: auth_headers(organizer),
           as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  # ── DELETE /api/v1/registrations/:id/check_in ───────────────────────────────
  describe "DELETE /api/v1/registrations/:id/check_in" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event, checked_in_at: Time.current) }

    it "clears the check-in" do
      delete "/api/v1/registrations/#{reg.id}/check_in",
             headers: auth_headers(organizer),
             as: :json

      expect(response).to have_http_status(:ok)
      expect(json["registration"]["checked_in_at"]).to be_nil
      expect(reg.reload.checked_in_at).to be_nil
    end

    it "returns 403 when a non-organizer tries to undo a check-in" do
      delete "/api/v1/registrations/#{reg.id}/check_in",
             headers: auth_headers(other),
             as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── finish_time_seconds exposure ─────────────────────────────────────────────
  describe "finish_time_seconds on registration_json" do
    let!(:event) { create(:event, creator: organizer) }
    let!(:reg)   { create(:registration, event: event, user: participant) }

    it "is omitted when no result has been recorded" do
      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json).not_to have_key("finish_time_seconds")
    end

    it "is present once a result has been recorded" do
      create(:result, registration: reg, finish_time_seconds: 5025)

      get "/api/v1/registrations", headers: auth_headers(participant), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["finish_time_seconds"]).to eq(5025)
    end

    it "is present in the organizer's view too" do
      create(:result, registration: reg, finish_time_seconds: 5025)

      get "/api/v1/events/#{event.id}/registrations", headers: auth_headers(organizer), as: :json

      reg_json = json["registrations"].find { |r| r["id"] == reg.id }
      expect(reg_json["finish_time_seconds"]).to eq(5025)
    end
  end
end
