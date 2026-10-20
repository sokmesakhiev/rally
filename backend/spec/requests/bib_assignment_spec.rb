require "rails_helper"

# Automatic bib assignment.
#
# The examples that matter are the ones about *not* assigning. Handing out
# numbers is easy; the value of this feature is entirely in which numbers it
# refuses to touch, because every one of those refusals maps to a race-day
# failure that is discovered at the finish line rather than in a test.
RSpec.describe "Bib assignment", type: :request do
  let(:organizer) { create(:user) }
  let(:stranger)  { create(:user) }
  let(:event)     { create(:event, creator: organizer) }

  def preview(as: organizer)
    get "/api/v1/events/#{event.id}/bib_assignment", headers: auth_headers(as), as: :json
  end

  def assign(as: organizer)
    post "/api/v1/events/#{event.id}/bib_assignment", headers: auth_headers(as), as: :json
  end

  def group(label)
    json["groups"].find { |g| g["label"] == label }
  end

  describe "a single-distance event" do
    before { event.update!(bib_start: 1000, bib_prefix: "", bib_padding: 0) }

    it "numbers everyone in registration order" do
      first  = create(:registration, event: event, created_at: 3.days.ago)
      second = create(:registration, event: event, created_at: 2.days.ago)
      third  = create(:registration, event: event, created_at: 1.day.ago)

      assign

      expect(response).to have_http_status(:ok)
      expect(json["assigned_count"]).to eq(3)
      expect([ first, second, third ].map { |r| r.reload.bib_number }).to eq(%w[1000 1001 1002])
    end

    it "pads to the configured width, keeping the leading zeros" do
      # Real bibs are printed with them, which is why bib_number is a string.
      event.update!(bib_padding: 5)
      registration = create(:registration, event: event)

      assign

      expect(registration.reload.bib_number).to eq("01000")
    end

    it "applies the prefix" do
      event.update!(bib_prefix: "RUN-")
      registration = create(:registration, event: event)

      assign

      expect(registration.reload.bib_number).to eq("RUN-1000")
    end
  end

  describe "what it refuses to touch" do
    before { event.update!(bib_start: 1000) }

    it "leaves an existing number alone and works around it" do
      # The organizer hand-picked 1000 for somebody. Assignment must honour
      # that rather than renumber them, and must not hand 1000 to anyone else.
      vip   = create(:registration, event: event, created_at: 3.days.ago, bib_number: "1000")
      other = create(:registration, event: event, created_at: 2.days.ago)

      assign

      expect(vip.reload.bib_number).to eq("1000")
      expect(other.reload.bib_number).to eq("1001")
      expect(json["assigned_count"]).to eq(1)
    end

    it "never reissues a withdrawn entry's number" do
      # The one that would be expensive. `registrations`' unique index on
      # (event_id, bib_number) is deliberately not scoped to kept rows,
      # because a withdrawn runner's result and certificate still point at
      # their number. Reusing it would attach one person's finishing time to
      # another's certificate.
      withdrawn = create(:registration, event: event, created_at: 3.days.ago, bib_number: "1000")
      withdrawn.discard!
      replacement = create(:registration, event: event, created_at: 2.days.ago)

      assign

      expect(replacement.reload.bib_number).to eq("1001")
      expect(withdrawn.reload.bib_number).to eq("1000")
    end

    it "is safe to run twice" do
      # The expected workflow: assign when entries close, assign again after
      # the late additions. A second run must be a no-op for everyone already
      # numbered.
      first = create(:registration, event: event, created_at: 3.days.ago)
      assign
      numbered = first.reload.bib_number

      late = create(:registration, event: event, created_at: 1.hour.ago)
      assign

      expect(first.reload.bib_number).to eq(numbered)
      expect(late.reload.bib_number).to eq("1001")
      expect(json["assigned_count"]).to eq(1)
    end

    it "skips a group with no start number instead of inventing one" do
      # No default of 1, deliberately: an organizer who meant 1000–1999 and
      # forgot to say so would otherwise get 1–143 with nothing to tell them.
      event.update!(bib_start: nil)
      registration = create(:registration, event: event)

      assign

      expect(registration.reload.bib_number).to be_nil
      expect(json["assigned_count"]).to eq(0)
      expect(group("No event type")["configured"]).to be(false)
      expect(group("No event type")["skipped_count"]).to eq(1)
    end

    it "does not number a withdrawn registration" do
      withdrawn = create(:registration, event: event)
      withdrawn.discard!

      assign

      expect(withdrawn.reload.bib_number).to be_nil
    end
  end

  describe "a multi-distance event" do
    let!(:five_k) { event.event_types.create!(name: "5K", position: 0, bib_start: 1000) }
    let!(:ten_k)  { event.event_types.create!(name: "10K", position: 1, bib_start: 2000) }

    def enter(type, created_at: 1.day.ago)
      registration = create(:registration, event: event, created_at: created_at)
      registration.registration_event_types.create!(event_type: type)
      registration
    end

    it "numbers each distance from its own range" do
      runner_5k = enter(five_k)
      runner_10k = enter(ten_k)

      assign

      expect(runner_5k.reload.bib_number).to eq("1000")
      expect(runner_10k.reload.bib_number).to eq("2000")
    end

    it "uses the lowest-positioned type when somebody enters two" do
      # One person wears one bib. Position is the order the organizer arranged
      # the distances in, so this is their decision rather than an arbitrary
      # one — and it is stable across re-runs.
      both = create(:registration, event: event)
      both.registration_event_types.create!(event_type: ten_k)
      both.registration_event_types.create!(event_type: five_k)

      assign

      expect(both.reload.bib_number).to eq("1000")
    end

    it "numbers the configured distances even when another has no range" do
      ten_k.update!(bib_start: nil)
      runner_5k = enter(five_k)
      runner_10k = enter(ten_k)

      assign

      expect(runner_5k.reload.bib_number).to eq("1000")
      expect(runner_10k.reload.bib_number).to be_nil
      expect(group("5K")["configured"]).to be(true)
      expect(group("10K")["configured"]).to be(false)
    end

    it "warns when one range runs into the next" do
      # Never an error — the unique index guarantees no two runners share a
      # number, so this is legible-numbering advice, not correctness. But it
      # is the kind of thing discovered at the printer otherwise.
      five_k.update!(bib_start: 1000)
      ten_k.update!(bib_start: 1002)
      3.times { |i| enter(five_k, created_at: (3 - i).days.ago) }

      assign

      expect(group("5K")["warning"]).to include("10K")
      expect(response).to have_http_status(:ok)
    end
  end

  describe "the preview" do
    before { event.update!(bib_start: 1000) }

    it "reports what a run would do and changes nothing" do
      registration = create(:registration, event: event)

      preview

      expect(response).to have_http_status(:ok)
      expect(json["assigned_count"]).to eq(1)
      expect(group("No event type")["first_number"]).to eq("1000")
      expect(group("No event type")["last_number"]).to eq("1000")
      # The point of the dry run. Bibs get printed.
      expect(registration.reload.bib_number).to be_nil
    end
  end

  describe "authorization" do
    before { event.update!(bib_start: 1000) }

    it "refuses a stranger" do
      create(:registration, event: event)

      assign(as: stranger)

      expect(response).to have_http_status(:not_found).or have_http_status(:forbidden)
      expect(Registration.where.not(bib_number: nil).count).to eq(0)
    end
  end

  describe "the activity log" do
    before { event.update!(bib_start: 1000) }

    it "records the run even when it assigned nothing" do
      # "Somebody pressed this and nothing changed" is exactly the entry you
      # want when an organizer reports that assignment is not working.
      expect { assign }.to change { EventActivity.where(action: "assign_bib_numbers").count }.by(1)

      entry = EventActivity.where(action: "assign_bib_numbers").last
      expect(entry.actor).to eq(organizer)
      expect(entry.metadata["assigned"]).to eq(0)
    end
  end
end
