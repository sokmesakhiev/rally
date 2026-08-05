require "rails_helper"

RSpec.describe RecaptchaVerifier do
  # The real network call (post_siteverify) is stubbed throughout — these
  # specs are about the pass/fail decision logic (success flag, action match,
  # score threshold), not Google's HTTP response format.
  def stub_configured(secret: "test-secret-key")
    allow(RecaptchaVerifier).to receive(:secret_key).and_return(secret)
  end

  def stub_siteverify(response)
    allow(RecaptchaVerifier).to receive(:post_siteverify).and_return(response)
  end

  describe ".configured?" do
    it "is false when RECAPTCHA_SECRET_KEY isn't set" do
      allow(RecaptchaVerifier).to receive(:secret_key).and_return(nil)
      expect(described_class).not_to be_configured
    end

    it "is true once a secret key is present" do
      stub_configured
      expect(described_class).to be_configured
    end
  end

  describe ".verify" do
    context "when unconfigured (no RECAPTCHA_SECRET_KEY)" do
      it "always succeeds without making any request, regardless of the token" do
        allow(RecaptchaVerifier).to receive(:secret_key).and_return(nil)
        expect(RecaptchaVerifier).not_to receive(:post_siteverify)

        result = described_class.verify(nil, action: "signup")

        expect(result).to be_success
        expect(result.reason).to eq("unconfigured")
      end
    end

    context "when configured" do
      before { stub_configured }

      it "fails without making a request when the token is blank" do
        expect(RecaptchaVerifier).not_to receive(:post_siteverify)

        result = described_class.verify(nil, action: "signup")

        expect(result).not_to be_success
        expect(result.reason).to eq("missing_token")
      end

      it "fails when Google reports success: false" do
        stub_siteverify({ "success" => false, "error-codes" => [ "invalid-input-response" ] })

        result = described_class.verify("bad-token", action: "signup")

        expect(result).not_to be_success
        expect(result.reason).to eq("invalid-input-response")
      end

      it "fails when the action doesn't match what was expected" do
        stub_siteverify({ "success" => true, "action" => "login", "score" => 0.9 })

        result = described_class.verify("tok", action: "signup")

        expect(result).not_to be_success
        expect(result.reason).to eq("action_mismatch")
      end

      it "fails when the score is below the threshold" do
        stub_siteverify({ "success" => true, "action" => "signup", "score" => 0.1 })

        result = described_class.verify("tok", action: "signup")

        expect(result).not_to be_success
        expect(result.reason).to eq("low_score")
        expect(result.score).to eq(0.1)
      end

      it "succeeds when the action matches and the score clears the threshold" do
        stub_siteverify({ "success" => true, "action" => "signup", "score" => 0.9 })

        result = described_class.verify("tok", action: "signup")

        expect(result).to be_success
        expect(result.score).to eq(0.9)
        expect(result.reason).to be_nil
      end

      it "fails closed when the verification request itself errors" do
        allow(RecaptchaVerifier).to receive(:post_siteverify)
          .and_raise(RecaptchaVerifier::RequestError, "reCAPTCHA verification request failed: timeout")

        result = described_class.verify("tok", action: "signup")

        expect(result).not_to be_success
        expect(result.reason).to include("timeout")
      end
    end
  end
end
