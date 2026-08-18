require "rails_helper"

RSpec.describe Results::BuildLeaderboard do
  let(:event) { create(:event) }

  def timed_registration(seconds, event: self.event)
    reg = create(:registration, event: event)
    reg.create_result!(finish_time_seconds: seconds)
    reg
  end

  describe ".call" do
    it "returns a single combined group for an event with no types" do
      fast = timed_registration(600)
      slow = timed_registration(1200)

      groups = described_class.call(event: event)

      expect(groups.length).to eq(1)
      expect(groups.first[:event_type_id]).to be_nil
      placements = groups.first[:results]
      expect(placements.map { |r| r[:registration_id] }).to eq([ fast.id, slow.id ])
      expect(placements.map { |r| r[:placement] }).to eq([ 1, 2 ])
    end

    it "ranks ascending by finish time within a group" do
      third = timed_registration(1800)
      first = timed_registration(600)
      second = timed_registration(1200)

      results = described_class.call(event: event).first[:results]

      expect(results.map { |r| r[:registration_id] }).to eq([ first.id, second.id, third.id ])
    end

    it "gives tied finish times the same placement and skips the next number" do
      a = timed_registration(600)
      b = timed_registration(600)
      c = timed_registration(900)

      results = described_class.call(event: event).first[:results]

      expect(results.map { |r| r[:placement] }).to eq([ 1, 1, 3 ])
      expect(results.map { |r| r[:registration_id] }).to contain_exactly(a.id, b.id, c.id)
    end

    it "excludes registrations with no recorded finish time" do
      timed = timed_registration(600)
      create(:registration, event: event) # never given a Result

      results = described_class.call(event: event).first[:results]

      expect(results.map { |r| r[:registration_id] }).to eq([ timed.id ])
    end

    it "excludes cancelled/discarded registrations even if they have a time" do
      kept = timed_registration(600)
      cancelled = timed_registration(700)
      cancelled.discard!

      results = described_class.call(event: event).first[:results]

      expect(results.map { |r| r[:registration_id] }).to eq([ kept.id ])
    end

    it "returns one empty group when nothing has been recorded yet" do
      create(:registration, event: event)

      groups = described_class.call(event: event)

      expect(groups).to eq([ { event_type_id: nil, event_type_name: nil, results: [] } ])
    end

    it "groups by event type, ranking each type's field independently" do
      five_k = event.event_types.create!(name: "5K", position: 0)
      ten_k  = event.event_types.create!(name: "10K", position: 1)

      five_k_winner = timed_registration(600)
      five_k_winner.registration_event_types.create!(event_type: five_k)

      ten_k_winner = timed_registration(1200)
      ten_k_winner.registration_event_types.create!(event_type: ten_k)

      groups = described_class.call(event: event)

      expect(groups.map { |g| g[:event_type_name] }).to eq([ "5K", "10K" ])
      expect(groups[0][:results].map { |r| r[:registration_id] }).to eq([ five_k_winner.id ])
      expect(groups[1][:results].map { |r| r[:registration_id] }).to eq([ ten_k_winner.id ])
    end

    it "exposes a nil display_name when the participant never set one, rather than raising" do
      reg = timed_registration(600)
      reg.user.profile.update!(display_name: nil)

      results = described_class.call(event: event).first[:results]

      expect(results.first[:display_name]).to be_nil
    end
  end
end
