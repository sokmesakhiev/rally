require "rails_helper"

RSpec.describe CertificatePreview do
  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:event) }

  describe "one per organizer per event" do
    # The model validation and the database index have to agree. A model that
    # permits what the database rejects turns a clear validation error into a
    # RecordNotUnique surfacing as a 500 — the same pairing as Registration's
    # kept-index and Conversation's one-live-thread rule.
    it "rejects a second preview for the same user and event" do
      first = create(:certificate_preview)
      duplicate = build(:certificate_preview, user: first.user, event: first.event)

      expect(duplicate).not_to be_valid
      expect { duplicate.save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows the same organizer a preview on a different event" do
      first = create(:certificate_preview)

      expect(build(:certificate_preview, user: first.user)).to be_valid
    end

    it "allows a different organizer a preview on the same event" do
      first = create(:certificate_preview)

      expect(build(:certificate_preview, event: first.event)).to be_valid
    end
  end

  describe "status" do
    it "accepts the three known statuses" do
      CertificatePreview::STATUSES.each do |status|
        expect(build(:certificate_preview, status: status)).to be_valid
      end
    end

    it "rejects anything else at both layers" do
      preview = build(:certificate_preview, status: "rendering")

      expect(preview).not_to be_valid
      expect { preview.save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /certificate_previews_status_check/)
    end
  end

  describe ".stale" do
    it "matches only rows untouched for longer than the retention window" do
      stale = create(:certificate_preview, :stale)
      create(:certificate_preview)

      expect(described_class.stale).to contain_exactly(stale)
    end

    # Keyed on updated_at, not created_at, so re-previewing an old row keeps
    # it alive rather than having it swept out from under the organizer who
    # just asked for it.
    it "spares a row that was re-rendered recently even if created long ago" do
      preview = create(:certificate_preview, :stale)
      preview.touch

      expect(described_class.stale).to be_empty
    end
  end
end
