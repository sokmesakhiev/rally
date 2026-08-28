# The public identity an event is presented under — see
# organization-identity-tickets.md's Ticket A (#330).
#
# Events belong to an organization rather than directly to the User who
# created them, so a club with several staff shares one brand, and one person
# can run several distinct brands without those events looking like they came
# from the same place.
#
# **Ownership is a column, not a role.** #owner_id is the single source of
# truth; OrganizationMembership holds "admin" and "member" only. That makes
# "exactly one owner" structural rather than an invariant validations have to
# defend, and gives #suspended? below a plain belongs_to to follow instead of
# a join through membership rows on a hot authorization path.
class Organization < ApplicationRecord
  belongs_to :owner, class_name: "User"
  # Which staff account vouched for this organization — mirrors
  # User#verified_by. Nullable: unverified organizations have none, and an
  # admin's account may later be anonymized by User#discard!.
  belongs_to :verified_by, class_name: "User", optional: true

  has_many :organization_memberships, dependent: :destroy
  has_many :members, through: :organization_memberships, source: :user

  # restrict_with_error, not destroy: an organization presents events other
  # people have paid to register for, so removing it can't quietly take them
  # down. Same reasoning as User#owned_organizations, and the same reason
  # User#discard! anonymizes rather than destroys.
  has_many :events, dependent: :restrict_with_error

  MAX_SLUG_LENGTH = 60

  # Anchored at BOTH ends, deliberately. Two things go wrong without `\z`:
  #
  #   "https://example.com\njavascript:alert(1)"   # newline injection
  #   "https://example.com junk"
  #
  # both pass a `\Ahttps?://`-style check, and these values are rendered
  # straight into href attributes on the public organizer page.
  #
  # Wraps URI::DEFAULT_PARSER.make_regexp (the same helper Event#route_map_url
  # uses) rather than hand-rolling a URL pattern — but note make_regexp is
  # itself UNANCHORED, so using it bare would additionally accept
  # "junk https://example.com". The anchors are doing real work here.
  URL_FORMAT = /\A#{URI::DEFAULT_PARSER.make_regexp(%w[http https])}\z/

  validates :name, presence: true, length: { maximum: 120 }
  validates :slug, presence: true, uniqueness: { case_sensitive: false },
                   format: { with: /\A[a-z0-9-]+\z/, message: "may only contain lowercase letters, numbers, and hyphens" }
  validates :description, length: { maximum: 2_000 }, allow_blank: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :website, :facebook_url, :instagram_url, :telegram_url,
            format: { with: URL_FORMAT, message: "must be a valid http(s) URL" }, allow_blank: true

  before_validation :generate_slug, on: :create
  validate :slug_is_immutable, on: :update

  # ── PayWay (attendee → organizer registration payments) ──────────────────
  # Moved here from Profile in Ticket B (#331): registration money settles
  # into the account of whoever *presents* the event, which is this
  # organization, not whichever colleague happened to create it.
  #
  # PayWay's API key is a payment-gateway secret — encrypted at rest via
  # Active Record encryption (keys in config/initializers/active_record_encryption.rb).
  # Never returned as plaintext in JSON; callers get #payway_api_key_masked.
  encrypts :payway_api_key

  # Require both together (or neither), so an organization can't sit in a
  # half-configured state where a merchant ID is saved but the key isn't —
  # which would silently fall back to Rally's platform credentials instead of
  # raising a clear validation error.
  validates :payway_api_key, presence: true, if: -> { payway_merchant_id.present? }
  validates :payway_merchant_id, presence: true, if: -> { payway_api_key.present? }

  # Treat "" as nil so clearing a field in the UI actually disconnects PayWay
  # rather than leaving an empty string that reads as "present".
  before_validation :nilify_blank_payway_fields

  # Explicit scopes rather than a default_scope, matching Event/Registration/
  # Survey/User: a default_scope here would make any belongs_to pointing at a
  # discarded or suspended organization silently behave as though it doesn't
  # exist, which is exactly the wrong thing for an admin reviewing one.
  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }
  scope :verified, -> { where.not(verified_at: nil) }

  # Organizations whose owner is also in good standing. This is the scope
  # public-facing queries want — see Ticket J (#339), which adds the matching
  # Event scope and audits every existing Event.published call site.
  scope :active, -> {
    kept.where(suspended_at: nil)
        .joins(:owner).where(users: { suspended_at: nil })
  }

  # ── Roles ────────────────────────────────────────────────────────────────

  def owner?(user)
    user.present? && owner_id == user.id
  end

  # Owner or admin — the set allowed to act for the organization: create
  # events under it, edit its identity, manage its team. Ticket C (#332) uses
  # exactly this to widen EventAuthorization's :owner resolution.
  def administered_by?(user)
    return false if user.nil?
    return true if owner?(user)

    organization_memberships.exists?(user_id: user.id, role: "admin")
  end

  # Any relationship at all, including plain members. A plain member gets no
  # event authority from this — they still need an EventMembership like
  # anyone else — so don't reach for this when gating an action.
  def member?(user)
    return false if user.nil?
    return true if owner?(user)

    organization_memberships.exists?(user_id: user.id)
  end

  def admins
    User.where(id: organization_memberships.where(role: "admin").select(:user_id))
  end

  # The owner plus every membership row, as one list — member-listing
  # endpoints and UI want the team to read as a single roster even though
  # ownership is stored separately.
  def team
    # Both sides stay as relations so `select` is a subquery. Splatting the
    # membership relation into an array would call #to_a and hand `where`
    # OrganizationMembership records, which Rails then matches on their own
    # primary keys rather than user_id — silently returning just the owner.
    User.where(id: owner_id)
        .or(User.where(id: organization_memberships.select(:user_id)))
  end

  # ── Moderation ───────────────────────────────────────────────────────────
  # Suspension is DERIVED downward, never written downward — see Ticket J
  # (#339). An organization is suspended if it was suspended directly, or if
  # the person who owns it was. Event#suspended? consults this in turn.
  #
  # Deriving rather than copying is what makes unsuspending correct: lifting
  # a suspension restores exactly what the cascade took down, while anything
  # suspended directly on its own merits stays down because its own
  # suspended_at is still set. No provenance column, no reconciliation job,
  # and no way for organization and event state to drift apart.
  def suspended?
    suspended_at.present? || owner.suspended?
  end

  # True only when this organization itself was suspended, ignoring the
  # owner. Use when the UI needs to explain *why* something is unavailable —
  # "this organizer was suspended" reads differently from "this organizer's
  # account was suspended".
  def suspended_directly?
    suspended_at.present?
  end

  # Mirrors User#suspend!/Event#suspend! exactly — same shape, same blank
  # reason handling. Deliberately does NOT touch its events: they derive
  # their state from this one.
  def suspend!(reason: nil)
    update!(suspended_at: Time.current, suspension_reason: reason.presence)
  end

  def unsuspend!
    update!(suspended_at: nil, suspension_reason: nil)
  end

  # ── Verification ─────────────────────────────────────────────────────────
  # What gates creating paid events, as of Ticket I (#338). Verification is a
  # claim about *who takes the money* — since #332 that's the organization
  # presenting the event, not whichever colleague clicked Create, and since
  # #331 the funds settle into this organization's own PayWay account.
  #
  # Mirrors User#verified?/#verify!(by:)/#unverify! exactly, including the
  # `by:` argument, so the two read the same at every call site. Deliberately
  # unrelated to a *user's* email verification, which is self-service —
  # keeping them separate means loosening email verification later can't
  # accidentally open up payments.
  def verified?
    verified_at.present?
  end

  def verify!(by:)
    update!(verified_at: Time.current, verified_by_id: by&.id)
  end

  # Revoking leaves existing paid events alone — they stay published and keep
  # taking registrations, matching User#unverify!'s reasoning: participants
  # already committed money to an event that was legitimately created, and
  # silently unpublishing it would strand them. This only bites on the *next*
  # attempt to create or price a paid event. Taking a specific bad event down
  # is a separate moderation action (Admin::EventsController#suspend).
  def unverify!
    update!(verified_at: nil, verified_by_id: nil)
  end

  # ── Publish-readiness ────────────────────────────────────────────────────
  # organization-identity-tickets.md's Ticket E (#334): a public event must
  # be presented by an organization an audience can actually evaluate. A
  # listing whose organizer is a bare name defeats the point of the feature.
  #
  # Contact is either/or — an organizer reachable by phone is reachable, and
  # phone is the more common channel here (see Profile#phone).
  IDENTITY_REQUIREMENTS = {
    name: ->(org) { org.name.present? },
    logo_url: ->(org) { org.logo_url.present? },
    description: ->(org) { org.description.present? },
    contact: ->(org) { org.contact_email.present? || org.contact_phone.present? }
  }.freeze

  # Whether the publish gate is actually enforced.
  #
  # Off by default, deliberately. Every organization that exists today was
  # created by a backfill (#330) or implicitly on first event creation (#332),
  # so none of them have a description or contact details — and until Ticket G
  # (#336) ships the organization settings UI, an organizer has no way in the
  # app to add them. Enforcing on merge would block *all* publishing, for
  # everyone, until #336.
  #
  # Flip REQUIRE_ORGANIZATION_IDENTITY=true once #336 is deployed and
  # organizers can complete their profile. The rule, its error payload, and
  # its specs all exist and are exercised either way.
  def self.identity_required_for_publishing?
    ActiveModel::Type::Boolean.new.cast(ENV["REQUIRE_ORGANIZATION_IDENTITY"]) || false
  end

  # Field names the organizer still has to fill in. Empty means ready.
  # Returned to the frontend so the error names what's missing rather than
  # making them guess — and so Ticket G's settings page can render the same
  # checklist from one source of truth.
  def missing_identity_fields
    IDENTITY_REQUIREMENTS.reject { |_field, present| present.call(self) }.keys
  end

  def identity_complete?
    missing_identity_fields.empty?
  end

  # ── Public trust signals ─────────────────────────────────────────────────
  # organization-identity-tickets.md's Ticket F (#335). Read on every public
  # organizer page view, so both are single database aggregates — loading
  # events and counting registrations in Ruby would be an N+1 on a page
  # anyone can hit.
  #
  # "Run" means finished, not merely published: an organizer with fifty
  # upcoming events and none delivered has no track record to speak of, and
  # this number is meant to say something an audience can rely on.
  def events_run
    events.publicly_visible.ended.count
  end

  # Registrations across those same finished events, excluding cancellations.
  # One COUNT over a join rather than a per-event tally.
  def participants_hosted
    Registration.kept.active
      .where(event_id: events.publicly_visible.ended.select(:id))
      .count
  end

  # ── PayWay predicates ────────────────────────────────────────────────────
  # Lifted verbatim from Profile (#331) — same semantics, new home.

  # True once this organization has connected its own PayWay account. When
  # true, its events' registration payments route through these credentials
  # instead of Rally's platform default — see AbaPayway::Client.for_event.
  def payway_configured?
    payway_merchant_id.present? && payway_api_key.present?
  end

  # payway_rsa_public_key is deliberately not required for #payway_configured?
  # — an organization can take payments without it and only loses the ability
  # to issue *gateway* refunds (AbaPayway::Client#refund) until they add it;
  # the manual/logged refund path (Refunds::IssueRefund) never needs it.
  def payway_refund_configured?
    payway_configured? && payway_rsa_public_key.present?
  end

  # Never expose the real key — just enough to confirm which one is saved.
  def payway_api_key_masked
    return nil if payway_api_key.blank?
    "•" * 8 + payway_api_key.last(4)
  end

  # ── Soft-delete ──────────────────────────────────────────────────────────

  def discarded?
    deleted_at.present?
  end

  # False while this organization still presents events people may have
  # registered and paid for. `has_many :events, dependent: :restrict_with_error`
  # only guards a real #destroy, which nothing calls — soft-deleting needs its
  # own check or an organizer could quietly remove the identity behind a live
  # event, leaving its "Presented by" block pointing at nothing.
  def discardable?
    !events.kept.exists?
  end

  def discard!
    update!(deleted_at: Time.current)
  end

  def to_param
    slug
  end

  private

  # Slugs are generated once, from the name, and never regenerated — see
  # #slug_is_immutable. Callers may pass an explicit slug (admin tooling,
  # fixtures); this only fills in a blank one.
  def generate_slug
    return if slug.present?

    base = self.class.slug_base_for(name)
    candidate = base
    suffix = 2
    while self.class.where(slug: candidate).exists?
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end

  # #parameterize strips non-ASCII entirely, so a Khmer-only name
  # ("ក្លឹបរត់ភ្នំពេញ") yields "" — which would fail the format validation and,
  # worse, collide every such organizer onto the same empty slug. Fall back
  # to a stable random one instead. This app is bilingual by design, so this
  # is a normal case, not an edge case.
  def self.slug_base_for(name)
    base = name.to_s.parameterize.presence
    base ||= "organizer-#{SecureRandom.hex(4)}"
    base.first(MAX_SLUG_LENGTH)
  end

  def slug_is_immutable
    return unless slug_changed?

    errors.add(:slug, "cannot be changed once the organization has been created")
  end

  def nilify_blank_payway_fields
    self.payway_merchant_id = payway_merchant_id.presence
    self.payway_api_key = payway_api_key.presence
    self.payway_rsa_public_key = payway_rsa_public_key.presence
  end
end
