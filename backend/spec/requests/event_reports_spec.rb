require "rails_helper"

RSpec.describe "Reporting an event", type: :request do
  let(:event) { create(:event) }
  let(:reporter) { create(:user) }

  def report(as: nil, reason: "violence", details: nil)
    post "/api/v1/events/#{event.id}/reports",
         params: { report: { reason: reason, details: details }.compact },
         headers: as ? auth_headers(as) : {},
         as: :json
  end

  describe "who can report" do
    it "accepts a signed-in report and records who made it" do
      expect { report(as: reporter) }.to change(EventReport, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(EventReport.last.reporter).to eq(reporter)
    end

    # Deliberate: the person best placed to report a gathering they're
    # frightened of may not want an account attached to it, and requiring one
    # filters out exactly the reports worth having. Rate limits do the job an
    # account requirement would.
    it "accepts an anonymous report" do
      expect { report }.to change(EventReport, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(EventReport.last.reporter).to be_nil
    end
  end

  describe "the response" do
    # The endpoint must not become an oracle for probing Rally's moderation
    # state. Reporting an already-reported, already-suspended event says
    # exactly the same thing as reporting a clean one.
    it "says the same thing whether or not the event is already reported" do
      report(as: create(:user))
      first_body = json

      report(as: reporter)

      expect(response).to have_http_status(:created)
      expect(json).to eq(first_body)
    end

    it "says the same thing for a duplicate from the same reporter" do
      report(as: reporter)
      first_body = json

      expect { report(as: reporter) }.not_to change(EventReport, :count)

      expect(response).to have_http_status(:created)
      expect(json).to eq(first_body)
    end

    # The validation and the partial unique index are the same rule twice, and
    # a race decides which one fires. The index path used to escape as a 500 —
    # which is an oracle of its own, and one only a duplicate reporter would
    # ever see.
    it "says the same thing when the index catches the duplicate, not the validation" do
      report(as: reporter)
      first_body = json

      allow_any_instance_of(EventReport).to receive(:save)
        .and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))

      report(as: reporter)

      expect(response).to have_http_status(:created)
      expect(json).to eq(first_body)
    end

    it "says the same thing for an already-suspended event" do
      event.suspend!(reason: "under review")

      report(as: reporter)

      expect(response).to have_http_status(:created)
    end
  end

  describe "validation" do
    it "rejects a reason outside the four categories plus other" do
      report(as: reporter, reason: "i_just_dont_like_it")

      expect(response).to have_http_status(:unprocessable_content)
      expect(json["error"]).to include("reason")
    end

    %w[political gambling violence discrimination other].each do |reason|
      it "accepts #{reason}" do
        report(as: reporter, reason: reason)

        expect(response).to have_http_status(:created)
      end
    end

    it "accepts a report with no details, because friction here loses reports" do
      report(as: reporter, details: nil)

      expect(response).to have_http_status(:created)
    end

    it "404s for an unknown event without confirming whether the id exists" do
      post "/api/v1/events/#{SecureRandom.uuid}/reports",
           params: { report: { reason: "violence" } }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "notifying staff" do
    let!(:admin) { create(:user, admin: true) }

    it "puts a row in every admin's bell" do
      expect { report(as: reporter) }.to change {
        Notification.where(user_id: admin.id, kind: "event_reported").count
      }.by(1)
    end

    # An event with twelve reports is one item of work, not twelve. Volume
    # belongs in the queue's priority, not in the bell.
    it "does not stack a second unread row for the same event" do
      report(as: create(:user))

      expect { report(as: create(:user)) }.not_to change {
        Notification.where(user_id: admin.id, kind: "event_reported").count
      }
    end

    it "notifies again once the admin has read and dismissed the first" do
      report(as: create(:user))
      Notification.where(user_id: admin.id).update_all(read_at: Time.current)

      expect { report(as: create(:user)) }.to change {
        Notification.where(user_id: admin.id, kind: "event_reported").count
      }.by(1)
    end

    it "skips suspended and deleted staff accounts" do
      create(:user, admin: true, suspended_at: Time.current)

      report(as: reporter)

      expect(Notification.where(kind: "event_reported").count).to eq(1)
    end

    # Losing the report is the one outcome this feature exists to prevent.
    it "still saves the report if the notification fails" do
      allow(Notification).to receive(:create!).and_raise("boom")

      expect { report(as: reporter) }.to change(EventReport, :count).by(1)
      expect(response).to have_http_status(:created)
    end
  end

  # No number of reports hides anything. Auto-hiding on a threshold hands
  # anyone with a few accounts a button that takes down a competitor's event.
  describe "what reporting never does" do
    it "leaves the event published no matter how many reports it has" do
      15.times { report(as: create(:user)) }

      expect(event.reload.is_published).to be(true)
      expect(event.reload).not_to be_suspended
    end
  end
end
