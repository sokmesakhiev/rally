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

  # PayWay credentials moved to Organization in Ticket B (#331) — registration
  # payments settle into the account of whoever *presents* the event, which is
  # an organization, not the individual who created it.
  #
  # The columns are still in the database on purpose. Dropping them in the
  # same deploy that stopped reading them would break any container still
  # serving the old code mid-rollout (ECS replaces tasks gradually, and
  # migrations run on boot). ignored_columns makes Rails behave as though
  # they're already gone; a follow-up ticket drops them once this has been
  # deployed and settled.
  self.ignored_columns += %w[payway_merchant_id payway_api_key payway_rsa_public_key]

  private

  # A cleared field in the UI should actually clear the column, not save an
  # empty string that both looks "present" to a naive check and would collide
  # with every other blank phone number under the unique index if it didn't.
  def nilify_blank_phone
    self.phone = phone.presence
  end
end
