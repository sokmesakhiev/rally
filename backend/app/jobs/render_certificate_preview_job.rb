# frozen_string_literal: true

# Renders one organizer's certificate preview — see Certificates::RenderPreview.
#
# A job rather than inline work in the controller, for two measured reasons.
# A conversion takes roughly 0.25-1.2s on four cores and peaks around 180 MB
# resident; the production web task is 0.5 vCPU / 1 GB with Rails already in
# it, so a handful of organizers clicking Preview at once would contend for
# three Puma threads and risk an OOM kill. It is also exactly the work the
# Solid Queue worker split (infrastructure/ecs.tf) exists to keep off the web
# task in the first place.
#
# Unlike RenderCertificateJob there is no outer rescue here: RenderPreview
# already converts every expected failure into a `failed` row with an
# error_code, because a preview that silently never arrives is worse for the
# organizer than one that says why. Anything that escapes it is a genuine bug
# and should reach Sentry and Solid Queue's retry, not be swallowed.
class RenderCertificatePreviewJob < ApplicationJob
  queue_as :default

  # Discarded rather than retried: if the row is gone, the organizer
  # re-previewed (which replaces the row) or the event was deleted. Retrying
  # would just fail again on the next attempt.
  discard_on ActiveRecord::RecordNotFound

  def perform(preview_id)
    preview = CertificatePreview.find(preview_id)
    Certificates::RenderPreview.call(preview)
  end
end
