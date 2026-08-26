# A pending invitation to help run an event — see
# db/migrate/20260826000001_create_event_invitations.rb, and
# EventMembership for the accepted counterpart.
#
# Token handling follows User's existing email-verification flow exactly
# (SecureRandom.urlsafe_base64(32), stored plaintext, time-boxed, single-use
# by virtue of accepted_at): these are low-value, short-lived, unique
# strings, so plaintext storage is fine here in a way it isn't for passwords.
class EventInvitation < ApplicationRecord
  EXPIRY = 14.days

  belongs_to :event
  belongs_to :invited_by, class_name: "User"

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: EventMembership::ROLES }
  validates :token, presence: true, uniqueness: true

  before_validation :normalize_email
  before_validation :set_defaults, on: :create

  # "Still usable" — the only scope authorization should ever look at. An
  # invitation that's been accepted, revoked, or has aged out is dead; the
  # row survives purely as a record of who was asked.
  scope :pending, -> { where(accepted_at: nil, revoked_at: nil).where("expires_at > ?", Time.current) }

  def pending?
    !accepted? && !revoked? && !expired?
  end

  def accepted?
    accepted_at.present?
  end

  def revoked?
    revoked_at.present?
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def accept!
    update!(accepted_at: Time.current)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  class << self
    # Mirrors User.find_by_valid_email_verification_token's shape: returns
    # nil rather than raising for every failure mode, so callers can render
    # one "this invitation is no longer valid" state without having to
    # distinguish expired-from-revoked-from-nonexistent (and without
    # confirming to a stranger holding a guessed token which it was).
    def find_by_valid_token(token)
      return nil if token.blank?

      invitation = find_by(token: token)
      return nil unless invitation
      return nil unless invitation.pending?

      invitation
    end

    def generate_token
      SecureRandom.urlsafe_base64(32)
    end
  end

  private

  def normalize_email
    self.email = email.downcase.strip if email.present?
  end

  def set_defaults
    self.token ||= self.class.generate_token
    self.expires_at ||= EXPIRY.from_now
  end
end
