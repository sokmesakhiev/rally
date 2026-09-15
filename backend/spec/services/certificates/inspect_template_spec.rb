require "rails_helper"

RSpec.describe Certificates::InspectTemplate do
  around do |example|
    Dir.mktmpdir("inspect-template-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_odt(name, content_xml:, styles_xml: "<styles/>")
    path = File.join(@dir, name)
    Zip::OutputStream.open(path) do |out|
      out.put_next_entry("mimetype")
      out.write("application/vnd.oasis.opendocument.text")
      out.put_next_entry("content.xml")
      out.write(content_xml)
      out.put_next_entry("styles.xml")
      out.write(styles_xml)
    end
    path
  end

  def all_tokens_xml
    "<text:p>{{participant_name}} {{event_title}} {{event_date}} {{event_location}}</text:p>"
  end

  it "reports every token present when each is one continuous run" do
    report = described_class.call(build_odt("ok.odt", content_xml: all_tokens_xml))

    expect(report.valid_odt).to be true
    expect(report.present).to match_array(described_class::TOKENS)
    expect(report.split).to be_empty
    expect(report.missing).to be_empty
    expect(report).to be_usable
  end

  # The failure this class exists for. A word processor splits a run the
  # moment part of a token picks up different formatting, and MergeOdt's
  # literal gsub then never matches it.
  it "reports a token split across spans as split, not present and not missing" do
    xml = <<~XML
      <text:p>
        <text:span>{{participant_</text:span><text:span text:style-name="T1">name}}</text:span>
        {{event_title}} {{event_date}} {{event_location}}
      </text:p>
    XML

    report = described_class.call(build_odt("split.odt", content_xml: xml))

    expect(report.split).to eq(%w[participant_name])
    expect(report.present).to match_array(%w[event_title event_date event_location])
    expect(report.missing).to be_empty
    expect(report).not_to be_usable
  end

  # Distinct from split, and deliberately not a failure — an organizer may
  # simply not want the location printed.
  it "reports an absent token as missing and still considers the template usable" do
    xml = "<text:p>{{participant_name}} {{event_title}} {{event_date}} at Phnom Penh</text:p>"

    report = described_class.call(build_odt("missing.odt", content_xml: xml))

    expect(report.missing).to eq(%w[event_location])
    expect(report.split).to be_empty
    expect(report).to be_usable
  end

  it "finds tokens in styles.xml too, since headers and footers live there" do
    report = described_class.call(
      build_odt("styles.odt",
                content_xml: "<text:p>{{participant_name}}</text:p>",
                styles_xml: "<footer>{{event_title}} {{event_date}} {{event_location}}</footer>")
    )

    expect(report.present).to match_array(described_class::TOKENS)
  end

  # UploadsController's content-type check trusts the browser. This is what
  # actually establishes the file is an ODT.
  it "reports an unreadable archive rather than raising" do
    path = File.join(@dir, "fake.odt")
    File.binwrite(path, "\xFF\xD8\xFF\xE0JFIF not a zip at all")

    report = described_class.call(path)

    expect(report.valid_odt).to be false
    expect(report.error).to eq("not_an_odt")
    expect(report).not_to be_usable
  end

  it "accepts anything responding to #path, so an uploaded file works directly" do
    path = build_odt("uploaded.odt", content_xml: all_tokens_xml)
    uploaded = Struct.new(:path).new(path)

    expect(described_class.call(uploaded).present).to match_array(described_class::TOKENS)
  end

  # If someone adds a placeholder to RenderPdf and forgets it here, organizers
  # would be told their template is complete while a documented token silently
  # never gets filled in.
  it "inspects exactly the tokens RenderPdf substitutes" do
    event = build(:event, title: "T", start_at: Time.current, location: "L")
    user = build(:user)
    registration = build(:registration, event: event, user: user)

    rendered_keys = Certificates::RenderPdf.new(registration).send(:placeholder_values).keys

    expect(described_class::TOKENS).to match_array(rendered_keys)
  end
end
