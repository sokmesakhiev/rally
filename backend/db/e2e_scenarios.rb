# The named worlds the Playwright suite resets into.
#
# **This file lives in db/ deliberately, outside every autoload and eager-load
# path.** It is not `lib/e2e/scenarios.rb`, which Zeitwerk would load in every
# environment including production. Nothing requires it except
# Api::E2e::ResetController, which only exists in the `e2e` environment, so
# code that creates users with a published password cannot be reached from a
# deployed process at all — not because it declines to run, but because it was
# never loaded.
#
# Design (docs/e2e-testing-design.md, D6): a test declares the world it needs
# rather than clicking through setup, **except for the journey under test**. A
# registration test registers through the UI; a check-in test seeds the
# registrations, because forty seconds of setup clicking makes a test slow and
# makes it fail for reasons that have nothing to do with check-in.
#
# Each builder returns a plain hash, rendered straight back to the test. Put
# ids and credentials in it — anything the test would otherwise have to
# scrape out of the DOM to know.
#
# **No FactoryBot here.** `factory_bot_rails` and `faker` are in the Gemfile's
# `:development, :test` group, so neither is loaded in this environment. That
# is a constraint worth keeping rather than working around: a scenario built
# from plain `create!` calls fails loudly when a model gains a required
# column, where a factory would quietly paper over it and let the suite drift
# away from what the app actually demands of a real record.
module E2eScenarios
  # Published on purpose: this is test data in a local-only database, and a
  # test that can't state the password it is typing is a test nobody can read.
  PASSWORD = "e2e-password-123".freeze

  class UnknownScenario < StandardError; end

  # Every name here must have a matching `when` in .build! — there is a spec
  # (spec/models/e2e_scenarios_spec.rb) that walks this list and builds each
  # one, so a name added here without a builder fails the suite rather than
  # failing a journey at 3am.
  def self.names
    %w[
      empty
      participant
      organizer
      draft_event
      paid_event
      full_event
      finished_event
      admin
    ]
  end

  def self.build!(name)
    case name.to_s
    when "empty"          then empty
    when "participant"    then participant
    when "organizer"      then organizer
    when "draft_event"    then draft_event
    when "paid_event"     then paid_event
    when "full_event"     then full_event
    when "finished_event" then finished_event
    when "admin"          then admin
    else
      raise UnknownScenario,
        "Unknown e2e scenario #{name.inspect}. Known: #{names.join(', ')}."
    end
  end

  # ── The worlds ───────────────────────────────────────────────────────────

  # Nothing but the truncation the caller already did. Useful for a journey
  # that creates its whole world through the UI — signing up, for instance.
  def self.empty
    { users: {} }
  end

  # One ordinary participant account, signed up and past the terms gate.
  def self.participant
    user = create_user!("participant@e2e.rally.test", display_name: "Dara Participant")
    { users: { participant: user_payload(user) } }
  end

  # An organizer with exactly one complete organization, and no events.
  #
  # **Exactly one organization, and that is load-bearing.** The create-event
  # form only renders the "Presented by" dropdown when there is more than one
  # (`organizations.length > 1`); with one it shows a label. Seeding two would
  # make every journey that creates an event have to operate a Radix select
  # for no reason connected to what it is testing.
  #
  # The organization is complete (logo, description, contact) because
  # EventPlanPaymentsController checks Organization#missing_identity_fields
  # before publishing. That gate is currently off by default behind an env
  # flag, so an incomplete organization would work today and break the suite
  # on the day someone turns it on — the sort of latent failure a seed should
  # not be carrying.
  #
  # Verified, so the paid-event paths are open. An unverified organizer is a
  # real and interesting case, but it is a *different* scenario, and one this
  # ticket doesn't have a journey for yet.
  def self.organizer
    user = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(user)

    { users: { organizer: user_payload(user) },
      organizations: { main: organization_payload(org) } }
  end

  # An organizer with an unpublished draft — no plan picked yet.
  #
  # The starting point for the paid-publish journey, which is about
  # plan → gateway → webhook → live. Creating the event is a different
  # journey's subject (see journey 1), so it is seeded here rather than
  # clicked through: D6's rule, and it takes forty seconds of form-filling
  # off a test that is trying to be about money.
  #
  # `plan` and `capacity` are nil, which is what makes the manage page offer
  # the plan grid. An event that already has a plan renders the
  # republish-under-the-same-plan path instead, which charges nothing and
  # would skip the entire journey.
  def self.draft_event
    organizer = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(organizer)

    event = Event.create!(
      creator: organizer, organization: org,
      title: "Mekong Century Ride",
      description: "Seeded by the end-to-end suite.",
      category: "cycling", location: "Phnom Penh",
      start_at: 3.weeks.from_now, end_at: 3.weeks.from_now + 8.hours,
      price_cents: 0, currency: "usd",
      is_published: false
    )

    {
      users: { organizer: user_payload(organizer) },
      organizations: { main: organization_payload(org) },
      events: { main: event_payload(event) }
    }
  end

  # An organizer with one published, **paid**, public event — plus a
  # participant to register for it. The starting point for the
  # register-and-pay journey.
  #
  # Paid rather than free, because a free registration is written with
  # `payment_status: "paid"` and never touches the gateway at all; a journey
  # against a free event would assert nothing about the half of registration
  # that handles money.
  def self.paid_event
    organizer = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(organizer)
    participant = create_user!("participant@e2e.rally.test", display_name: "Dara Participant")

    event = create_event!(
      organizer, org,
      title: "Sunrise 10K",
      plan: "free",
      capacity: Event::PLANS.fetch("free")[:capacity],
      price_cents: 2_500
    )

    {
      users: { organizer: user_payload(organizer), participant: user_payload(participant) },
      organizations: { main: organization_payload(org) },
      events: { main: event_payload(event) }
    }
  end

  # A published paid event with exactly one spot, already taken.
  #
  # Capacity 1 rather than "capacity 20 with 20 registrations": the event is
  # full either way, and the second version costs twenty inserts and twenty
  # user accounts to say the same thing. It also makes the *cancellation* in
  # the waitlist journey free up exactly one spot, which is the thing under
  # test.
  #
  # Paid (`price_cents`), because a free registration is created already-paid
  # and so can never exercise the payment side of promotion.
  def self.full_event
    organizer = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(organizer)
    holder = create_user!("holder@e2e.rally.test", display_name: "Rith Holder")
    waiter = create_user!("waiter@e2e.rally.test", display_name: "Bopha Waiter")

    event = create_event!(
      organizer, org,
      title: "Riverside Night Run",
      plan: "free",
      capacity: 1,
      price_cents: 2_500
    )

    registration = Registration.create!(
      event: event, user: holder,
      status: "confirmed", payment_status: "paid", amount_paid_cents: 2_500
    )

    {
      users: {
        organizer: user_payload(organizer),
        holder: user_payload(holder),
        waiter: user_payload(waiter)
      },
      organizations: { main: organization_payload(org) },
      events: { main: event_payload(event) },
      registrations: { holder: { id: registration.id, user_id: holder.id } }
    }
  end

  # An event that has already happened, with two paid registrations carrying
  # bib numbers. The starting point for the race-day journey (check-in, then
  # a results import).
  #
  # Bibs are set here rather than assigned through the UI because
  # `Results::ImportCsv` matches on bib first and email second, and the CSV
  # an organizer actually has comes out of a chip-timing system that knows
  # bibs and has never heard of anyone's email address. A race-day journey
  # that imported by email would be testing a path real organizers don't use.
  def self.finished_event
    organizer = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(organizer)

    event = create_event!(
      organizer, org,
      title: "Angkor Half Marathon",
      plan: "free",
      capacity: Event::PLANS.fetch("free")[:capacity],
      price_cents: 0,
      start_at: 2.weeks.ago,
      end_at: 2.weeks.ago + 6.hours
    )

    finishers = {
      finisher_one: [ "finisher-one@e2e.rally.test", "Chan Finisher", "A101" ],
      finisher_two: [ "finisher-two@e2e.rally.test", "Veasna Finisher", "A102" ]
    }.transform_values do |(email, name, bib)|
      user = create_user!(email, display_name: name)
      registration = Registration.create!(
        event: event, user: user, bib_number: bib,
        status: "confirmed", payment_status: "paid", amount_paid_cents: 0
      )
      { user: user, registration: registration, bib: bib }
    end

    {
      users: {
        organizer: user_payload(organizer),
        **finishers.transform_values { |f| user_payload(f[:user]) }
      },
      organizations: { main: organization_payload(org) },
      events: { main: event_payload(event) },
      registrations: finishers.transform_values do |f|
        { id: f[:registration].id, bib_number: f[:bib], email: f[:user].email }
      end
    }
  end

  # A staff admin plus a published event to moderate, and a participant who
  # can try to register for it after it's taken down.
  def self.admin
    staff = create_user!("admin@e2e.rally.test", display_name: "Sam Staff", admin: true)
    organizer = create_user!("organizer@e2e.rally.test", display_name: "Sokha Organizer", verified: true)
    org = create_organization!(organizer)
    participant = create_user!("participant@e2e.rally.test", display_name: "Dara Participant")

    event = create_event!(
      organizer, org,
      title: "Midnight Dice Fun Run",
      plan: "free",
      capacity: Event::PLANS.fetch("free")[:capacity],
      price_cents: 0
    )

    {
      users: {
        admin: user_payload(staff),
        organizer: user_payload(organizer),
        participant: user_payload(participant)
      },
      organizations: { main: organization_payload(org) },
      events: { main: event_payload(event) }
    }
  end

  # ── Builders ─────────────────────────────────────────────────────────────

  # `email_verified_at` is set because an unverified account is a different
  # scenario with different banners, not a neutral default. A seeded world
  # should look like an account somebody has actually been using; anything
  # unusual about it should be unusual on purpose.
  #
  # `terms_version` is stamped alongside `terms_accepted_at` because
  # AuthController#signup stamps both, and the pair is the point: the column
  # exists so a future ToS bump can tell "agreed to an old version" from
  # "never agreed to anything" (see TermsOfService). Seeding the timestamp
  # alone would manufacture a state real signup can't produce.
  def self.create_user!(email, display_name:, verified: false, admin: false)
    user = User.create!(
      email: email,
      password: PASSWORD,
      password_confirmation: PASSWORD,
      admin: admin,
      email_verified_at: Time.current,
      terms_accepted_at: Time.current,
      terms_version: TermsOfService::CURRENT_VERSION,
      verified_at: verified ? Time.current : nil
    )
    user.profile.update!(display_name: display_name)
    user
  end
  private_class_method :create_user!

  def self.create_organization!(owner, verified: true)
    Organization.create!(
      owner: owner,
      name: "Phnom Penh Runners",
      description: "A running club based in Phnom Penh.",
      contact_email: "hello@e2e.rally.test",
      logo_url: "https://example.invalid/logo.png",
      verified_at: verified ? Time.current : nil
    )
  end
  private_class_method :create_organization!

  def self.create_event!(creator, organization, title:, plan:, capacity:, price_cents:,
                         start_at: 2.weeks.from_now, end_at: nil)
    Event.create!(
      creator: creator,
      organization: organization,
      title: title,
      description: "Seeded by the end-to-end suite.",
      category: "running",
      location: "Phnom Penh",
      start_at: start_at,
      end_at: end_at || (start_at + 4.hours),
      price_cents: price_cents,
      currency: "usd",
      capacity: capacity,
      plan: plan,
      is_published: true
    )
  end
  private_class_method :create_event!

  # ── Wire shapes ──────────────────────────────────────────────────────────

  def self.user_payload(user)
    {
      id: user.id,
      email: user.email,
      password: PASSWORD,
      display_name: user.profile&.display_name
    }
  end
  private_class_method :user_payload

  def self.organization_payload(org)
    { id: org.id, name: org.name, slug: org.slug }
  end
  private_class_method :organization_payload

  # `url` rather than just `id` so a test navigates to what it was handed
  # instead of assembling a path — the one place the route shape is written
  # down is then this file, not six journeys.
  def self.event_payload(event)
    {
      id: event.id,
      title: event.title,
      url: "/events/#{event.id}",
      manage_url: "/dashboard/events/#{event.id}",
      price_cents: event.price_cents,
      capacity: event.capacity
    }
  end
  private_class_method :event_payload
end
