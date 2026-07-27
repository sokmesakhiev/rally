class Event < ApplicationRecord
  belongs_to :creator, class_name: "User"
  belongs_to :survey, optional: true
  has_many :registrations, dependent: :destroy
  has_many :event_types, -> { order(position: :asc) }, dependent: :destroy
  has_many :event_plan_payments, dependent: :destroy

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
    "extra_large" => { label: "Extra Large", capacity: 30_000, price_cents: 200_000 },
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
