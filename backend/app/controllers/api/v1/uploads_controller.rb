module Api
  module V1
    class UploadsController < BaseController
      before_action :authenticate_user!

      ALLOWED_CONTENT_TYPES = %w[image/jpeg image/png image/webp image/gif].freeze
      MAX_FILE_SIZE = 5.megabytes

      # POST /api/v1/uploads
      # Params: file (multipart), type ("banner"|"logo"|"avatar")
      def create
        file = params[:file]
        upload_type = params[:type].presence_in(%w[banner logo avatar]) || "banner"

        unless file.is_a?(ActionDispatch::Http::UploadedFile)
          render json: { error: "No file provided" }, status: :bad_request
          return
        end

        unless ALLOWED_CONTENT_TYPES.include?(file.content_type)
          render json: { error: "File type not allowed. Use JPEG, PNG, WebP, or GIF." }, status: :unprocessable_entity
          return
        end

        if file.size > MAX_FILE_SIZE
          render json: { error: "File too large (max 5 MB)" }, status: :unprocessable_entity
          return
        end

        blob = ActiveStorage::Blob.create_and_upload!(
          io: file,
          filename: "#{current_user.id}/#{upload_type}-#{Time.current.to_i}#{File.extname(file.original_filename)}",
          content_type: file.content_type
        )

        render json: { url: url_for(blob) }, status: :created
      end
    end
  end
end
