# frozen_string_literal: true

module Certificates
  # Reads an organizer's .odt certificate template and reports what
  # Certificates::MergeOdt will actually be able to substitute, *before* the
  # template is saved and long before a real certificate is generated.
  #
  # This exists because of the one failure mode MergeOdt's own comment warns
  # about and cannot defend against: substitution is a literal gsub over the
  # raw XML, so a token split across two <text:span> elements never matches
  # and the braces print on the finished certificate. Word processors split
  # runs silently — autocorrect capitalising a letter mid-token is enough —
  # and the organizer has no way to see it. Today they find out when a
  # participant downloads a certificate reading "Dear {{participant_name}}".
  #
  # Detecting it is cheap and needs no LibreOffice: a split token is absent
  # from the raw XML but present once the tags are stripped, because stripping
  # tags is exactly what rejoins the runs the word processor separated.
  #
  #   raw XML:  <text:span>{{participant_</text:span><text:span>name}}</text:span>
  #   stripped: {{participant_name}}        <- found here, not above => split
  #
  # Also doubles as real format validation. UploadsController's content-type
  # check trusts whatever the browser claimed the file was; this opens the
  # archive, so a .odt that is secretly a JPEG (or empty, or corrupt) is
  # rejected here rather than blowing up inside a background job days later
  # when the event ends.
  class InspectTemplate
    # Must stay in step with Certificates::RenderPdf#placeholder_values.
    # A spec pins the two together — adding a token there and forgetting it
    # here would tell organizers their template is fine while a placeholder
    # they were told about silently never gets filled in.
    TOKENS = %w[participant_name event_title event_date event_location].freeze

    # Same two entries MergeOdt substitutes into. styles.xml matters because
    # headers, footers and the master page live there, and organizers do put
    # the event title in a header.
    INSPECTED_ENTRIES = %w[content.xml styles.xml].freeze

    # A guard against a decompression bomb: a few KB of zip can expand to
    # gigabytes, and this runs inline in a request. Real content.xml files for
    # a certificate are single-digit KB; 16 MB is far past any legitimate one
    # while staying cheap to refuse.
    MAX_ENTRY_BYTES = 16 * 1024 * 1024

    Report = Struct.new(:valid_odt, :present, :split, :missing, :error, keyword_init: true) do
      # Whether the template can be used at all. A *missing* token is not a
      # failure — an organizer may legitimately not want the location on the
      # certificate. A *split* token is, because it prints literal braces.
      def usable?
        valid_odt && split.empty?
      end

      def as_json(*)
        {
          valid_odt: valid_odt,
          usable: usable?,
          present: present,
          split: split,
          missing: missing,
          error: error
        }.compact
      end
    end

    def self.call(source)
      new(source).call
    end

    # `source` is anything Zip::File.open accepts a path for, or an object
    # responding to #path (ActionDispatch::Http::UploadedFile, Tempfile).
    def initialize(source)
      @path = source.respond_to?(:path) ? source.path : source.to_s
    end

    def call
      xml = read_inspected_entries
      stripped = strip_tags(xml)

      present, split, missing = [], [], []
      TOKENS.each do |token|
        literal = "{{#{token}}}"
        if xml.include?(literal)
          present << token
        elsif stripped.include?(literal)
          split << token
        else
          missing << token
        end
      end

      Report.new(valid_odt: true, present: present, split: split, missing: missing)
    rescue Zip::Error, IOError, Errno::ENOENT => e
      # Not a readable zip at all. The organizer gets a clear "this isn't an
      # .odt" instead of a successful upload that fails silently later.
      Report.new(valid_odt: false, present: [], split: [], missing: TOKENS.dup,
                 error: "not_an_odt")
        .tap { Rails.logger.info("[certificate template] unreadable upload: #{e.class}: #{e.message}") }
    rescue EntryTooLarge
      Report.new(valid_odt: false, present: [], split: [], missing: TOKENS.dup,
                 error: "template_too_complex")
    end

    private

    class EntryTooLarge < StandardError; end

    def read_inspected_entries
      Zip::File.open(@path) do |zip|
        INSPECTED_ENTRIES.filter_map do |name|
          entry = zip.find_entry(name)
          next unless entry

          raise EntryTooLarge if entry.size > MAX_ENTRY_BYTES

          entry.get_input_stream.read(MAX_ENTRY_BYTES).to_s
        end.join("\n")
      end
    end

    # Removes every tag, which rejoins text runs the word processor split.
    # Deliberately a blunt regex rather than an XML parse: the question is
    # only "what characters would a reader see as continuous text", and
    # parsing would cost more and answer the same thing. Note this is used
    # *only* for diagnosis — MergeOdt still substitutes against the raw XML,
    # so a token found only here genuinely will not be replaced.
    def strip_tags(xml)
      xml.gsub(/<[^>]*>/, "")
    end
  end
end
