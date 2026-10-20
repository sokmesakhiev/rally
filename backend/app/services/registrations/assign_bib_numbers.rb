# frozen_string_literal: true

module Registrations
  # Assigns bib numbers to everyone who doesn't have one.
  #
  # **Fills gaps, never reassigns.** A bib that already exists is left exactly
  # as it is, whether an organizer typed it or an earlier run produced it, and
  # whether or not the entry holding it is still live. That last part is the
  # one that matters: `registrations`' unique index on `(event_id, bib_number)`
  # is deliberately **not** scoped to kept rows, because a withdrawn runner's
  # result and certificate still reference their number. Handing 1042 to
  # somebody else because its original owner pulled out would silently attach
  # one person's finishing time to another's certificate. So discarded rows'
  # numbers are read as taken here too, and freeing one stays an explicit edit.
  #
  # Running this twice is therefore safe and is expected: an organizer assigns
  # once when entries close, then again after the inevitable late additions.
  #
  # **Numbering is per event type**, from that type's own range, because a
  # multi-distance race is numbered by distance — marshals read the range to
  # know which course someone is on. Registrations with no event type at all
  # (single-distance events, which never create one) use the event's own range;
  # the two never compete, since which applies is decided by what the
  # registration has rather than by a precedence rule.
  #
  # **Order is registration order**, oldest first, tie-broken by id so the
  # result is identical on a re-run. Worth knowing out loud, because it means
  # the number on someone's chest encodes roughly when they signed up.
  class AssignBibNumbers
    Result = Struct.new(:ok?, :groups, :assigned_count, :error, :code, keyword_init: true)

    # One per event type, plus one for the untyped registrations when there are
    # any. `first_number`/`last_number` are what the preview shows; on a real
    # run they are what was actually issued.
    #
    # `source` is the EventType (or the Event, for untyped registrations) the
    # range is read from. Carried on the struct rather than looked up on demand
    # so that formatting a number is not a database query per participant —
    # this runs over the whole field of a 30,000-entry event.
    Group = Struct.new(
      :key, :label, :configured, :pending_count, :first_number, :last_number,
      :skipped_count, :warning, :source,
      keyword_init: true,
    )

    def self.call(...) = new(...).call

    def initialize(event:, dry_run: false)
      @event = event
      @dry_run = dry_run
    end

    def call
      # The whole assignment runs under one row lock on the event. Two
      # organizers pressing the button at the same moment is rare but entirely
      # possible on race week, and without this they would race for the same
      # numbers — the unique index would reject the loser mid-run, leaving half
      # the field numbered and an error nobody can reproduce.
      @event.with_lock do
        taken = taken_numbers
        groups = build_groups

        assigned = 0
        groups.each do |group, registrations|
          next unless group.configured

          number = group_start(group)
          issued = []

          registrations.each do |registration|
            number, formatted = next_free(number, group, taken)
            issued << formatted
            taken << formatted
            unless @dry_run
              # update_column: the bib is the only thing changing, and a
              # registration carries validations (capacity, suspension,
              # closing) written for *creation*. Re-running them here could
              # refuse to number a perfectly valid entry because the event has
              # since closed — which is exactly when bibs get assigned.
              registration.update_column(:bib_number, formatted)
            end
            number += 1
            assigned += 1
          end

          group.first_number = issued.first
          group.last_number = issued.last
        end

        annotate_overruns(groups.keys)

        Result.new(ok?: true, groups: groups.keys, assigned_count: assigned)
      end
    end

    private

    # Every number already spoken for in this event, live or not. Read once and
    # carried in memory for the rest of the run — the alternative is a query
    # per candidate, and a 30,000-entry event is precisely the one that would
    # time out.
    def taken_numbers
      @event.registrations.where.not(bib_number: nil).pluck(:bib_number).to_set
    end

    # { Group => [registrations needing a number, in order] }
    def build_groups
      pending = @event.registrations.kept
        .where(bib_number: nil)
        .includes(:event_types)
        .order(:created_at, :id)
        .to_a

      types = @event.event_types.order(:position, :created_at).to_a
      buckets = {}

      types.each do |type|
        buckets[type.id] = [ group_for_type(type), [] ]
      end
      untyped = [ Group.new(key: nil, label: "No event type", configured: @event.bib_start.present?,
                            pending_count: 0, skipped_count: 0, source: @event), [] ]

      pending.each do |registration|
        type = primary_type(registration, types)
        bucket = type ? buckets[type.id] : untyped
        bucket[1] << registration
      end

      result = {}
      buckets.each_value do |(group, regs)|
        group.pending_count = regs.size
        group.skipped_count = regs.size unless group.configured
        result[group] = regs
      end
      # Only surfaced when it has somebody in it — an event with event types
      # should not show a phantom "No event type" row in the preview.
      if untyped[1].any?
        untyped[0].pending_count = untyped[1].size
        untyped[0].skipped_count = untyped[1].size unless untyped[0].configured
        result[untyped[0]] = untyped[1]
      end
      result
    end

    # A participant may enter more than one distance in a single registration
    # (a 5K and a 10K on the same day happens). They wear one bib, so the
    # **lowest-positioned** type they entered decides the range — position is
    # the order the organizer arranged the types in, so this is their call
    # rather than an arbitrary one, and it is stable across re-runs.
    def primary_type(registration, types)
      ids = registration.event_types.map(&:id)
      return nil if ids.empty?

      types.find { |type| ids.include?(type.id) }
    end

    def group_for_type(type)
      Group.new(
        key: type.id,
        label: type.name,
        configured: type.bib_start.present?,
        pending_count: 0,
        skipped_count: 0,
        source: type,
      )
    end

    def group_start(group) = group.source.bib_start

    def group_format(group) = [ group.source.bib_prefix.to_s, group.source.bib_padding.to_i ]

    # Walks forward past anything already taken. The skip is what makes a
    # re-run idempotent and what lets an organizer hand-pick 1001 for a VIP
    # before pressing the button.
    def next_free(number, group, taken)
      prefix, padding = group_format(group)
      loop do
        formatted = "#{prefix}#{number.to_s.rjust(padding, '0')}"
        return [ number, formatted ] unless taken.include?(formatted)

        number += 1
      end
    end

    # A real race-day failure, caught in the preview rather than at the
    # printer: the 10K starting at 2000 with 1,400 entries runs into the half
    # marathon's 3000 only if someone counts. The unique index guarantees no
    # two runners share a number, so this is never *incorrect* — it is just
    # that the half's numbers would start part-way through its range with no
    # explanation. Warn, never refuse; the organizer may know something the
    # arithmetic doesn't.
    def annotate_overruns(groups)
      configured = groups.select { |g| g.configured && g.last_number }
      starts = groups.select(&:configured).map { |g| [ g, group_start(g) ] }.to_h

      configured.each do |group|
        last = numeric_part(group.last_number, group)
        next unless last

        clash = starts.find do |other, other_start|
          other != group && other_start && other_start <= last && (starts[group] || 0) < other_start
        end
        next unless clash

        group.warning = "reaches #{group.last_number}, which runs into " \
                        "#{clash[0].label} starting at #{clash[1]}"
      end
    end

    def numeric_part(formatted, group)
      prefix, _padding = group_format(group)
      formatted.to_s.delete_prefix(prefix).to_i
    end
  end
end
