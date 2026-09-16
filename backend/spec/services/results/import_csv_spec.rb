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
        { row: 3, bib: nil, email: "missing@example.com",
          reason: "no registration found for this email on this event" }
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

    # Wording changed when bib became a valid identifier: a blank email is no
    # longer the only way a row can fail to name anybody.
    it "flags a row that identifies nobody" do
      csv = "email,finish_time\n,10:00\n"

      summary = described_class.call(event: event, csv_text: csv)

      expect(summary[:updated]).to eq(0)
      expect(summary[:errors].first[:reason]).to eq("missing bib and email — the row identifies nobody")
    end

    it "does not raise on a completely empty CSV (header only)" do
      summary = described_class.call(event: event, csv_text: "email,finish_time\n")

      expect(summary).to eq(updated: 0, errors: [])
    end
  end

  # ── Matching by bib ─────────────────────────────────────────────────────────
  # The reason bib_number exists (docs/partner-api-design.md, D10). Chip-timing
  # systems export bib and time; none of them export entrant email addresses, so
  # before this an organizer had to VLOOKUP their timing file against their
  # entrant list before Rally would accept it.
  describe "matching by bib" do
    let!(:runner) do
      create(:registration, event: event, bib_number: "A1042",
                            user: create(:user, email: "runner@example.com"))
    end

    it "matches a bib-only file, which is what a timing export actually looks like" do
      summary = described_class.call(event: event, csv_text: "bib,finish_time\nA1042,1:02:33\n")

      expect(summary[:updated]).to eq(1)
      expect(runner.reload.result.finish_time_seconds).to eq(3753)
    end

    # Rally's own participant export uses the longer header.
    it "accepts bib_number as a header too" do
      summary = described_class.call(event: event, csv_text: "bib_number,finish_time\nA1042,10:00\n")

      expect(summary[:updated]).to eq(1)
    end

    it "reports an unknown bib against the bib, not the email column" do
      summary = described_class.call(event: event, csv_text: "bib,finish_time\nZ999,10:00\n")

      expect(summary[:updated]).to eq(0)
      expect(summary[:errors].first).to include(
        bib: "Z999", email: nil, reason: "no registration found for bib Z999 on this event"
      )
    end

    it "still matches on email when the file has no bib column" do
      summary = described_class.call(
        event: event, csv_text: "email,finish_time\nrunner@example.com,10:00\n"
      )

      expect(summary[:updated]).to eq(1)
    end

    # A mismatched pair means the file is wrong somewhere. Picking either side
    # would write a finish time onto the wrong runner — silently.
    it "refuses a row whose bib and email are different people" do
      create(:registration, event: event, bib_number: "B7",
                            user: create(:user, email: "someone.else@example.com"))

      summary = described_class.call(
        event: event, csv_text: "bib,email,finish_time\nA1042,someone.else@example.com,10:00\n"
      )

      expect(summary[:updated]).to eq(0)
      expect(summary[:errors].first[:reason])
        .to eq("bib A1042 and this email belong to different participants")
    end

    it "accepts a row whose bib and email agree" do
      summary = described_class.call(
        event: event, csv_text: "bib,email,finish_time\nA1042,runner@example.com,10:00\n"
      )

      expect(summary[:updated]).to eq(1)
    end

    # Previously unscoped: a withdrawn participant could still be given a
    # finish time, and then a certificate.
    it "ignores a discarded registration's bib" do
      runner.discard!

      summary = described_class.call(event: event, csv_text: "bib,finish_time\nA1042,10:00\n")

      expect(summary[:updated]).to eq(0)
    end
  end
end
