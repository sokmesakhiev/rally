# A generated, one-per-registration certificate of participation. Created
# only once Certificates::RenderPdf has actually succeeded — there's no
# "pending"/"failed" status column, because GenerateCertificatesJob's own
# eligibility check (a confirmed, paid registration with no Certificate row
# yet, on an ended event with a template) is naturally idempotent: a
# registration without a Certificate just gets tried again on the next sweep,
# whether this is its first attempt or a retry after a prior failure.
class Certificate < ApplicationRecord
  belongs_to :registration

  # A plain URL column (like Event#banner_url/#logo_url/
  # #certificate_template_url), populated by
  # ActiveStorage::Blob.create_and_upload! + a url_for-equivalent — not
  # has_one_attached. This is the only file-storage path the rest of the
  # app actually exercises; has_one_attached's ActiveStorage::Attachment
  # join row wasn't reliably visible to a fresh query within the same
  # DatabaseCleaner `:transaction`-strategy test (see
  # Certificates::RenderPdf's class comment for the full story).
  validates :registration_id, uniqueness: true

  def file_present?
    file_url.present?
  end
end
