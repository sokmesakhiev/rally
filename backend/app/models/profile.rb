class Profile < ApplicationRecord
  belongs_to :user

  validates :user_id, uniqueness: true

  # Cambodia's most common contact channel — often more reliable than email
  # for reaching a participant. Unique (nulls allowed) so
  # Registrations::GuestCheckout can treat it as an identity-matching field
  # the same way it already treats email: a match against an existing
  # account is a conflict to resolve (sign in), not something to silently
  # merge into. Deliberately lenient format check — Cambodian numbers show
  # up as "012 345 678", "+855 12 345 678", "0123456789", etc., and this
  # app isn't the place to enforce a single canonical format.
  # before_validation :nilify_blank_phone (below) runs first, so "" is
  # already nil by the time these checks run — allow_nil: true is all
  # that's needed here.
  validates :phone, uniqueness: true, allow_nil: true,
                     format: { with: /\A[+]?[\d\s-]{7,20}\z/, message: "doesn't look like a phone number" }
  before_validation :nilify_blank_phone

  # PayWay's API key is a payment-gateway secret — encrypted at rest via
  # Active Record encryption (keys configured in
  # config/initializers/active_record_encryption.rb). It's never returned as
  # plaintext in JSON — see ProfilesController#profile_json, which exposes
  # only #payway_api_key_masked.
  encrypts :payway_api_key

  # Require both fields together (or neither) so an organizer can't end up in
  # a half-configured state where e.g. a merchant ID is saved but the API key
  # isn't, which would silently fall back to Rally's platform credentials
  # instead of raising a clear validation error.
  validates :payway_api_key, presence: true, if: -> { payway_merchant_id.present? }
  validates :payway_merchant_id, presence: true, if: -> { payway_api_key.present? }

  # Treat "" the same as nil, so clearing the field in the UI (submitting a
  # blank string) actually disconnects PayWay instead of leaving an empty
  # string that reads as "present" to a naive check.
  before_validation :nilify_blank_payway_fields

  # True once the organizer has connected their own PayWay account. When
  # true, their event's registration payments (attendee → organizer) are
  # routed through these credentials instead of Rally's platform default —
  # see AbaPayway::Client.for_event.
  def payway_configured?
    payway_merchant_id.present? && payway_api_key.present?
  end

  # payway_rsa_public_key is deliberately not required for payway_configured?
  # — an organizer can take payments without it and only loses the ability to
  # issue *gateway* refunds (AbaPayway::Client#refund) on their own
  # PayWay-configured events until they add it; the manual/logged refund path
  # (Refunds::IssueRefund) never needs it.
  def payway_refund_configured?
    payway_configured? && payway_rsa_public_key.present?
  end

  # Never expose the real key to the frontend — just enough to confirm which
  # one is saved.
  def payway_api_key_masked
    return nil if payway_api_key.blank?
    "•" * 8 + payway_api_key.last(4)
  end

  private

  def nilify_blank_payway_fields
    self.payway_merchant_id = payway_merchant_id.presence
    self.payway_api_key = payway_api_key.presence
  end

  # Same "" vs nil treatment as the PayWay fields above — a cleared field in
  # the UI should actually clear the column, not save an empty string that
  # both looks "present" to a naive check and would collide with every
  # other blank phone number under the unique index if it didn't.
  def nilify_blank_phone
    self.phone = phone.presence
  end
end
