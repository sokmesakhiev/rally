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
module E2eScenarios
  # Published on purpose: this is test data in a local-only database, and a
  # test that can't state the password it is typing is a test nobody can read.
  PASSWORD = "e2e-password-123".freeze

  class UnknownScenario < StandardError; end

  # Phase 0 ships the two the smoke test needs. Phases 1 and 2 add the worlds
  # the six journeys want (an organizer with a draft event, a full race with a
  # waitlist, a finished event with results to import); each is one more entry
  # here and nothing else.
  def self.names
    %w[empty participant]
  end

  def self.build!(name)
    case name.to_s
    when "empty"       then empty
    when "participant" then participant
    else
      raise UnknownScenario,
        "Unknown e2e scenario #{name.inspect}. Known: #{names.join(', ')}."
    end
  end

  # Nothing but the truncation the caller already did. Useful for a journey
  # that creates its whole world through the UI — signing up, for instance.
  def self.empty
    { users: {} }
  end

  # One ordinary participant account, signed up and past the terms gate.
  #
  # `email_verified_at` is set because an unverified account is a different
  # scenario with different banners, not a neutral default —
  # `terms_accepted_at` likewise. A seeded world should look like an account
  # somebody has actually been using; anything unusual about it should be
  # unusual on purpose.
  #
  # `terms_version` is stamped alongside `terms_accepted_at` because
  # AuthController#signup stamps both, and the pair is the point: the column
  # exists so a future ToS bump can tell "agreed to an old version" from
  # "never agreed to anything" (see TermsOfService). Seeding the timestamp
  # alone would manufacture a state real signup can't produce.
  def self.participant
    user = User.create!(
      email: "participant@e2e.rally.test",
      password: PASSWORD,
      password_confirmation: PASSWORD,
      email_verified_at: Time.current,
      terms_accepted_at: Time.current,
      terms_version: TermsOfService::CURRENT_VERSION
    )
    user.profile.update!(display_name: "Dara Participant")

    { users: { participant: user_payload(user) } }
  end

  def self.user_payload(user)
    {
      id: user.id,
      email: user.email,
      password: PASSWORD,
      display_name: user.profile&.display_name
    }
  end
  private_class_method :user_payload
end
