require "rails_helper"

RSpec.describe Result, type: :model do
  subject(:result) { build(:result) }

  describe "associations" do
    it { is_expected.to belong_to(:registration) }
  end

  describe "validations" do
    it "is valid with a registration that doesn't already have a result" do
      expect(result).to be_valid
    end

    it "rejects a second result for the same registration" do
      existing = create(:result)
      dupe = build(:result, registration: existing.registration)

      expect(dupe).not_to be_valid
      expect(dupe.errors[:registration_id]).to be_present
    end

    it "allows a blank finish_time_seconds" do
      expect(build(:result, finish_time_seconds: nil)).to be_valid
    end

    it "rejects a zero or negative finish_time_seconds" do
      expect(build(:result, finish_time_seconds: 0)).not_to be_valid
      expect(build(:result, finish_time_seconds: -5)).not_to be_valid
    end

    it "rejects a non-integer finish_time_seconds" do
      expect(build(:result, finish_time_seconds: 12.5)).not_to be_valid
    end
  end

  describe ".parse_duration_to_seconds" do
    it "parses bare seconds" do
      expect(Result.parse_duration_to_seconds("125")).to eq(125)
    end

    it "parses MM:SS" do
      expect(Result.parse_duration_to_seconds("23:45")).to eq(23 * 60 + 45)
    end

    it "parses H:MM:SS" do
      expect(Result.parse_duration_to_seconds("1:23:45")).to eq(1 * 3600 + 23 * 60 + 45)
    end

    it "parses HH:MM:SS with a two-digit hour" do
      expect(Result.parse_duration_to_seconds("12:23:45")).to eq(12 * 3600 + 23 * 60 + 45)
    end

    it "tolerates surrounding whitespace" do
      expect(Result.parse_duration_to_seconds("  23:45  ")).to eq(23 * 60 + 45)
    end

    it "returns nil for blank input" do
      expect(Result.parse_duration_to_seconds("")).to be_nil
      expect(Result.parse_duration_to_seconds(nil)).to be_nil
    end

    it "returns nil for unparseable input" do
      expect(Result.parse_duration_to_seconds("not a time")).to be_nil
      expect(Result.parse_duration_to_seconds("1:2:3:4")).to be_nil
    end
  end
end
