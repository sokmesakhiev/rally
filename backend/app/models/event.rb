class Event < ApplicationRecord
  belongs_to :creator, class_name: "User"
  belongs_to :survey, optional: true
  has_many :registrations, dependent: :destroy
  has_many :event_types, -> { order(position: :asc) }, dependent: :destroy
  has_many :event_plan_payments, dependent: :destroy
  has_many :waitlist_entries, -> { order(created_at: :asc) }, dependent: :destroy
  has_many :event_activities, dependent: :destroy
  # The event's team — people other than #creator who help run it. See
  # EventMembership. `dependent: :destroy` here only fires on a real
  # `destroy` (which nothing in the app calls on Event); the soft-delete
  # path, #discard!, deliberately leaves memberships alone — see there.
  has_many :event_memberships, dependent: :destroy
  has_many :members, through: :event_memberships, source: :user
  has_many :event_invitations, dependent: :destroy

  accepts_nested_attributes_for :event_types,
    allow_destroy: true,
    reject_if: :all_blank

  has_one_attached :banner_image
  has_one_attached :logo_image

  CATEGORIES = %w[running cycling swimming triathlon hiking other].freeze

  # Organizer-facing pricing tiers. Publishing an event requires picking one
  # of these — it sets the event's capacity and (for paid tiers) requires an
  # EventPlanPayment before is_published can flip to true. Order matters: it
  # drives display order on the pricing page and in the publish flow.
  PLANS = {
    "free" =>        { label: "Free",        capacity: 20,     price_cents: 0 },
    "small" =>       { label: "Small",       capacity: 200,    price_cents: 10_000 },
    "medium" =>      { label: "Medium",      capacity: 1_000,  price_cents: 30_000 },
    "large" =>       { label: "Large",       capacity: 10_000, price_cents: 100_000 },
    "extra_large" => { label: "Extra Large", capacity: 30_000, price_cents: 200_000 }
  }.freeze

  validates :title, presence: true, length: { maximum: 120 }
  validates :category, inclusion: { in: CATEGORIES }
  validates :start_at, presence: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0 }
  validates :plan, inclusion: { in: PLANS.keys }, allow_nil: true
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 },
    allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 },
    allow_nil: true
  # Set by the frontend's Google Maps location picker — both or neither, so a
  # pin never ends up half-placed (e.g. after a partial client-side bug).
  validate :lat_lng_present_together
  validates :route_map_url, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]),
    message: "must be a valid http(s) URL" }, allow_blank: true
  validate :end_after_start
  # Only meaningful once a plan has actually set a capacity — a draft event
  # with types but no plan yet (capacity nil) isn't constrained by this.
  validate :capacity_covers_event_types, if: -> { capacity.present? }

  before_validation :default_price_cents

  scope :published, -> { where(is_published: true) }
  scope :upcoming, -> { where("start_at >= ?", Time.current) }

  # Free-text search across the fields a participant would plausibly type:
  # event name, blurb, and place. Deliberately ILIKE rather than Postgres
  # full-text search — at this catalogue size the simpler thing is easier to
  # reason about, matches partial words (which tsquery wouldn't without extra
  # work), and avoids a tsvector column plus its maintenance. Worth revisiting
  # if the events table gets large enough for the sequential scan to hurt.
  #
  # sanitize_sql_like escapes % and _ so a query containing them is treated as
  # literal text rather than as wildcards.
  scope :search, ->(term) {
    query = term.to_s.strip
    next all if query.blank?

    pattern = "%#{sanitize_sql_like(query)}%"
    where(
      "events.title ILIKE :pattern OR events.description ILIKE :pattern OR events.location ILIKE :pattern",
      pattern: pattern
    )
  }

  scope :in_category, ->(category) {
    category.presence ? where(category: category) : all
  }

  # Soft-delete — see db/migrate/20260817000003_add_deleted_at_to_soft_deletable_tables.rb
  # for why this is an explicit scope rather than a Rails `default_scope`
  # (the short version: `belongs_to :event` elsewhere would silently inherit
  # a default_scope too, breaking e.g. `registration.event` the moment its
  # event was discarded). Callers opt in at read call sites that need it —
  # see EventsController#index/#my_events and #set_event.
  scope :kept, -> { where(deleted_at: nil) }
  scope :discarded, -> { where.not(deleted_at: nil) }

  # Soft-delete: hides the event (and, since it's no longer reachable
  # through normal reads, effectively everyone downstream of it) without
  # touching payments, event_types, or event_plan_payments — those remain as
  # historical/financial records attached to a now-hidden event rather than
  # being destroyed. Cascades to registrations/waitlist_entries specifically
  # because those need to stop counting toward capacity and stop appearing
  # in "my registrations"/"my waitlist spots" lists, which is what their own
  # #discard! achieves (not because they need to be hidden for their own
  # sake). Also unpublishes, belt-and-suspenders alongside #kept filtering —
  # mirrors User#suspend!.
  #
  # Deliberately named #discard! (not overriding #destroy!) — the app's
  # `dependent: :destroy` declarations above are real hard-delete behavior
  # that should still fire if something ever legitimately calls #destroy!
  # directly (e.g. a future admin console cleanup script); silently
  # redefining what #destroy! means would be its own footgun.
  # Memberships and invitations are deliberately left untouched here (see
  # event-membership-tickets.md's "Ticket A"). A discarded event is hidden,
  # not gone, and if it's ever restored the organizer shouldn't have to
  # rebuild their team and re-send every invitation. Nothing reads a
  # membership without going through the event anyway, so a team attached
  # to a hidden event grants no access to anything. Contrast the two lines
  # below, which discard for a different reason entirely — capacity and
  # "my registrations" listings, not concealment.
  def discard!
    transaction do
      registrations.kept.find_each(&:discard!)
      waitlist_entries.kept.find_each(&:discard!)
      update!(deleted_at: Time.current, is_published: false)
    end
  end

  def discarded?
    deleted_at.present?
  end

  def plan_details
    PLANS[plan]
  end

  # Sum of each event type's own capacity — the most people who could
  # register across all types combined. Types with no capacity of their own
  # (unlimited) don't contribute a number here, since they have no explicit
  # limit to add up.
  def combined_event_type_capacity
    event_types.filter_map(&:capacity).sum
  end

  # Same predicate Registration#event_not_full validates against — kept here
  # too so WaitlistEntry (and anything else that needs to ask "is this event
  # full right now?") doesn't have to duplicate the capacity.present? guard.
  # .active excludes cancelled registrations (see Registration::active) so a
  # fully-refunded registration's spot actually counts as free.
  def full?
    capacity.present? && registrations.active.count >= capacity
  end

  # Does registering for this event cost money? Checks BOTH the event's own
  # price and each type's, because EventType#effective_price_cents falls back
  # to the parent event's price — so an event with price_cents: 0 is still a
  # paid event if any of its types carries its own nonzero price. Anything
  # gating on "is this paid" (today: the organizer-verification requirement in
  # Api::V1::EventsController) has to ask it this way or the per-type path is
  # a trivial bypass.
  # Safe to call on an unsaved record with nested attributes already assigned
  # (which is exactly how EventsController checks a *pending* create/update
  # before committing it) — hence skipping types marked for destruction, which
  # are still in the association until save but won't survive it.
  def paid?
    return true if price_cents.to_i.positive?

    event_types.reject(&:marked_for_destruction?)
      .any? { |type| type.effective_price_cents.to_i.positive? }
  end

  # An organizer has uploaded a certificate-of-participation template — see
  # Api::V1::UploadsController (type: "certificate_template") and
  # Certificates::RenderPdf, which merges participant/event data into it.
  def certificate_template?
    certificate_template_url.present?
  end

  # "Completed" for certificate purposes — end_at if the organizer set one,
  # otherwise start_at. Used by GenerateCertificatesJob to decide which
  # events are done, not just which have already started.
  def ended?
    (end_at || start_at) <= Time.current
  end

  private

  def default_price_cents
    self.price_cents ||= 0
  end

  def end_after_start
    return unless end_at && start_at
    errors.add(:end_at, "must be after start time") if end_at <= start_at
  end

  def lat_lng_present_together
    return if latitude.present? == longitude.present?
    errors.add(:base, "latitude and longitude must both be set, or both left blank")
  end

  def capacity_covers_event_types
    total = combined_event_type_capacity
    return if total <= capacity
    errors.add(:capacity,
      "must be at least #{total} to cover the combined limit across all event types (currently #{total})")
  end
end
