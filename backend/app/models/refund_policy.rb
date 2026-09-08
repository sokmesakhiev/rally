# frozen_string_literal: true

# An event's refund policy: a set of tiers, each saying "cancel at least this
# long before the event starts and you get this percentage back".
#
# A plain value object, not an ActiveRecord model — it has no table of its
# own. Events and registrations both store the raw tiers in a jsonb column
# (`refund_policy_tiers`) and hand them to this class to be reasoned about.
#
# See platform-payments-tickets.md Ticket D. The evaluation function is
# deliberately pure: it takes hours and returns a percentage, touching no
# database and no clock, so the interesting cases are cheap to test and the
# ones that matter (boundaries) are exact rather than approximate.
class RefundPolicy
  # A guard against an unbounded jsonb blob, not a product limit anyone is
  # expected to reach — three or four tiers is a realistic policy.
  MAX_TIERS = 10

  Tier = Data.define(:hours_before, :refund_percent) do
    # jsonb round-trips with string keys, but a policy built in Ruby (a
    # template, a spec) has symbols. Normalise both here so no caller has to
    # care which side the data came from.
    def self.from(raw)
      raw = raw.symbolize_keys if raw.respond_to?(:symbolize_keys)
      new(
        hours_before: cast_integer(raw[:hours_before]),
        refund_percent: cast_integer(raw[:refund_percent])
      )
    end

    # Returns nil rather than raising on junk — an invalid tier should surface
    # as a validation error naming the problem, not as a 500 while parsing.
    def self.cast_integer(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def to_h
      { "hours_before" => hours_before, "refund_percent" => refund_percent }
    end

    def covers?(hours_until_start)
      hours_before.present? && hours_until_start >= hours_before
    end
  end

  # Named presets a host can start from. "non_refundable" is an explicit,
  # meaningful choice — an empty tier list means "nothing back at any point",
  # which is different from having set no policy at all (nil).
  TEMPLATES = {
    "flexible" => [
      { hours_before: 24, refund_percent: 100 }
    ],
    "standard" => [
      { hours_before: 168, refund_percent: 100 },
      { hours_before: 48,  refund_percent: 50 }
    ],
    "strict" => [
      { hours_before: 336, refund_percent: 50 }
    ],
    "non_refundable" => []
  }.freeze

  attr_reader :tiers

  class << self
    def template(name)
      raw = TEMPLATES[name.to_s]
      raw && new(raw)
    end

    def template_names
      TEMPLATES.keys
    end

    # nil in, nil out: an event with no policy set is a different thing from
    # an event whose policy returns nothing, and collapsing the two here
    # would lose that distinction everywhere downstream.
    def from(raw_tiers)
      return nil if raw_tiers.nil?

      new(raw_tiers)
    end
  end

  def initialize(raw_tiers)
    @tiers = Array(raw_tiers).map { |raw| Tier.from(raw) }
  end

  # THE function. Given how many hours remain until the event starts, what
  # percentage comes back?
  #
  # Deliberately order-independent: it takes the most generous tier the
  # participant qualifies for, rather than the first match in stored order.
  # Ordering is validated on the way in, but evaluation shouldn't depend on
  # that having held — a hand-edited or legacy row should still produce a
  # defensible answer rather than a silently wrong one. "Most generous
  # qualifying tier" is also the right reading of an ambiguous policy: if two
  # tiers both apply, the participant gets the better of them.
  #
  # Anything past the last cutoff gets 0. That final "and nothing after
  # that" tier is implicit and never stored.
  def refund_percent_for(hours_until_start)
    return 0 if hours_until_start.nil?

    tiers.select { |tier| tier.covers?(hours_until_start) }
         .filter_map(&:refund_percent)
         .max || 0
  end

  # Rounds to the nearest cent. A sub-cent difference is immaterial either
  # way, and rounding beats truncating for a host explaining "50% of $9.99".
  # It can never exceed what was paid, since percent is capped at 100.
  def refund_amount_cents(paid_cents, hours_until_start:)
    return 0 if paid_cents.nil? || paid_cents <= 0

    percent = refund_percent_for(hours_until_start)
    return 0 if percent.zero?
    return paid_cents if percent >= 100

    (paid_cents * percent / 100.0).round
  end

  def non_refundable?
    tiers.empty?
  end

  # Which named preset this matches, if any — so the UI can say "Standard"
  # instead of re-describing the tiers, without storing a template name that
  # could drift out of sync with the tiers themselves.
  def template_name
    TEMPLATES.each do |name, raw|
      return name if self.class.new(raw).tiers == tiers
    end
    nil
  end

  def valid?
    errors.empty?
  end

  # Returns messages rather than raising, so Event can fold them into its own
  # ActiveModel errors and the caller gets one coherent 422.
  def errors
    @errors ||= begin
      messages = []
      messages << "cannot have more than #{MAX_TIERS} tiers" if tiers.size > MAX_TIERS
      messages.concat(tier_value_errors)
      messages.concat(ordering_errors) if messages.empty?
      messages
    end
  end

  def as_json(*)
    { "tiers" => tiers.map(&:to_h), "template_name" => template_name }
  end

  def to_a
    tiers.map(&:to_h)
  end

  def ==(other)
    other.is_a?(self.class) && other.tiers == tiers
  end

  private

  def tier_value_errors
    tiers.each_with_index.filter_map do |tier, index|
      position = index + 1
      if tier.hours_before.nil? || tier.refund_percent.nil?
        "tier #{position} needs a whole number of hours and a whole percentage"
      elsif tier.hours_before.negative?
        "tier #{position} cannot be a negative number of hours before the event"
      elsif !tier.refund_percent.between?(0, 100)
        "tier #{position} must refund between 0% and 100%"
      end
    end
  end

  # Two rules, both about tiers making sense as a sequence:
  #
  #   * cutoffs must strictly decrease, which is what "non-overlapping"
  #     means here — two tiers with the same cutoff, or one nested inside
  #     another, have no single answer at that moment.
  #   * the percentage must not go *up* as the event gets closer. A policy
  #     that pays more the later you cancel is always a data-entry mistake,
  #     and catching it here is far cheaper than honouring it.
  def ordering_errors
    messages = []
    tiers.each_cons(2) do |earlier, later|
      if later.hours_before >= earlier.hours_before
        messages << "tiers must be ordered from the earliest cutoff to the latest, " \
                    "with no two the same"
      end
      if later.refund_percent > earlier.refund_percent
        messages << "the refund percentage cannot increase as the event gets closer"
      end
    end
    messages.uniq
  end
end
