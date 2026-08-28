require "rails_helper"

RSpec.describe Organization, type: :model do
  subject(:organization) { build(:organization) }

  # ── Associations ─────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:owner).class_name("User") }
    it { is_expected.to have_many(:organization_memberships).dependent(:destroy) }
    it { is_expected.to have_many(:events).dependent(:restrict_with_error) }

    # An organization presents events other people have paid to register for,
    # so removing it can't quietly take them down.
    it "refuses to be destroyed while it still presents events" do
      organization = create(:organization)
      create(:event, :for_organization, presented_by: organization)

      expect(organization.destroy).to be(false)
      expect(organization.errors[:base]).to be_present
      expect(Organization.exists?(organization.id)).to be(true)
    end
  end

  # ── Validations ──────────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(120) }

    it "rejects a contact_email that isn't an email" do
      organization.contact_email = "not-an-email"
      expect(organization).not_to be_valid
      expect(organization.errors[:contact_email]).to be_present
    end

    it "accepts a blank contact_email" do
      organization.contact_email = nil
      expect(organization).to be_valid
    end

    it "rejects a website without a scheme" do
      organization.website = "example.com"
      expect(organization).not_to be_valid
      expect(organization.errors[:website]).to be_present
    end

    it "accepts http and https URLs for every link field" do
      organization.assign_attributes(
        website: "https://example.com",
        facebook_url: "http://facebook.com/x",
        instagram_url: "https://instagram.com/x",
        telegram_url: "https://t.me/x"
      )
      expect(organization).to be_valid
    end

    # These values are rendered straight into href attributes on the public
    # organizer page, so a URL that merely *starts* valid isn't good enough —
    # URL_FORMAT is anchored at both ends specifically to stop these.
    describe "link fields reject smuggled content" do
      injections = {
        "a newline followed by a javascript: URL" => "https://example.com\njavascript:alert(1)",
        "a newline followed by anything at all"   => "https://example.com\nhttp://evil.test",
        "trailing junk"                           => "https://example.com junk",
        "leading junk"                            => "junk https://example.com",
        "a javascript: scheme"                    => "javascript:alert(1)",
        "a data: URI"                             => "data:text/html,<script>alert(1)</script>"
      }

      injections.each do |description, value|
        it "rejects #{description}" do
          %i[website facebook_url instagram_url telegram_url].each do |field|
            org = build(:organization, field => value)

            expect(org).not_to be_valid, "expected #{field} to reject #{value.inspect}"
            expect(org.errors[field]).to be_present
          end
        end
      end
    end
  end

  # ── Slug ─────────────────────────────────────────────────────────────────────
  describe "slug generation" do
    it "derives a slug from the name" do
      org = create(:organization, name: "Phnom Penh Runners")
      expect(org.slug).to eq("phnom-penh-runners")
    end

    it "appends a numeric suffix on collision rather than failing" do
      create(:organization, name: "Angkor Wat Half")
      second = create(:organization, name: "Angkor Wat Half")

      expect(second.slug).to eq("angkor-wat-half-2")
    end

    it "keeps incrementing past a second collision" do
      3.times { create(:organization, name: "Mekong Ride") }

      expect(Organization.where(name: "Mekong Ride").map(&:slug))
        .to contain_exactly("mekong-ride", "mekong-ride-2", "mekong-ride-3")
    end

    # The app is bilingual by design, so a Khmer-only name is a normal case.
    # #parameterize strips non-ASCII entirely, which would otherwise collide
    # every such organizer onto the same empty slug.
    it "falls back to a generated slug when the name has no ASCII to slugify" do
      org = create(:organization, name: "ក្លឹបរត់ភ្នំពេញ")

      expect(org.slug).to match(/\Aorganizer-[0-9a-f]{8}\z/)
      expect(org).to be_valid
    end

    it "gives two non-ASCII-named organizations distinct slugs" do
      first = create(:organization, name: "ក្លឹបរត់ភ្នំពេញ")
      second = create(:organization, name: "ក្លឹបរត់ភ្នំពេញ")

      expect(first.slug).not_to eq(second.slug)
    end

    it "truncates a long name to the slug length limit" do
      # Within the 120-char name limit, but well past the 60-char slug limit.
      org = create(:organization, name: "A" * 100)

      expect(org.slug.length).to eq(Organization::MAX_SLUG_LENGTH)
    end

    it "honours an explicitly provided slug" do
      org = create(:organization, name: "Anything", slug: "custom-slug")
      expect(org.slug).to eq("custom-slug")
    end

    it "rejects a slug with invalid characters" do
      org = build(:organization, slug: "Not A Slug!")
      expect(org).not_to be_valid
      expect(org.errors[:slug]).to be_present
    end

    it "enforces uniqueness" do
      create(:organization, slug: "taken")
      duplicate = build(:organization, slug: "taken")

      expect(duplicate).not_to be_valid
    end
  end

  describe "slug immutability" do
    # A public URL that changes silently breaks every link the organizer has
    # already shared, so renaming updates :name and never :slug.
    it "refuses to change the slug after creation" do
      org = create(:organization, name: "Original Name")

      org.slug = "something-else"

      expect(org).not_to be_valid
      expect(org.errors[:slug]).to be_present
    end

    it "allows renaming without touching the slug" do
      org = create(:organization, name: "Original Name")

      org.name = "Completely Different Name"

      expect(org).to be_valid
      expect { org.save! }.not_to change { org.reload.slug }
    end
  end

  describe "#to_param" do
    it "returns the slug so routes are slug-addressed" do
      org = create(:organization, name: "Siem Reap Striders")
      expect(org.to_param).to eq("siem-reap-striders")
    end
  end

  # ── Roles ────────────────────────────────────────────────────────────────────
  describe "roles" do
    let(:owner) { create(:user) }
    let(:admin) { create(:user) }
    let(:plain_member) { create(:user) }
    let(:stranger) { create(:user) }
    let(:organization) { create(:organization, owner: owner) }

    before do
      create(:organization_membership, organization: organization, user: admin, role: "admin")
      create(:organization_membership, organization: organization, user: plain_member, role: "member")
    end

    describe "#owner?" do
      it "is true only for the owner" do
        expect(organization.owner?(owner)).to be(true)
        expect(organization.owner?(admin)).to be(false)
        expect(organization.owner?(nil)).to be(false)
      end
    end

    describe "#administered_by?" do
      it "includes the owner and admins, but not plain members or strangers" do
        expect(organization.administered_by?(owner)).to be(true)
        expect(organization.administered_by?(admin)).to be(true)
        expect(organization.administered_by?(plain_member)).to be(false)
        expect(organization.administered_by?(stranger)).to be(false)
        expect(organization.administered_by?(nil)).to be(false)
      end
    end

    describe "#member?" do
      it "includes everyone with any relationship, including plain members" do
        expect(organization.member?(owner)).to be(true)
        expect(organization.member?(admin)).to be(true)
        expect(organization.member?(plain_member)).to be(true)
        expect(organization.member?(stranger)).to be(false)
      end
    end

    describe "#team" do
      it "returns the owner alongside every membership, without duplicates" do
        expect(organization.team).to contain_exactly(owner, admin, plain_member)
      end
    end

    describe "#admins" do
      it "returns admin members only" do
        expect(organization.admins).to contain_exactly(admin)
      end
    end
  end

  # ── Moderation ───────────────────────────────────────────────────────────────
  # Suspension derives downward — see Ticket J (#339). The cascade to events
  # is specced there, once events.organization_id exists.
  describe "#suspended?" do
    let(:owner) { create(:user) }
    let(:organization) { create(:organization, owner: owner) }

    it "is false for an ordinary organization with an active owner" do
      expect(organization.suspended?).to be(false)
    end

    it "is true when the organization itself was suspended" do
      organization.suspend!(reason: "Reported as fraudulent")

      expect(organization.suspended?).to be(true)
      expect(organization.suspension_reason).to eq("Reported as fraudulent")
    end

    it "is true when the OWNER is suspended, without touching this row" do
      owner.suspend!(reason: "Fraud")

      expect(organization.reload.suspended?).to be(true)
      expect(organization.suspended_at).to be_nil
    end

    it "distinguishes a direct suspension from an inherited one" do
      owner.suspend!

      expect(organization.reload.suspended?).to be(true)
      expect(organization.suspended_directly?).to be(false)

      organization.suspend!(reason: "Its own problem")
      expect(organization.suspended_directly?).to be(true)
    end

    it "blanks a whitespace-only reason, mirroring User#suspend!" do
      organization.suspend!(reason: "   ")
      expect(organization.suspension_reason).to be_nil
    end

    # The point of deriving rather than copying: unsuspending the owner
    # restores the organization with no reconciliation step.
    it "recovers automatically when the owner is unsuspended" do
      owner.suspend!
      expect(organization.reload.suspended?).to be(true)

      owner.unsuspend!
      expect(organization.reload.suspended?).to be(false)
    end

    it "stays suspended after the owner is unsuspended if suspended directly too" do
      owner.suspend!
      organization.suspend!(reason: "Its own problem")

      owner.unsuspend!

      expect(organization.reload.suspended?).to be(true)
    end
  end

  describe "#unsuspend!" do
    it "clears both suspension columns" do
      org = create(:organization, :suspended)

      org.unsuspend!

      expect(org.suspended_at).to be_nil
      expect(org.suspension_reason).to be_nil
    end
  end

  # ── Publish-readiness ────────────────────────────────────────────────────────
  # Ticket E (#334). A public event must be presented by an organization an
  # audience can actually evaluate.
  describe "identity completeness" do
    def complete_attributes
      {
        name: "Phnom Penh Runners",
        logo_url: "https://example.com/logo.png",
        description: "A running club.",
        contact_email: "hello@example.com"
      }
    end

    it "is complete when name, logo, description and a contact are present" do
      organization = build(:organization, **complete_attributes)

      expect(organization.identity_complete?).to be(true)
      expect(organization.missing_identity_fields).to be_empty
    end

    it "accepts a phone as the contact instead of an email" do
      organization = build(:organization, **complete_attributes.merge(contact_email: nil, contact_phone: "012345678"))

      expect(organization.identity_complete?).to be(true)
    end

    it "names each missing field" do
      organization = build(:organization, name: "Bare", logo_url: nil, description: nil,
                                          contact_email: nil, contact_phone: nil)

      expect(organization.missing_identity_fields)
        .to contain_exactly(:logo_url, :description, :contact)
    end

    %i[logo_url description].each do |field|
      it "is incomplete without #{field}" do
        organization = build(:organization, **complete_attributes.merge(field => nil))

        expect(organization.identity_complete?).to be(false)
        expect(organization.missing_identity_fields).to include(field)
      end
    end

    it "is incomplete with neither contact method" do
      organization = build(:organization, **complete_attributes.merge(contact_email: nil, contact_phone: nil))

      expect(organization.missing_identity_fields).to include(:contact)
    end

    # The freshly-backfilled state every existing organization is in — which
    # is exactly why enforcement is off by default until #336 ships the UI.
    it "treats a backfilled name-only organization as incomplete" do
      organization = build(:organization, name: "From Backfill", logo_url: nil,
                                          description: nil, contact_email: nil, contact_phone: nil)

      expect(organization.identity_complete?).to be(false)
    end
  end

  describe ".identity_required_for_publishing?" do
    # Same ENV swap/restore shape as spec/services/aba_payway/client_spec.rb —
    # climate_control isn't a dependency here.
    def with_env(value)
      original = ENV.to_hash
      ENV["REQUIRE_ORGANIZATION_IDENTITY"] = value
      yield
    ensure
      ENV.replace(original)
    end

    it "is off unless REQUIRE_ORGANIZATION_IDENTITY is set" do
      expect(described_class.identity_required_for_publishing?).to be(false)
    end

    it "is on when the env var is truthy" do
      with_env("true") { expect(described_class.identity_required_for_publishing?).to be(true) }
    end

    it "treats an explicit false the same as unset" do
      with_env("false") { expect(described_class.identity_required_for_publishing?).to be(false) }
    end

    it "treats an empty value the same as unset" do
      with_env("") { expect(described_class.identity_required_for_publishing?).to be(false) }
    end
  end

  # ── PayWay ───────────────────────────────────────────────────────────────────
  # Moved here from Profile in Ticket B (#331). Registration payments settle
  # into the account of whoever presents the event.
  describe "PayWay credentials" do
    let(:organization) { create(:organization) }

    it "is unconfigured by default" do
      expect(organization.payway_configured?).to be(false)
      expect(organization.payway_refund_configured?).to be(false)
      expect(organization.payway_api_key_masked).to be_nil
    end

    it "is configured once both merchant id and api key are set" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")

      expect(organization.payway_configured?).to be(true)
    end

    it "encrypts the api key at rest" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")

      raw = Organization.connection.select_value(
        "SELECT payway_api_key FROM organizations WHERE id = #{Organization.connection.quote(organization.id)}"
      )

      expect(raw).not_to include("secret_abcdef1234")
      expect(organization.reload.payway_api_key).to eq("secret_abcdef1234")
    end

    it "masks all but the last four characters of the key" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")

      expect(organization.payway_api_key_masked).to eq("••••••••1234")
    end

    # Half-configured would silently fall back to Rally's platform credentials
    # instead of failing loudly.
    it "rejects a merchant id without an api key" do
      organization.payway_merchant_id = "m_123"

      expect(organization).not_to be_valid
      expect(organization.errors[:payway_api_key]).to be_present
    end

    it "rejects an api key without a merchant id" do
      organization.payway_api_key = "secret_abcdef1234"

      expect(organization).not_to be_valid
      expect(organization.errors[:payway_merchant_id]).to be_present
    end

    it "treats blank strings as a disconnect rather than a half-configured state" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")

      organization.update!(payway_merchant_id: "", payway_api_key: "")

      expect(organization.reload.payway_merchant_id).to be_nil
      expect(organization.payway_api_key).to be_nil
      expect(organization.payway_configured?).to be(false)
    end

    # The RSA key is only needed for gateway refunds — an organization can
    # take payments perfectly well without it.
    it "needs the RSA public key only for refund capability" do
      organization.update!(payway_merchant_id: "m_123", payway_api_key: "secret_abcdef1234")
      expect(organization.payway_configured?).to be(true)
      expect(organization.payway_refund_configured?).to be(false)

      organization.update!(payway_rsa_public_key: "-----BEGIN PUBLIC KEY-----")
      expect(organization.payway_refund_configured?).to be(true)
    end
  end

  # ── Verification ─────────────────────────────────────────────────────────────
  describe "verification" do
    it "is unverified by default" do
      expect(create(:organization).verified?).to be(false)
    end

    it "round-trips through verify!/unverify!" do
      org = create(:organization)

      org.verify!
      expect(org.verified?).to be(true)

      org.unverify!
      expect(org.verified?).to be(false)
    end
  end

  # ── Scopes ───────────────────────────────────────────────────────────────────
  describe "scopes" do
    let!(:ordinary)  { create(:organization) }
    let!(:suspended) { create(:organization, :suspended) }
    let!(:discarded) { create(:organization, :discarded) }
    let!(:owned_by_suspended_user) { create(:organization, owner: create(:user, :suspended)) }

    describe ".kept" do
      it "excludes discarded organizations" do
        expect(Organization.kept).to include(ordinary, suspended)
        expect(Organization.kept).not_to include(discarded)
      end
    end

    describe ".active" do
      it "excludes discarded, suspended, and suspended-owner organizations" do
        expect(Organization.active).to include(ordinary)
        expect(Organization.active).not_to include(suspended, discarded, owned_by_suspended_user)
      end
    end

    describe ".verified" do
      it "returns only verified organizations" do
        verified = create(:organization, :verified)

        expect(Organization.verified).to include(verified)
        expect(Organization.verified).not_to include(ordinary)
      end
    end
  end

  # ── Soft-delete ──────────────────────────────────────────────────────────────
  describe "#discard!" do
    it "sets deleted_at without destroying the row" do
      org = create(:organization)

      expect { org.discard! }.not_to change(Organization, :count)
      expect(org.discarded?).to be(true)
    end
  end
end
