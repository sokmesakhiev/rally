class ImpersonationMailer < ApplicationMailer
  # Tells someone that Rally staff opened their account.
  #
  # **This one carries content, unlike SupportMailer#reply_waiting.** That mail
  # deliberately says nothing beyond "come and look" because support threads
  # hold whatever people paste. Here the content *is* the point: the whole
  # purpose is a record the person keeps outside Rally, in a place we can't
  # later edit. An email that said only "check your notifications" would be a
  # transparency measure that depends on them signing in.
  #
  # It names Rally and the stated reason, and deliberately **not the individual
  # admin**. Staff identity is in `admin_actions` for internal accountability;
  # putting an employee's name in front of a frustrated organizer invites the
  # wrong kind of follow-up, and the company is the accountable party either
  # way.
  def account_accessed(session)
    @user = session.user
    @reason = session.reason
    @started_at = session.created_at
    @support_url = frontend_url("/")

    mail(to: @user.email, subject: "A Rally support admin accessed your account")
  end
end
