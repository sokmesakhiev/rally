require "rails_helper"

RSpec.describe Certificates::MergeOdt do
  around do |example|
    Dir.mktmpdir("merge-odt-spec-") do |dir|
      @dir = dir
      example.run
    end
  end

  def build_odt(path, content_xml:, styles_xml: "<styles/>", extra_entries: {})
    Zip::OutputStream.open(path) do |out|
      out.put_next_entry("content.xml")
      out.write(content_xml)

      out.put_next_entry("styles.xml")
      out.write(styles_xml)

      extra_entries.each do |name, body|
        out.put_next_entry(name)
        out.write(body)
      end
    end
  end

  def read_entries(path)
    entries = {}
    Zip::File.open(path) { |zip| zip.each { |entry| entries[entry.name] = entry.get_input_stream.read } }
    entries
  end

  it "substitutes tokens in content.xml and styles.xml only, leaving other entries untouched" do
    source = File.join(@dir, "source.odt")
    destination = File.join(@dir, "merged.odt")

    build_odt(
      source,
      content_xml: "<text>Hello {{participant_name}}, congrats on {{event_title}}!</text>",
      styles_xml: "<footer>{{event_date}}</footer>",
      extra_entries: { "mimetype" => "application/vnd.oasis.opendocument.text" }
    )

    Certificates::MergeOdt.call(
      source_path: source,
      destination_path: destination,
      replacements: {
        "participant_name" => "Jane Doe",
        "event_title" => "Rally 10K",
        "event_date" => "August 1, 2026"
      }
    )

    entries = read_entries(destination)

    expect(entries["content.xml"]).to eq("<text>Hello Jane Doe, congrats on Rally 10K!</text>")
    expect(entries["styles.xml"]).to eq("<footer>August 1, 2026</footer>")
    expect(entries["mimetype"]).to eq("application/vnd.oasis.opendocument.text")
  end

  it "XML-escapes replacement values so special characters can't corrupt the document" do
    source = File.join(@dir, "source.odt")
    destination = File.join(@dir, "merged.odt")

    build_odt(source, content_xml: "<text>{{event_title}}</text>")

    Certificates::MergeOdt.call(
      source_path: source,
      destination_path: destination,
      replacements: { "event_title" => "Cats & Dogs <5K>" }
    )

    expect(read_entries(destination)["content.xml"]).to eq("<text>Cats &amp; Dogs &lt;5K&gt;</text>")
  end

  it "leaves an unrecognized placeholder token untouched" do
    source = File.join(@dir, "source.odt")
    destination = File.join(@dir, "merged.odt")

    build_odt(source, content_xml: "<text>{{unknown_token}}</text>")

    Certificates::MergeOdt.call(
      source_path: source,
      destination_path: destination,
      replacements: { "event_title" => "Rally 10K" }
    )

    expect(read_entries(destination)["content.xml"]).to eq("<text>{{unknown_token}}</text>")
  end

  it "returns the destination path" do
    source = File.join(@dir, "source.odt")
    destination = File.join(@dir, "merged.odt")
    build_odt(source, content_xml: "<text>{{event_title}}</text>")

    result = Certificates::MergeOdt.call(
      source_path: source,
      destination_path: destination,
      replacements: { "event_title" => "Rally 10K" }
    )

    expect(result).to eq(destination)
  end
end
