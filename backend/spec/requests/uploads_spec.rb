require "rails_helper"

RSpec.describe "Uploads API", type: :request do
  let(:user) { create(:user) }

  # A real (tiny) PNG, so content_type sniffing and Active Storage have
  # something genuine to work with rather than arbitrary bytes.
  def png_upload(filename: "banner.png", content_type: "image/png")
    Rack::Test::UploadedFile.new(
      StringIO.new(Base64.decode64(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8AAAwAB/AF+9dQZAAAAAElFTkSuQmCC"
      )),
      content_type,
      original_filename: filename
    )
  end

  describe "POST /api/v1/uploads" do
    it "stores the file and returns a URL" do
      expect {
        post "/api/v1/uploads",
             params: { file: png_upload, type: "banner" },
             headers: auth_headers(user)
      }.to change(ActiveStorage::Blob, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json["url"]).to be_present
    end

    it "namespaces the stored filename under the uploading user's id" do
      # Keeps one user's uploads from colliding with another's, and makes
      # ownership visible in the bucket. The controller builds the filename
      # as "#{user.id}/#{type}-...", but ActiveStorage::Filename#sanitized
      # (Rails' blob filename sanitizer) replaces "/" with "-" since a blob
      # filename is a single path segment, not a path — so the stored
      # filename uses "-" as the separator, not "/".
      post "/api/v1/uploads",
           params: { file: png_upload, type: "logo" },
           headers: auth_headers(user)

      expect(ActiveStorage::Blob.last.filename.to_s).to start_with("#{user.id}-logo-")
    end

    it "defaults an unrecognized type to banner rather than rejecting it" do
      post "/api/v1/uploads",
           params: { file: png_upload, type: "wallpaper" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(ActiveStorage::Blob.last.filename.to_s).to include("-banner-")
    end

    it "accepts each allowed image content type" do
      Api::V1::UploadsController::ALLOWED_CONTENT_TYPES.each do |content_type|
        post "/api/v1/uploads",
             params: { file: png_upload(content_type: content_type), type: "avatar" },
             headers: auth_headers(user)

        expect(response).to have_http_status(:created), "expected #{content_type} to be accepted"
      end
    end

    it "returns 400 when no file is attached" do
      post "/api/v1/uploads", params: { type: "banner" }, headers: auth_headers(user)

      expect(response).to have_http_status(:bad_request)
      expect(json["error"]).to be_present
    end

    it "returns 400 when `file` is a bare string rather than an upload" do
      # Guards the `is_a?(ActionDispatch::Http::UploadedFile)` check — without
      # it, a JSON string would reach Active Storage and blow up as a 500.
      post "/api/v1/uploads",
           params: { file: "not-a-file", type: "banner" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a disallowed content type with 422" do
      expect {
        post "/api/v1/uploads",
             params: { file: png_upload(filename: "resume.pdf", content_type: "application/pdf"), type: "banner" },
             headers: auth_headers(user)
      }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to match(/JPEG|PNG|WebP|GIF/i)
    end

    it "rejects a file over the size limit with 422" do
      oversized = Rack::Test::UploadedFile.new(
        StringIO.new("x" * (Api::V1::UploadsController::MAX_FILE_SIZE + 1)),
        "image/png",
        original_filename: "huge.png"
      )

      expect {
        post "/api/v1/uploads", params: { file: oversized, type: "banner" }, headers: auth_headers(user)
      }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to match(/too large/i)
    end

    it "checks content type before size, so a huge non-image reports the type error" do
      # Ordering matters for a sensible message: telling someone their PDF is
      # too large is less useful than telling them PDFs aren't accepted.
      huge_pdf = Rack::Test::UploadedFile.new(
        StringIO.new("x" * (Api::V1::UploadsController::MAX_FILE_SIZE + 1)),
        "application/pdf",
        original_filename: "huge.pdf"
      )

      post "/api/v1/uploads", params: { file: huge_pdf, type: "banner" }, headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json["error"]).to match(/JPEG|PNG|WebP|GIF/i)
    end

    it "requires authentication" do
      expect {
        post "/api/v1/uploads", params: { file: png_upload, type: "banner" }
      }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
