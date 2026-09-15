module Api
  module V1
    class UploadsController < BaseController
      before_action :authenticate_user!

      ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze
      MAX_FILE_SIZE = 5.megabytes

      # Certificate-of-participation templates (see Certificates::RenderPdf)
      # are OpenDocument Text files, not images — different allowed content
      # type and a bigger size ceiling, since a template can embed a
      # print-resolution background image.
      CERTIFICATE_TEMPLATE_CONTENT_TYPE = "application/vnd.oasis.opendocument.text"
      CERTIFICATE_TEMPLATE_MAX_FILE_SIZE = 10.megabytes

      UPLOAD_TYPES = %w[banner logo avatar certificate_template].freeze

      # POST /api/v1/uploads
      # Params: file (multipart), type ("banner"|"logo"|"avatar"|"certificate_template")
      def create
        file = params[:file]
        upload_type = params[:type].presence_in(UPLOAD_TYPES) || "banner"

        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          render json: { error: "No file provided" }, status: :bad_request
          return
        end

        unless allowed_content_types(upload_type).include?(file.content_type)
          render json: { error: content_type_error_message(upload_type) }, status: :unprocessable_entity
          return
        end

        max_size = max_file_size(upload_type)
        if file.size > max_size
          render json: { error: "File too large (max #{max_size / 1.megabyte} MB)" }, status: :unprocessable_entity
          return
        end

        # Inspect certificate templates *before* storing, so a file that isn't
        # really an ODT never becomes a blob. The content-type check above only
        # tests what the browser claimed; this one opens the archive.
        report = nil
        if upload_type == "certificate_template"
          report = Certificates::InspectTemplate.call(file)

          unless report.valid_odt
            render json: {
              error: "That file could not be read as an OpenDocument Text (.odt) document.",
              code: report.error
            }, status: :unprocessable_entity
            return
          end
        end

        blob = ActiveStorage::Blob.create_and_upload!(
          io: file,
          filename: "#{current_user.id}/#{upload_type}-#{Time.current.to_i}#{File.extname(file.original_filename)}",
          content_type: file.content_type
        )

        body = { url: url_for(blob) }
        # signed_id lets the certificate-preview endpoint name this blob
        # directly instead of being handed a URL to go and fetch. An endpoint
        # that takes a URL and downloads it is an SSRF hole; a signed id can
        # only ever resolve to a blob this application stored.
        body[:signed_id] = blob.signed_id if upload_type == "certificate_template"
        # A split token is reported, not rejected. It is a strong signal but a
        # heuristic one, and an organizer blocked by a false positive would
        # have no way around it — whereas a warning they can act on costs
        # nothing if it is wrong. An unreadable archive, above, is certain and
        # is refused.
        body[:template_check] = report.as_json if report

        render json: body, status: :created
      end

      private

      def allowed_content_types(upload_type)
        upload_type == "certificate_template" ? [ CERTIFICATE_TEMPLATE_CONTENT_TYPE ] : ALLOWED_CONTENT_TYPES
      end

      def max_file_size(upload_type)
        upload_type == "certificate_template" ? CERTIFICATE_TEMPLATE_MAX_FILE_SIZE : MAX_FILE_SIZE
      end

      def content_type_error_message(upload_type)
        if upload_type == "certificate_template"
          "File type not allowed. Use an OpenDocument Text (.odt) file."
        else
          "File type not allowed. Use JPEG, PNG, WebP, or GIF."
        end
      end
    end
  end
end
