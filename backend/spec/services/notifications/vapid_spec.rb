require "rails_helper"

RSpec.describe Notifications::Vapid do
  def with_env(vars)
    original = ENV.to_hash
    vars.each { |k, v| v.nil? ? ENV.delete(k.to_s) : ENV[k.to_s] = v }
    yield
  ensure
    ENV.replace(original)
  end

  describe "#configured?" do
    it "is false with no keypair — the default in development, test and CI" do
      with_env(VAPID_PUBLIC_KEY: nil, VAPID_PRIVATE_KEY: nil) do
        expect(described_class).not_to be_configured
      end
    end

    # A half-configured keypair would otherwise fail at send time, once per
    # notification, inside a background job.
    it "is false with only the public half" do
      with_env(VAPID_PUBLIC_KEY: "pub", VAPID_PRIVATE_KEY: nil) do
        expect(described_class).not_to be_configured
      end
    end

    it "is false with only the private half" do
      with_env(VAPID_PUBLIC_KEY: nil, VAPID_PRIVATE_KEY: "priv") do
        expect(described_class).not_to be_configured
      end
    end

    it "is true with both halves and a usable subject" do
      with_env(VAPID_PUBLIC_KEY: "pub", VAPID_PRIVATE_KEY: "priv",
        VAPID_SUBJECT: "mailto:admin@rails-dev.com") do
        expect(described_class).to be_configured
      end
    end

    # Push services reject a malformed `sub` claim, so a bad one means every
    # notification fails in the least visible place possible. Better to be
    # cleanly off and say why.
    it "is false when the subject isn't a mailto: or https: URL" do
      with_env(VAPID_PUBLIC_KEY: "pub", VAPID_PRIVATE_KEY: "priv", VAPID_SUBJECT: "admin") do
        expect(described_class).not_to be_configured
      end
    end

    it "accepts an https subject" do
      with_env(VAPID_PUBLIC_KEY: "pub", VAPID_PRIVATE_KEY: "priv",
        VAPID_SUBJECT: "https://rally.example/contact") do
        expect(described_class).to be_configured
      end
    end
  end

  describe "#subject" do
    it "falls back to MAILER_FROM_EMAIL when VAPID_SUBJECT is unset" do
      with_env(VAPID_SUBJECT: nil, MAILER_FROM_EMAIL: "noreply@rails-dev.com") do
        expect(described_class.subject).to eq("mailto:noreply@rails-dev.com")
      end
    end

    # The reason .env.example's MAILER_FROM_EMAIL is unquoted: dotenv strips
    # surrounding quotes, but ECS passes the value through verbatim, so a
    # quoted value in Terraform would land inside the sub claim.
    it "produces an invalid subject if MAILER_FROM_EMAIL arrives quoted" do
      with_env(VAPID_SUBJECT: nil, MAILER_FROM_EMAIL: '"noreply@rails-dev.com"',
        VAPID_PUBLIC_KEY: "pub", VAPID_PRIVATE_KEY: "priv") do
        expect(described_class).not_to be_configured
      end
    end
  end
end
