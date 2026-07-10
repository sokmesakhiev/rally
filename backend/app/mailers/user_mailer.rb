class UserMailer < ApplicationMailer
  def password_reset(user)
    @user = user
    @reset_url = frontend_url("/reset-password/#{user.password_reset_token}")
    mail(to: @user.email, subject: "Reset your Rally password")
  end

  def email_verification(user)
    @user = user
    @verify_url = frontend_url("/verify-email/#{user.email_verification_token}")
    mail(to: @user.email, subject: "Verify your email for Rally")
  end
end
