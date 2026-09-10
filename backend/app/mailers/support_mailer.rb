class SupportMailer < ApplicationMailer
  # The fallback for a participant who asked something and walked away.
  #
  # Sent by SupportReplyFallbackEmailJob only when they still haven't read the
  # reply after a delay — chat is the primary channel here, and this exists so
  # that closing the tab doesn't turn a support conversation into a black hole.
  #
  # Deliberately does **not** quote the reply body. Support threads carry
  # whatever people choose to paste, which on a payments product means card
  # complaints and personal details; email is the least controlled channel we
  # have and the most likely to be forwarded or sit unencrypted in an archive.
  # A nudge to come back and read it in the app costs one click and leaks
  # nothing.
  def reply_waiting(message)
    @message = message
    @user = message.conversation.user
    @chat_url = frontend_url("/")

    mail(to: @user.email, subject: "Rally Support replied to you")
  end
end
