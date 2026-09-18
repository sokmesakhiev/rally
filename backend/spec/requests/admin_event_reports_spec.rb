require "rails_helper"

RSpec.describe "Admin event report queue", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:event) { create(:event, title: "Midnight Ride") }

  def add_reports(n, on: event, reason: "violence")
    n.times { create(:event_report, event: on, reporter: create(:user), reason: reason) }
  end

  describe "authorization" do
    # 404, not 403 — the admin surface doesn't advertise itself.
    it "404s for a non-admin" do
      get "/api/v1/admin/event_reports", headers: auth_headers(create(:user))

      expect(response).to have_http_status(:not_found)
    end

    it "401s with no token" do
      get "/api/v1/admin/event_reports"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "the queue" do
    # A reviewer's unit of work is "should this event stay up", not "what did
    # reporter #7 say". Twelve reports on one event is one decision.
    it "returns one row per event, not one per report" do
      add_reports(3)

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(json["reports"].length).to eq(1)
      expect(json["reports"].first["report_count"]).to eq(3)
      expect(json["reports"].first["event"]["title"]).to eq("Midnight Ride")
    end

    it "counts events, not rows, in the pagination total" do
      add_reports(5)
      add_reports(2, on: create(:event))

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(json["meta"]["total_count"]).to eq(2)
      expect(json["meta"]["total_pages"]).to eq(1)
    end

    it "breaks down which reasons were given" do
      add_reports(2, reason: "gambling")
      add_reports(1, reason: "violence")

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(json["reports"].first["reasons"]).to eq("gambling" => 2, "violence" => 1)
    end

    # The row has to describe the rows the filter selected, or the count and
    # the tally contradict the list they sit in.
    it "counts only what the reason filter selected" do
      add_reports(2, reason: "gambling")
      add_reports(3, reason: "violence")

      get "/api/v1/admin/event_reports?reason=gambling", headers: auth_headers(admin)

      row = json["reports"].first
      expect(row["report_count"]).to eq(2)
      expect(row["reasons"]).to eq("gambling" => 2)
    end

    # The deliberate exception: "is there work left on this event" is a fact
    # about the event, not about the view, and priority follows it — an event
    # with five open reports must not read as quiet because someone filtered
    # to one reason.
    it "still counts every live report in open_count and priority" do
      add_reports(2, reason: "gambling")
      add_reports(3, reason: "violence")

      get "/api/v1/admin/event_reports?reason=gambling", headers: auth_headers(admin)

      row = json["reports"].first
      expect(row["open_count"]).to eq(5)
      expect(row["priority"]).to eq("high")
    end

    it "shows open threads by default, not resolved history" do
      add_reports(1)
      EventReport.last.resolve!(by: admin, status: "dismissed")

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(json["reports"]).to be_empty
    end

    it "shows resolved ones when asked for explicitly" do
      add_reports(1)
      EventReport.last.resolve!(by: admin, status: "dismissed")

      get "/api/v1/admin/event_reports?status=dismissed", headers: auth_headers(admin)

      expect(json["reports"].length).to eq(1)
    end

    # Same reasoning as the support inbox's awaiting_count: it means "how much
    # is waiting on us", not "how many rows are on screen".
    it "reports open_count independently of the active filter" do
      add_reports(1)
      add_reports(1, on: create(:event))

      get "/api/v1/admin/event_reports?reason=gambling", headers: auth_headers(admin)

      expect(json["reports"]).to be_empty
      expect(json["open_count"]).to eq(2)
    end
  end

  describe "priority" do
    it "is normal for a single report" do
      add_reports(1)

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(json["reports"].first["priority"]).to eq("normal")
    end

    it "rises to high, then urgent" do
      add_reports(EventReport::HIGH_THRESHOLD)
      get "/api/v1/admin/event_reports", headers: auth_headers(admin)
      expect(json["reports"].first["priority"]).to eq("high")

      add_reports(EventReport::URGENT_THRESHOLD - EventReport::HIGH_THRESHOLD)
      get "/api/v1/admin/event_reports", headers: auth_headers(admin)
      expect(json["reports"].first["priority"]).to eq("urgent")
    end

    # Priority is the *only* thing volume does.
    it "never suspends or unpublishes on its own" do
      add_reports(EventReport::URGENT_THRESHOLD + 5)

      get "/api/v1/admin/event_reports", headers: auth_headers(admin)

      expect(event.reload.is_published).to be(true)
      expect(event.reload).not_to be_suspended
    end
  end

  describe "resolving" do
    it "closes every live report on the event at once" do
      add_reports(3)

      post "/api/v1/admin/event_reports/events/#{event.id}/resolve",
           params: { status: "dismissed", note: "Charity casino night, legitimate." },
           headers: auth_headers(admin), as: :json

      expect(json["resolved"]).to eq(3)
      expect(event.event_reports.live).to be_empty
    end

    it "records who decided and when" do
      add_reports(1)

      post "/api/v1/admin/event_reports/events/#{event.id}/resolve",
           params: { status: "actioned" }, headers: auth_headers(admin), as: :json

      report = event.event_reports.first.reload
      expect(report.reviewed_by).to eq(admin)
      expect(report.reviewed_at).to be_present
    end

    it "writes an audit row" do
      add_reports(1)

      expect {
        post "/api/v1/admin/event_reports/events/#{event.id}/resolve",
             params: { status: "dismissed" }, headers: auth_headers(admin), as: :json
      }.to change(AdminAction, :count).by(1)

      expect(AdminAction.last.action).to eq("resolve_event_reports")
    end

    it "refuses a status that isn't a real outcome" do
      add_reports(1)

      post "/api/v1/admin/event_reports/events/#{event.id}/resolve",
           params: { status: "open" }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end

    # Taking an event down is its own act, with its own audit entry, so the
    # record shows a person chose it rather than it being implied by closing
    # a ticket.
    it "does not suspend the event as a side effect" do
      add_reports(1)

      post "/api/v1/admin/event_reports/events/#{event.id}/resolve",
           params: { status: "actioned" }, headers: auth_headers(admin), as: :json

      expect(event.reload).not_to be_suspended
    end
  end
end
