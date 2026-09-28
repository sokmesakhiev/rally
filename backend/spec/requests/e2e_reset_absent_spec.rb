require "rails_helper"

# The most dangerous endpoint in this codebase, and the spec that keeps it
# caged.
#
# `POST /api/e2e/reset` truncates every table and re-seeds a scenario. It
# exists so Playwright — a separate process that cannot call
# `DatabaseCleaner.clean` — can put the system into a known state between
# journeys. See docs/e2e-testing-design.md D4.
#
# It is guarded three ways, and this file is the third:
#
#   1. `config/routes.rb` draws it inside `if Rails.env.e2e?`, so anywhere
#      else it is not merely forbidden — it is **not routable**.
#   2. The controller re-asserts the environment and aborts, so a refactor
#      that lifts the route out of that guard doesn't silently arm it.
#   3. This spec fails the moment either of those stops being true.
#
# Guards one and two are prose rules: someone has to keep believing them. This
# one is the executable version, which is the house pattern — see the PayWay
# serializer guard in spec/requests/impersonation_spec.rb.
RSpec.describe "The e2e reset endpoint", type: :request do
  it "is not in the route set outside the e2e environment" do
    e2e_routes = Rails.application.routes.routes
      .map { |route| route.path.spec.to_s }
      .grep(%r{/api/e2e})

    expect(e2e_routes).to be_empty,
      "POST /api/e2e/reset truncates the database. It is drawn inside " \
      "`if Rails.env.e2e?` for that reason, and something has moved it out: " \
      "#{e2e_routes.inspect}"
  end

  # The route-set assertion above is the precise one; this is the behavioural
  # counterpart, in case a future Rails version changes how routes are
  # enumerated but not how they're recognised.
  it "cannot be recognised as a path" do
    expect {
      Rails.application.routes.recognize_path("/api/e2e/reset", method: :post)
    }.to raise_error(ActionController::RoutingError)
  end

  # Cheap, and it documents the mechanism the other two depend on: if
  # `Rails.env.e2e?` were somehow true while running specs, the guard in
  # routes.rb would draw the route and the assertions above would be
  # meaningless rather than wrong.
  it "is guarded by an environment predicate that is false here" do
    expect(Rails.env.e2e?).to be(false)
    expect(Rails.env.test?).to be(true)
  end
end
