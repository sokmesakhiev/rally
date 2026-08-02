class AddFileUrlToCertificates < ActiveRecord::Migration[8.1]
  def change
    # Storing the rendered PDF as a plain URL column, not via
    # has_one_attached — matches the existing banner_url/logo_url/
    # certificate_template_url convention (standalone
    # ActiveStorage::Blob.create_and_upload! + url_for), which is the only
    # file-storage path this codebase actually exercises in tests. A
    # has_one_attached association's join row (ActiveStorage::Attachment)
    # wasn't reliably visible to a fresh query within the same
    # DatabaseCleaner `:transaction`-strategy test — see
    # Certificates::RenderPdf's class comment.
    add_column :certificates, :file_url, :string
  end
end
