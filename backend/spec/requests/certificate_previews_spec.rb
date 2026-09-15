require "rails_helper"

RSpec.describe "Api::V1::CertificatePreviews", type: :request do
  let(:organizer) { create(:user) }
  let(:event) { create(:event, creator: organizer) }
  let(:headers) { auth_headers(organizer) }

  let(:template_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("PK\x03\x04 pretend odt"),
      filename: "template.odt",
      content_type: "application/vnd.oasis.opendocument.text"
    )
  end

  describe "POST /api/v1/events/:event_id/certificate_preview" do
    it "accepts a signed id, creates a pending preview and enqueues the render" do
      expect {
        post "/api/v1/events/#{event.id}/certificate_preview",
             params: { signed_id: template_blob.signed_id }, headers: headers
      }.to have_enqueued_job(RenderCertificatePreviewJob)

      expect(response).to have_http_status(:accepted)
      expect(json["preview"]["status"]).to eq("pending")

      preview = CertificatePreview.sole
      expect(preview.user).to eq(organizer)
      expect(preview.event).to eq(event)
      expect(preview.template_blob_id).to eq(template_blob.id)
    end

    # The bound on this table: re-previewing replaces rather than appends, so
    # clicking Preview repeatedly can't grow the table or orphan rows.
    it "overwrites the existing preview rather than creating a second one" do
      create(:certificate_preview, user: organizer, event: event, status: "ready",
                                   file_url: "https://example.com/old.pdf")

      post "/api/v1/events/#{event.id}/certificate_preview",
           params: { signed_id: template_blob.signed_id }, headers: headers

      expect(CertificatePreview.count).to eq(1)
      preview = CertificatePreview.sole
      expect(preview).to be_pending
      expect(preview.file_url).to be_nil
    end

    # The endpoint takes a signed id precisely so it can never be pointed at
    # an arbitrary address — the renderer runs inside the VPC.
    it "rejects a signed id that isn't ours" do
      post "/api/v1/events/#{event.id}/certificate_preview",
           params: { signed_id: "not-a-real-signed-id" }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(CertificatePreview.count).to eq(0)
    end

    it "rejects a blob that isn't an odt" do
      image = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("\xFF\xD8\xFF"), filename: "photo.jpg", content_type: "image/jpeg"
      )

      post "/api/v1/events/#{event.id}/certificate_preview",
           params: { signed_id: image.signed_id }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "404s for someone who can't manage the event" do
      stranger = create(:user)

      post "/api/v1/events/#{event.id}/certificate_preview",
           params: { signed_id: template_blob.signed_id }, headers: auth_headers(stranger)

      expect(response).to have_http_status(:not_found)
      expect(CertificatePreview.count).to eq(0)
    end

    it "requires authentication" do
      post "/api/v1/events/#{event.id}/certificate_preview",
           params: { signed_id: template_blob.signed_id }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/events/:event_id/certificate_preview" do
    # The normal state for almost every organizer, and the UI polls this — a
    # 404 would make "not requested yet" indistinguishable from an error.
    it "returns null when no preview has been requested" do
      get "/api/v1/events/#{event.id}/certificate_preview", headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["preview"]).to be_nil
    end

    it "returns the finished preview" do
      create(:certificate_preview, :ready, user: organizer, event: event)

      get "/api/v1/events/#{event.id}/certificate_preview", headers: headers

      expect(json["preview"]["status"]).to eq("ready")
      expect(json["preview"]["file_url"]).to be_present
    end

    it "returns a machine-readable error code on failure, never a raw message" do
      create(:certificate_preview, :failed, user: organizer, event: event)

      get "/api/v1/events/#{event.id}/certificate_preview", headers: headers

      expect(json["preview"]["status"]).to eq("failed")
      expect(json["preview"]["error_code"]).to eq("conversion_failed")
    end

    # Two managers of the same event each get their own, so neither sees the
    # other's half-finished render appear under them.
    it "does not return another organizer's preview for the same event" do
      other = create(:user)
      create(:certificate_preview, :ready, user: other, event: event)

      get "/api/v1/events/#{event.id}/certificate_preview", headers: headers

      expect(json["preview"]).to be_nil
    end
  end
end
