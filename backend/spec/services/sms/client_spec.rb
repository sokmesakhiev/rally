require "rails_helper"

RSpec.describe Sms::Client do
  describe ".deliver" do
    it "uses the null adapter by default and reports success" do
      result = described_class.deliver(to: "012345678", body: "hello")

      expect(result).to be_success
      expect(result.provider).to eq("null")
    end

    it "logs what would have been sent instead of actually sending it" do
      expect(Rails.logger).to receive(:info).with(a_string_including("012345678").and(a_string_including("hello")))

      described_class.deliver(to: "012345678", body: "hello")
    end

    it "respects SMS_PROVIDER=null explicitly" do
      with_env("SMS_PROVIDER" => "null") do
        result = described_class.deliver(to: "012345678", body: "hello")
        expect(result).to be_success
      end
    end
  end

  describe ".adapter_for" do
    it "raises a clear error for an unregistered provider name" do
      expect { described_class.adapter_for("twilio") }
        .to raise_error(ArgumentError, /Unknown SMS_PROVIDER "twilio"/)
    end

    it "falls back to the null adapter when unset" do
      expect(described_class.adapter_for(nil)).to be_a(Sms::Adapters::NullAdapter)
    end
  end

  # Small local helper — no existing spec/support helper stubs ENV, and this
  # is the only spec file that needs it so far.
  def with_env(vars)
    originals = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| ENV[k] = v }
  end
end
