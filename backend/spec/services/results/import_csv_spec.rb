require "rails_helper"

RSpec.describe Results::ImportCsv do
  let(:organizer) { create(:user) }
  let(:event)     { create(:event, creator: organizer) }

  describe ".call" do
    it "is tolerant of header case/whitespace and reports the correct row numbers" do
      alice = create(:user, email: "alice@example.com")
      create(:registration, event: event, user: alice)

      csv = <<~CSV
        Email , Finish_Time
        alice@example.com,10:00
        missing@example.com,10:00
      CSV

      summary = described_class.call(event: event, csv_text: csv)

      expect(summary[:updated]).to eq(1)
      expect(summary[:errors]).to eq([
        { row: 3, email: "missing@example.com", reason: "no registration found for this email on this event" }
      ])
    end

    it "treats email matching case-insensitively" do
      alice = create(:user, email: "alice@example.com")
      reg = create(:registration, event: event, user: alice)

      csv = "email,finish_time\nALICE@EXAMPLE.COM,10:00\n"

      summary = described_class.call(event: event, csv_text: csv)

      expect(summary[:updated]).to eq(1)
      expect(reg.reload.result.finish_time_seconds).to eq(600)
    end

    it "flags a missing email column value" do
      csv = "email,finish_time\n,10:00\n"

      summary = described_class.call(event: event, csv_text: csv)

      expect(summary[:updated]).to eq(0)
      expect(summary[:errors].first[:reason]).to eq("missing email")
    end

    it "does not raise on a completely empty CSV (header only)" do
      summary = described_class.call(event: event, csv_text: "email,finish_time\n")

      expect(summary).to eq(updated: 0, errors: [])
    end
  end
end
