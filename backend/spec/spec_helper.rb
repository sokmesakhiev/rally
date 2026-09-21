# Coverage, opt-in via COVERAGE=1.
#
# **This block must stay at the very top of this file.** `.rspec` requires
# spec_helper before anything else, and rails_helper loads `config/environment`
# on its third line — SimpleCov only sees files required *after* it starts, so
# starting it any later silently reports most of `app/` as uncovered.
#
# Opt-in rather than always-on, because the common case is running one spec
# file: an unconditional report would announce "4% covered" after every
# focused run, which is both meaningless and alarming. There is deliberately
# **no `minimum_coverage` threshold** — pick one once the real number is known,
# not before, or the first run fails the suite for no reason anyone chose.
if ENV["COVERAGE"]
  require "simplecov"

  SimpleCov.start "rails" do
    # Line coverage alone overstates: a `case` with four branches counts as
    # covered when one of them runs. The deck quotes this number, so measure
    # the honest one too.
    enable_coverage :branch

    add_filter "/spec/"
    # Unused default Minitest scaffolding — see CLAUDE.md. Counting it would
    # drag the figure down for code nobody is expected to test.
    add_filter "/test/"
    add_filter "/config/"
    add_filter "/db/"
    add_filter "/vendor/"

    # Groups mirror the app's own structure so the HTML report is navigable
    # rather than one flat list of 200 files.
    add_group "Models",          "app/models"
    add_group "Controllers",     "app/controllers"
    add_group "Services",        "app/services"
    add_group "Jobs",            "app/jobs"
    add_group "Mailers",         "app/mailers"
    add_group "Channels",        "app/channels"
    add_group "Request schemas", "app/request_schemas"
    add_group "Library",         "lib"
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed
end
