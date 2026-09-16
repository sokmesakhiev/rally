require "rails_helper"

# The retention window is a *published* number: the privacy policy states it,
# and Conversations::SweepResolved enforces it. Those live in different
# languages in different subprojects, so nothing but a test keeps them
# together — and the failure mode when they drift is not a stale comment, it's
# a privacy policy that makes a false statement about how long data is kept.
#
# Reading a frontend locale file from a backend spec is a boundary crossing,
# and a deliberate one. The alternative is a comment, and a comment has never
# stopped anyone changing a constant.
RSpec.describe "Support chat retention" do
  LOCALES = {
    "en" => Rails.root.join("../frontend/src/i18n/locales/en.json"),
    "km" => Rails.root.join("../frontend/src/i18n/locales/km.json")
  }.freeze

  # 12.months -> "12". Written from the constant rather than hardcoded, so
  # changing RETENTION_PERIOD makes this spec demand the matching policy edit
  # instead of quietly agreeing with whatever the policy already said.
  let(:months) { (Conversation::RETENTION_PERIOD / 1.month).to_i }

  # Khmer writes numerals in its own digits (០១២៣៤៥៦៧៨៩), and the policy is
  # prose a Khmer speaker reads — forcing Arabic digits into it to make a test
  # pass would be letting the test dictate the translation. So the expected
  # string is transliterated per locale instead.
  KHMER_DIGITS = "០១២៣៤៥៦៧៨៩"

  def expected_number(value, locale)
    return value.to_s unless locale == "km"

    value.to_s.chars.map { |d| KHMER_DIGITS[d.to_i] }.join
  end

  it "is a whole number of months, so the policy can state it plainly" do
    expect(Conversation::RETENTION_PERIOD).to eq(months.months)
  end

  LOCALES.each do |locale, path|
    context "the #{locale} privacy policy" do
      let(:legal) { JSON.parse(File.read(path)).fetch("legal") }

      it "exists where this spec expects it" do
        expect(File.exist?(path)).to be(true),
          "Expected the #{locale} locale at #{path}. If the frontend moved it, update LOCALES " \
          "here rather than deleting this spec — it is the only thing keeping the published " \
          "retention promise and Conversation::RETENTION_PERIOD in agreement."
      end

      it "states the same number of months the sweep actually enforces" do
        expected = expected_number(months, locale)

        expect(legal.fetch("privacyRetentionBody")).to include(expected),
          "The #{locale} retention section doesn't mention #{expected}, but " \
          "Conversation::RETENTION_PERIOD is #{Conversation::RETENTION_PERIOD.inspect}. " \
          "One of the two is now wrong, and the published one is the expensive one."
      end

      it "tells people support chat is collected at all" do
        expect(legal.fetch("privacyCollectBody").downcase).to match(/support|ជំនួយ/)
      end

      it "says what happens to support conversations when an account is deleted" do
        expect(legal.fetch("privacyRetentionBody").downcase).to match(/delete|លុប/)
      end
    end
  end
end
