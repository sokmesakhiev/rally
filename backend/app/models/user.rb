class User < ApplicationRecord
  # Rails 8.1's has_secure_password auto-generates a stateless password_reset_token
  # (via generates_token_for) and a class-level find_by_password_reset_token method
  # by default. This app has its own DB-column-backed reset flow below (token +
  # expiry persisted, mailer, controller) — the built-in one is disabled so it
  # doesn't shadow our #password_reset_token attribute reader.
  has_secure_password reset_token: false

  has_one :profile, dependent: :destroy
  has_many :events, foreign_key: :creator_id, dependent: :destroy
  has_many :registrations, dependent: :destroy
  has_many :surveys, foreign_key: :creator_id, dependent: :destroy
  has_many :waitlist_entries, dependent: :destroy
  # Events this user helps run but did NOT create — see EventMembership.
  # Distinct from `events` above (which is creator_id): an organizer's own
  # events and the ones they've been invited onto are different lists, and
  # conflating them would let a member's dashboard imply ownership.
  has_many :event_memberships, dependent: :destroy
  has_many :member_events, through: :event_memberships, source: :event

  # Organizations this user owns — see Organization, where ownership is a
  # column rather than a role. restrict_with_error, not destroy: an
  # organization presents events that other people have paid to register for,
  # so deleting the account can't quietly take it down. User#discard!
  # anonymizes rather than destroys for the same reason.
  has_many :owned_organizations, class_name: "Organization", foreign_key: :owner_id,
                                 dependent: :restrict_with_error
  # Organizations this user helps run but does not own. Distinct from
  # owned_organizations for the same reason member_events is distinct from
  # events above: conflating them would let an admin's dashboard imply
  # ownership they don't have.
  has_many :organization_memberships, dependent: :destroy
  has_many :member_organizations, through: :organization_memberships, source: :organization

  # Every organization this user may act for — owned, plus those where they
  # hold the admin role. This is the set Ticket C (#332) uses to widen
  # EventAuthorization and events#my_events, and the set the frontend's org
  # switcher lists. Plain members are excluded on purpose: org membership
  # alone grants no event authority.
  def administered_organizations
    Organization.where(id: owned_organizations.select(:id))
                .or(Organization.where(id: organization_memberships.admins.select(:organization_id)))
  end

  # Tokens are single-use, random, and time-boxed — plain-text storage is fine
  # here (unlike passwords) since they're low-value, short-lived, and unique.
  PASSWORD_RESET_EXPIRY = 2.hours
  EMAIL_VERIFICATION_EXPIRY = 3.days

  validates :email, presence: true, uniqueness: { case_sensitive: false }, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 8 }, if: :password_required?
  # "Sign in with Google" accounts (see .find_or_create_from_google!) — the
  # DB has a matching unique index; this just gives a friendlier error.
  validates :google_uid, uniqueness: true, allow_nil: true

  before_validation { self.email = email.downcase.strip if email.present? }
  after_create :create_profile!
  after_create :generate_email_verification_token!

  scope :admins, -> { where(admin: true) }
  scope :suspended, -> { where.not(suspended_at: nil) }
  scope :active, -> { where(suspended_at: nil) }
  scope :verified, -> { where.not(verified_at: nil) }
  scope :unverified, -> { where(verified_at: nil) }

  # Soft-delete — see #discard! below. Explicit scopes, not a default_scope
  # (same reasoning as Event/Registration/Survey/WaitlistEntry this
  # session): a default_scope here would make any `belongs_to`/`has_many`
  # pointing at a discarded user silently behave as if they don't exist.
  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }

  def email_verified?
    email_verified_at.present?
  end

  # ── Organizer verification ──────────────────────────────────────────────────

  # Deliberately NOT the same thing as #email_verified?. Email verification is
  # self-service (click a link) and so carries no fraud signal — anyone with a
  # working inbox passes it. This one is granted by an admin only
  # (Admin::UsersController#verify) after a human has vetted the organizer, and
  # is what gates creating paid events (Event#paid?, EventsController's
  # #authorize_paid_event!). Keeping the two separate means loosening or
  # automating email verification later can't accidentally open up payments.
  def verified?
    verified_at.present?
  end

  def verify!(by:)
    update!(verified_at: Time.current, verified_by_id: by&.id)
  end

  # Revoking verification intentionally leaves the organizer's existing paid
  # events alone — they stay published and keep taking registrations. Their
  # participants already committed money on the strength of an event that was
  # legitimately created, and silently unpublishing it would strand them. The
  # revocation only bites on the *next* attempt to create or price a paid
  # event. Taking a specific bad event down is a separate, deliberate
  # moderation action (Admin::EventsController#unpublish), and suspending the
  # organizer outright (User#suspend!) is the tool for "stop everything now".
  def unverify!
    update!(verified_at: nil, verified_by_id: nil)
  end

  # ── Moderation ──────────────────────────────────────────────────────────────

  def suspended?
    suspended_at.present?
  end

  # A suspension takes effect for the public immediately, but nothing is
  # written downward to do it — see organization-identity-tickets.md's
  # Ticket J (#339). Organization#suspended? consults its owner, and
  # Event#suspended? consults its organization, so every event this user
  # presents drops out of public listings (Event.publicly_visible joins both)
  # the moment this row is stamped.
  #
  # This used to `events.published.update_all(is_published: false)`. That is
  # deliberately gone: with derivation it's redundant for hiding events, and
  # now actively wrong, because unsuspending would leave them unpublished and
  # the organizer with fifty events to manually republish — for a paid plan,
  # back through the payment flow.
  #
  # Only organizations this user *owns* are affected. Being suspended costs
  # them their own access to a club they merely administer, but the club and
  # its events carry on: cascading through admin membership would let one bad
  # actor take down a legitimate organization they happened to volunteer for.
  #
  # Their registrations are left alone: cancelling someone else's paid
  # registration is a refund decision, not a moderation one.
  def suspend!(reason: nil)
    update!(suspended_at: Time.current, suspension_reason: reason.presence)
  end

  # Restores everything the cascade took down, automatically — an event
  # suspended on its own merits stays suspended, because its own suspended_at
  # is still set (see Event#suspended?).
  #
  # Note this differs from Event#unsuspend!, which does NOT re-publish an
  # event that direct suspension unpublished — that stays the organizer's own
  # decision, and for a paid plan goes back through
  # EventPlanPaymentsController so plan/capacity stay consistent. The
  # asymmetry is deliberate: suspending an event is a judgment about that
  # event, suspending an account is a judgment about the account, and lifting
  # the latter should undo it wholesale.
  def unsuspend!
    update!(suspended_at: nil, suspension_reason: nil)
  end

  # Self-service account deletion — see Api::V1::AuthController#delete_account,
  # which blocks calling this at all while the user organizes an event with
  # a paid registration still outstanding (same guard
  # Admin::EventsController#destroy uses). Anonymizes this account's own PII
  # and permanently blocks sign-in, but deliberately does NOT hard-`destroy`
  # the row — the has_many :events, dependent: :destroy chain above would
  # cascade into every event this user organized, taking down *other*
  # people's registrations/payments/refunds for those events too. Hiding
  # (not destroying) their own remaining events is safe once the paid-event
  # guard has already passed — nothing left has money attached to it.
  #
  # Distinct from #suspend! (admin-initiated, reversible, keeps real PII) —
  # this is user-initiated and irreversible, hence its own deleted_at column
  # rather than overloading suspended_at.
  def discard!
    transaction do
      events.kept.each(&:discard!)
      # password_confirmation is a virtual attr_accessor from has_secure_password
      # that validates_confirmation_of checks *whenever it's already been set on
      # this in-memory object* (e.g. by the factory/signup flow that created it),
      # not just when explicitly passed here. Leaving it out would leave a stale
      # confirmation value around that no longer matches the new random
      # password, so it must be set alongside password, not omitted.
      unusable_password = SecureRandom.hex(32)
      update!(
        email: "deleted-#{id}@deleted.rally.invalid",
        # The account's own placeholder now, not a "please add a real
        # email" nudge — leaving this true post-deletion would make
        # User.where(email_auto_generated: true) (the query behind that
        # nudge) surface dead, anonymized accounts alongside the phone-only
        # guests it's actually meant for.
        email_auto_generated: false,
        password: unusable_password,
        password_confirmation: unusable_password,
        google_uid: nil,
        provider: nil,
        email_verified_at: nil,
        email_verification_token: nil,
        email_verification_sent_at: nil,
        password_reset_token: nil,
        password_reset_sent_at: nil,
        deleted_at: Time.current
      )
      profile&.update!(
        display_name: nil,
        avatar_url: nil,
        phone: nil
      )
      # PayWay credentials live on Organization since Ticket B (#331), so
      # clearing them here means clearing them there. The organizations
      # themselves survive — they present events other people registered for,
      # the same reason this method hides events rather than destroying them —
      # but a deleted account's live merchant credentials must not linger on
      # them. Safe by the time we get here: #delete_account already refuses
      # while any of this user's events still has an outstanding paid
      # registration.
      owned_organizations.find_each do |organization|
        organization.update!(
          payway_merchant_id: nil,
          payway_api_key: nil,
          payway_rsa_public_key: nil
        )
      end
    end
  end

  def discarded?
    deleted_at.present?
  end

  def verify_email!
    update!(email_verified_at: Time.current, email_verification_token: nil, email_verification_sent_at: nil)
  end

  def generate_email_verification_token!
    update!(email_verification_token: SecureRandom.urlsafe_base64(32), email_verification_sent_at: Time.current)
  end

  def generate_password_reset_token!
    update!(password_reset_token: SecureRandom.urlsafe_base64(32), password_reset_sent_at: Time.current)
  end

  def password_reset_token_valid?
    password_reset_token.present? && password_reset_sent_at.present? &&
      password_reset_sent_at > PASSWORD_RESET_EXPIRY.ago
  end

  def reset_password!(new_password)
    update!(password: new_password, password_confirmation: new_password,
            password_reset_token: nil, password_reset_sent_at: nil)
  end

  class << self
    def find_by_valid_password_reset_token(token)
      return nil if token.blank?
      user = find_by(password_reset_token: token)
      return nil unless user
      return nil unless user.password_reset_token_valid?
      user
    end

    def find_by_valid_email_verification_token(token)
      return nil if token.blank?
      user = find_by(email_verification_token: token)
      return nil unless user
      return nil if user.email_verification_sent_at.present? && user.email_verification_sent_at < EMAIL_VERIFICATION_EXPIRY.ago
      user
    end

    # Called from AuthController#google *after* the ID token has already
    # been cryptographically verified server-side — `google_uid`/`email`
    # are trusted at this point, not user input.
    #
    # Three cases, in order:
    #   1. We've seen this Google account before (google_uid matches) — sign them in.
    #   2. No Google link yet, but the email matches an existing password
    #      account — link Google to it (so switching to "Sign in with
    #      Google" later doesn't create a second account) and, since Google
    #      already verified the address, mark it verified if it wasn't.
    #   3. Neither — create a brand new Google-only account. It still gets a
    #      real (unusable, never shown) random password so the existing
    #      has_secure_password/password_digest NOT NULL invariant holds and
    #      no schema/validation special-casing is needed for OAuth users.
    def find_or_create_from_google!(google_uid:, email:, email_verified:, name:)
      user = find_by(google_uid: google_uid)
      return user if user

      user = find_by(email: email.downcase.strip)
      if user
        user.update!(google_uid: google_uid, provider: user.provider || "google")
        user.verify_email! if email_verified && !user.email_verified?
        return user
      end

      # Deliberately does NOT stamp terms_accepted_at/terms_version here —
      # unlike the email/password path (AuthController#signup), this one-click
      # flow never shows the user a checkbox, so there's nothing real to
      # record consent for yet. terms_accepted_at stays nil, and
      # AuthController#accept_terms is what the frontend calls once it shows
      # this new account a one-time acceptance interstitial. See
      # event-freeze-and-terms-tickets.md's Ticket H.
      user = create!(email: email, password: SecureRandom.hex(32), google_uid: google_uid, provider: "google")
      user.verify_email! if email_verified
      user.profile.update!(display_name: name) if name.present?
      user
    end
  end

  private

  def password_required?
    password_digest.nil? || password.present?
  end
end
