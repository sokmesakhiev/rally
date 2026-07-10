class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAILER_FROM_EMAIL", "Rally <no-reply@example.com>")
  layout "mailer"

  # Frontend base URL for links inside emails (password reset, verification,
  # event pages) — the frontend and backend are deployed separately, so we
  # can't rely on Rails route helpers for these.
  def frontend_url(path)
    "#{ENV.fetch('FRONTEND_URL', 'http://localhost:5173').chomp('/')}#{path}"
  end
end
