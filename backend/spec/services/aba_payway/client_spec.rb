require "rails_helper"

RSpec.describe AbaPayway::Client, ".for_event" do
  around do |example|
    original = ENV.to_hash
    ENV["ABA_PAYWAY_MERCHANT_ID"] = "platform_merchant"
    ENV["ABA_PAYWAY_API_KEY"] = "platform_key"
    example.run
    ENV.replace(original)
  end

  it "uses the platform credentials when the organizer hasn't connected PayWay" do
    event = create(:event)

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@merchant_id)).to eq("platform_merchant")
    expect(client.instance_variable_get(:@api_key)).to eq("platform_key")
  end

  it "uses the presenting organization's credentials once it has connected PayWay" do
    event = create(:event)
    event.organization.update!(payway_merchant_id: "organizer_merchant", payway_api_key: "organizer_key")

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@merchant_id)).to eq("organizer_merchant")
    expect(client.instance_variable_get(:@api_key)).to eq("organizer_key")
  end

  it "passes the organization's RSA public key through when set" do
    event = create(:event)
    event.organization.update!(
      payway_merchant_id: "organizer_merchant",
      payway_api_key: "organizer_key",
      payway_rsa_public_key: "-----BEGIN PUBLIC KEY-----"
    )

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@rsa_public_key)).to eq("-----BEGIN PUBLIC KEY-----")
  end

  # organization-identity-tickets.md's Ticket B (#331): the money follows the
  # organization that presents the event, not whichever colleague created it.
  # Getting this backwards would settle a club's registration income into an
  # individual's personal merchant account.
  it "follows the organization, not the event's creator" do
    club = create(:organization)
    club.update!(payway_merchant_id: "club_merchant", payway_api_key: "club_key")
    colleague = create(:user)
    event = create(:event, :for_organization, creator: colleague, presented_by: club)

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@merchant_id)).to eq("club_merchant")
  end

  it "ignores credentials on an organization that does not present the event" do
    unrelated = create(:organization)
    unrelated.update!(payway_merchant_id: "unrelated_merchant", payway_api_key: "unrelated_key")
    event = create(:event)

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@merchant_id)).to eq("platform_merchant")
  end

  # Half-configured can't happen through the model's both-or-neither
  # validation, but a direct DB write could produce it — falling back to the
  # platform is the safe outcome, versus presenting a merchant_id with no key.
  it "falls back to the platform when only a merchant id is set" do
    event = create(:event)
    event.organization.update_columns(payway_merchant_id: "half_configured")

    client = described_class.for_event(event)

    expect(client.instance_variable_get(:@merchant_id)).to eq("platform_merchant")
  end
end

RSpec.describe AbaPayway::Client, ".config" do
  it "reads merchant_id/api_key from ENV and base_url from config/payway.yml for the current environment" do
    original = ENV.to_hash
    ENV["ABA_PAYWAY_MERCHANT_ID"] = "yml_merchant"
    ENV["ABA_PAYWAY_API_KEY"] = "yml_key"

    config = described_class.config

    expect(config.merchant_id).to eq("yml_merchant")
    expect(config.api_key).to eq("yml_key")
    expect(config.base_url).to eq("https://checkout-sandbox.payway.com.kh")
  ensure
    ENV.replace(original)
  end

  it "lets an explicit ABA_PAYWAY_BASE_URL override the environment's default" do
    original = ENV.to_hash
    ENV["ABA_PAYWAY_BASE_URL"] = "https://staging.payway.example"

    expect(described_class.config.base_url).to eq("https://staging.payway.example")
  ensure
    ENV.replace(original)
  end
end
