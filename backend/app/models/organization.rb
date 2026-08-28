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

  has_many :organization_memberships, dependent: :destroy
  has_many :members, through: :organization_memberships, source: :user

  # NOTE: `has_many :events` deliberately does NOT live here yet — Ticket C
  # (#332) adds it along with the events.organization_id column. Declaring it
  # now would install a dependent-callback that queries a column the database
  # doesn't have, which fails only at destroy time rather than at boot.

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
  # Populated by Ticket I (#338), which moves the paid-event gate off
  # User#verified?. Defined now so the public payload and badge have a stable
  # thing to read; until #338 lands nothing sets it.
  def verified?
    verified_at.present?
  end

  def verify!
    update!(verified_at: Time.current)
  end

  def unverify!
    update!(verified_at: nil)
  end

  # ── Soft-delete ──────────────────────────────────────────────────────────

  def discarded?
    deleted_at.present?
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
end
