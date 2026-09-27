require "rails_helper"

# Every route under /api/v1/admin must resolve to a declared capability.
#
# `Admin::BaseController#authorize_staff_action!` looks the capability up with
# `ACTION_CAPABILITIES.fetch(action_name)`, so an action nobody declared
# raises `KeyError` — loud, which is the point, but loud *at request time*.
# This spec moves that failure to the suite, where it costs a minute instead
# of an incident.
#
# It is the executable half of docs/staff-roles-design.md §4's first bullet.
# The prose version ("remember to declare a capability when you add an admin
# action") is exactly the kind of rule this codebase has watched get violated
# — see `GenerateCertificatesJob`, which documented a schedule it wasn't on.
#
# Deliberately derived from the **route set** rather than from a hand-written
# list of controllers. A new admin controller wired into routes.rb is covered
# the moment it exists, with nobody having to remember this file.
RSpec.describe "Admin capability coverage", type: :request do
  # [[controller_class, action_name], …] for everything mounted under the
  # admin namespace.
  def admin_endpoints
    Rails.application.routes.routes.filter_map do |route|
      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller&.start_with?("api/v1/admin/")

      [ "#{controller}_controller".camelize.constantize, action ]
    end.uniq
  end

  it "mounts at least the endpoints we know about" do
    # A control. If the route-scraping above silently matched nothing, every
    # other example here would pass vacuously — which is the failure mode this
    # project has hit twice before, once against a 502 and once against a
    # missing JSON key.
    # Loose on purpose. There are 31 today; the number is here to catch a
    # scrape that matched nothing, not to pin a count that changes whenever
    # somebody adds a route.
    expect(admin_endpoints.size).to be >= 25
  end

  it "declares a capability for every admin action" do
    missing = admin_endpoints.reject do |controller, action|
      controller.const_defined?(:ACTION_CAPABILITIES) &&
        controller::ACTION_CAPABILITIES.key?(action)
    end

    expect(missing).to be_empty, lambda {
      lines = missing.map { |c, a| "  #{c.name}##{a}" }.join("\n")
      "These admin actions have no entry in their controller's " \
      "ACTION_CAPABILITIES, so they raise KeyError on every request:\n#{lines}\n\n" \
      "Add one — see StaffAuthorization::CAPABILITIES for the vocabulary."
    }
  end

  it "only names capabilities that actually exist" do
    unknown = admin_endpoints.filter_map do |controller, action|
      next unless controller.const_defined?(:ACTION_CAPABILITIES)

      capability = controller::ACTION_CAPABILITIES[action]
      next if capability.nil? || StaffAuthorization::CAPABILITIES.key?(capability)

      "#{controller.name}##{action} → #{capability.inspect}"
    end

    # A typo here is worse than a missing entry: `fetch` in
    # StaffAuthorization#staff_permits? raises, so the endpoint 500s for
    # everyone including admins rather than merely denying someone.
    expect(unknown).to be_empty,
      "Unknown capabilities:\n  #{unknown.join("\n  ")}"
  end

  it "grants every declared capability to admin" do
    # Phase 1's contract: the mechanism changed, the answer did not. If any
    # capability omits :admin, somebody has narrowed an existing power while
    # claiming not to have.
    not_granted = StaffAuthorization::CAPABILITIES.reject { |_, roles| roles.include?(:admin) }

    expect(not_granted.keys).to be_empty,
      "Admin lost access to: #{not_granted.keys.join(', ')}"
  end

  it "uses only roles that User declares" do
    known = User::STAFF_ROLES.map(&:to_sym)
    stray = StaffAuthorization::CAPABILITIES
      .values.flatten.uniq
      .reject { |role| known.include?(role) }

    expect(stray).to be_empty, "Unknown staff roles in the matrix: #{stray.inspect}"
  end
end
