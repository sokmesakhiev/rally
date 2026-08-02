# frozen_string_literal: true

module Certificates
  # Fills in an organizer's uploaded .odt certificate template with real
  # participant/event data. An .odt is just a zip archive of XML parts
  # (content.xml is the document body, styles.xml covers headers/footers/the
  # master page) — this copies every entry from the source archive to a new
  # one unchanged, except content.xml and styles.xml, where {{token}}
  # placeholders get substituted with real values.
  #
  # IMPORTANT organizer-facing caveat, worth understanding before debugging a
  # "placeholder didn't get replaced" report: this is a *literal* string
  # substitution against the raw XML, not a rich-text-aware one. If a token
  # like {{participant_name}} gets split across more than one <text:span> in
  # the underlying XML — which word processors do silently the moment part of
  # the token has different formatting (e.g. autocorrect capitalizing a
  # letter, a stray bold/italic toggle mid-token, or "smart quotes"
  # autocorrect mangling the braces) — the substitution simply won't match
  # and the literal "{{...}}" text will appear on the printed certificate.
  # Organizers should type each token in one continuous run of plain text,
  # ideally with autocorrect/autoformat turned off while typing it.
  class MergeOdt
    PLACEHOLDER_ENTRIES = %w[content.xml styles.xml].freeze

    def self.call(source_path:, destination_path:, replacements:)
      new(source_path, destination_path, replacements).call
    end

    def initialize(source_path, destination_path, replacements)
      @source_path = source_path
      @destination_path = destination_path
      @replacements = replacements
    end

    def call
      Zip::File.open(@source_path) do |source_zip|
        Zip::OutputStream.open(@destination_path) do |out|
          source_zip.each do |entry|
            next unless entry.file?

            content = entry.get_input_stream.read
            content = substitute(content) if PLACEHOLDER_ENTRIES.include?(entry.name)

            out.put_next_entry(entry.name)
            out.write(content)
          end
        end
      end

      @destination_path
    end

    private

    # XML-escapes each value before substitution — a participant display
    # name containing "&"/"<"/">" would otherwise produce invalid XML and
    # corrupt the whole document.
    def substitute(xml)
      @replacements.reduce(xml) do |str, (token, value)|
        str.gsub("{{#{token}}}", xml_escape(value))
      end
    end

    def xml_escape(value)
      value.to_s
        .gsub("&", "&amp;")
        .gsub("<", "&lt;")
        .gsub(">", "&gt;")
    end
  end
end
