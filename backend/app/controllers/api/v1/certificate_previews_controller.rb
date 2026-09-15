module Api
  module V1
    # Lets an organizer see a rendered sample of their certificate template
    # before saving it, and before any participant receives a real one.
    #
    # Singular by design — no `:id` in either route. A preview belongs to
    # (this organizer, this event) and there is exactly one, so "which
    # preview" is never the caller's to choose and there is nothing to
    # authorize per record. Same reasoning as the participant side of support
    # chat. The uniqueness is enforced by an index, not just by convention.
    class CertificatePreviewsController < BaseController
      before_action :authenticate_user!

      # POST /api/v1/events/:event_id/certificate_preview
      # Params: signed_id (Active Storage signed id of the uploaded .odt)
      #
      # Returns 202: rendering runs in a job (see
      # RenderCertificatePreviewJob for the measurements behind that), so the
      # client polls #show.
      def create
        event = find_authorized_event!(params[:event_id], :update_event)

        blob = resolve_template_blob
        return if performed?

        preview = CertificatePreview.find_or_initialize_by(user: current_user, event: event)
        preview.assign_attributes(
          status: "pending", template_blob_id: blob.id, file_url: nil, error_code: nil
        )
        preview.save!

        RenderCertificatePreviewJob.perform_later(preview.id)

        render json: preview_json(preview), status: :accepted
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      # GET /api/v1/events/:event_id/certificate_preview
      # Returns null rather than 404 when none has been requested — that is
      # the normal state for most organizers, and the UI polls this.
      def show
        event = find_authorized_event!(params[:event_id], :update_event)
        preview = CertificatePreview.find_by(user: current_user, event: event)

        render json: { preview: preview && preview_json(preview)[:preview] }
      rescue ActiveRecord::RecordNotFound
        render json: { error: "Event not found" }, status: :not_found
      end

      private

      # The client hands us a signed id, never a URL. An endpoint that
      # accepted a URL and fetched it would be a server-side request forgery
      # hole — the renderer runs inside the VPC and could be pointed at
      # internal addresses. A signed id can only ever resolve to a blob this
      # application already stored, and `find_signed` rejects a tampered one
      # without us writing any validation.
      def resolve_template_blob
        signed_id = params[:signed_id].to_s
        blob = ActiveStorage::Blob.find_signed(signed_id) if signed_id.present?

        if blob.nil?
          render json: { error: "Upload the template again before previewing." },
                 status: :unprocessable_entity
          return nil
        end

        # Belt and braces: the signed id proves provenance, not content type.
        # Rendering a JPEG would fail in the job anyway, but failing here is
        # immediate and says something useful.
        unless blob.content_type == UploadsController::CERTIFICATE_TEMPLATE_CONTENT_TYPE
          render json: { error: "That file is not an OpenDocument Text (.odt) document." },
                 status: :unprocessable_entity
          return nil
        end

        blob
      end

      def preview_json(preview)
        {
          preview: {
            status: preview.status,
            file_url: preview.file_url,
            error_code: preview.error_code,
            updated_at: preview.updated_at
          }
        }
      end
    end
  end
end
