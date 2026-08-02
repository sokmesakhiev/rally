class CreateCertificatesAndAddTemplateToEvents < ActiveRecord::Migration[8.1]
  def change
    # Same "just a URL string" pattern as banner_url/logo_url — set via the
    # generic /api/v1/uploads endpoint, then PATCHed onto the event. See
    # Api::V1::UploadsController and EventUpdateRequestSchema.
    add_column :events, :certificate_template_url, :string

    create_table :certificates, id: :uuid do |t|
      t.references :registration, null: false, foreign_key: true, type: :uuid, index: { unique: true }

      t.timestamps
    end
  end
end
