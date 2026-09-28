# Certificates, templates, and bib numbers

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Certificates: templates, checking and preview

An organizer uploads a `.odt`; `Certificates::MergeOdt` substitutes four tokens into it (`participant_name`, `event_title`, `event_date`, `event_location` — `Certificates::RenderPdf#placeholder_values` is the only source of that list) and `Certificates::OdtToPdf` shells out to LibreOffice. `docs/templates/rally-certificate-modern.odt` is a working example, built by `scripts/build-certificate-template.py` — the script is the reviewable source, since an ODT is a zip of XML and therefore opaque in a diff.

Organizers get **two different kinds of feedback, because they answer different questions at wildly different cost**:

- **The token check runs inline at upload** (`Certificates::InspectTemplate`, returned as `template_check` from `POST /uploads`). It answers "will the placeholders be filled in?" in milliseconds with no LibreOffice. It exists for the one failure MergeOdt warns about and cannot defend against: substitution is a literal gsub over raw XML, so a token split across two `<text:span>`s never matches and the braces print on every certificate. Detection is cheap — **a split token is absent from the raw XML but present once tags are stripped**, because stripping tags is exactly what rejoins the runs the word processor separated. A split token is *reported, not rejected* (a heuristic false positive would leave the organizer with no way around it); an unreadable archive **is** rejected, before the blob is written, which is also the first thing in this codebase that actually verifies an upload is an ODT rather than trusting the browser's content-type.
- **The rendered preview is a job** (`RenderCertificatePreviewJob` → `Certificates::RenderPreview`), polled via `POST`/`GET /events/:event_id/certificate_preview`. It is the only thing that catches layout problems — a long name or event title wrapping and pushing content onto a second page. Measured cost is why it can't be synchronous: **~0.25–1.2s and ~180 MB peak RSS per conversion**, against a web task with 3 Puma threads on 0.5 vCPU / 1 GB. It is also precisely the work the Solid Queue worker split exists to keep off the web task.

Four decisions worth knowing:

- **The preview endpoint takes an Active Storage `signed_id`, never a URL.** An endpoint that accepts a URL and fetches it is an SSRF hole, and the renderer runs inside the VPC. `UploadsController` returns `signed_id` alongside `url` for this reason; `find_signed` rejects a tampered one without any validation code. It also means no outbound HTTP at all — unlike `RenderPdf`, which legitimately downloads `event.certificate_template_url` because by then the template is saved.
- **Preview runs on an uploaded-but-unsaved template.** That is the point — looking before committing — so it cannot read `event.certificate_template_url`.
- **One row per organizer per event**, by unique index. That is the entire storage-growth story: re-previewing overwrites, so the table is bounded by (organizers × events) rather than by clicks. Per *organizer*, not per event, so two managers of the same event don't overwrite each other's half-finished renders.
- **`Certificates::SweepPreviews` (hourly) is not optional.** The row keeps only the newest URL, so every re-render orphans the previous PDF in S3 — unreferenced, invisible, and billed for.

**Blob URLs built outside a request must use `Storage::BlobUrl`, never `action_mailer.default_url_options`.** A controller's `url_for(blob)` takes the host from the request — the API domain — and is correct. A job has no request, and the obvious fallback is the mailer host, which is deliberately `FRONTEND_URL`. But `/rails/active_storage/blobs/redirect/...` is served by *Rails*, on the API domain: pointed at the frontend it becomes a CloudFront path that doesn't exist. Both `RenderPdf` and `RenderPreview` shipped with that bug (the second copied it from the first), storing 404 URLs for every certificate and preview. It survived because in development and test the mailer host *is* the Rails host, so only production was wrong. `Storage::BlobUrl` reads `BACKEND_URL` — the same value the ABA webhook callbacks already use — and falls back to the mailer options only when it's unset. **Certificate rows written before the fix still hold the bad host.**

`Certificates::RenderPdf::ConversionError` is deliberately **the same class** as `OdtToPdf::ConversionError`, not a sibling. `RenderCertificateJob` rescues it to log-and-swallow a bad template; when the soffice call moved into `OdtToPdf`, a separate class would have quietly stopped that rescue catching conversion failures, turning a logged warning into a crashed job.

### Bib numbers, and the certificate job that never ran

Both landed together as Phase 0 of `docs/partner-api-design.md` (the Partner
API), but neither is about the API — they're gaps the product already had.

- **`GenerateCertificatesJob` was dead code until 2026-09-16.** Its own header
  said it "runs on a schedule (see `config/recurring.yml`)"; it was not in
  `recurring.yml` and nothing called it, so **no certificate had ever been
  generated in production**. Comments that describe intent are not evidence
  that the wiring exists.
- **It could not simply be switched on.** `eligible_registrations` filtered on
  status, payment, template and end date — but not on `registrations.deleted_at`,
  `events.deleted_at` or `events.suspended_at`, while every other read of
  registrations in this codebase goes through `.kept`. Its first run would have
  issued certificates to people who withdrew and to events an admin had taken
  down, each one a PDF in S3 that the participant can see. The bug survived
  review *because* the job was dead: the existing spec passed throughout, since
  it only covered the filters that were there. Suspension is treated as
  deferral rather than denial — unsuspending makes those registrations eligible
  on the next run.
- **`MAX_PER_RUN` (200) is what makes a no-cutoff backfill safe.** Every
  finished event qualifies however old, so the first runs face the whole
  history; each render is ~180 MB RSS and 0.25–1.2 s of LibreOffice on the
  worker. Hourly + capped drains the backlog over hours instead of starving
  the queue of the registration and payment jobs people are waiting on.
  Ordering is oldest-finished-first so a capped run is predictable.
- **`registrations.bib_number` is a string, not an integer** — real bibs are
  `"A1042"`, `"10K-233"`, `"0007"` with the leading zeros printed on them, and
  nothing sorts or sums this column. The unique index is partial and per-event
  (`WHERE bib_number IS NOT NULL`), the same shape as the `(event_id, user_id)`
  index. `normalizes` turns `""` and whitespace into NULL, without which the
  second participant to have their bib cleared would collide with the first.
- **Unlike the `user_id` index, the bib index is deliberately *not* scoped to
  kept rows.** A withdrawn runner's number must not be silently reissued while
  their result and certificate still reference it; freeing a number is an
  explicit edit.
- **`Results::ImportCsv` matches on bib first, then email**, and reports a
  bib/email pair that names two different people as an error rather than
  picking a side. Email was the only key before, which was always wrong for the
  file organizers actually have: chip-timing systems export bib and time and no
  timing exporter emits entrant email addresses. The export CSV leads with
  `Bib` so export → fill in times → re-import is a round trip with no VLOOKUP.
  Its lookups are now `.kept`-scoped, which they weren't.
