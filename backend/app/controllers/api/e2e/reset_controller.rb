module Api
  module E2e
    # Puts the system into a known state for one Playwright journey.
    #
    # Playwright is a separate process from Rails; it cannot call
    # DatabaseCleaner, so the reset has to be reachable over HTTP. That makes
    # this the most dangerous endpoint in the codebase, and the three guards
    # around it are described in docs/e2e-testing-design.md D4 — the route
    # block in config/routes.rb, BaseController#ensure_e2e_environment!, and
    # spec/requests/e2e_reset_absent_spec.rb.
    #
    #   POST /api/e2e/reset    { "scenario": "participant" }
    #
    # Returns whatever the scenario builder produced — ids, emails, the
    # password — so a test never has to scrape setup data out of the page it
    # is about to assert on.
    class ResetController < BaseController
      # Tables the reset must not touch. `schema_migrations` and
      # `ar_internal_metadata` are Rails' own bookkeeping; truncating them
      # would leave the database structurally intact but convinced it had
      # never been migrated, and the next `db:prepare` would try to run every
      # migration again against a full schema.
      PROTECTED_TABLES = %w[schema_migrations ar_internal_metadata].freeze

      def create
        # Required here rather than at the top of the file, and that is not
        # an oversight. `app/controllers/` is eager-loaded in production, so a
        # top-level require would pull db/e2e_scenarios.rb — a file whose job
        # is creating accounts with a published password — into every
        # deployed process. Loading it only inside an action that cannot be
        # reached outside the `e2e` environment keeps it genuinely absent
        # from production rather than merely unused.
        require Rails.root.join("db/e2e_scenarios")

        scenario = params[:scenario].presence || "empty"

        truncate_everything!
        purge_uploads!
        clear_process_state!

        data = E2eScenarios.build!(scenario)

        render json: { scenario: scenario, **data }, status: :ok
      rescue E2eScenarios::UnknownScenario => e
        # 422 rather than 404: the route exists and the request was
        # well-formed, the world it asked for isn't defined. A test that
        # typos a scenario name should read the reason, not hunt for a
        # missing route.
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # `connection_pool.with_connection`, not `ActiveRecord::Base.connection`
      # — the latter is on its way out in Rails 8 and leases a connection for
      # the rest of the thread's life, which is the wrong shape for a request
      # that then hands the thread back to Puma.
      def truncate_everything!
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          tables = connection.tables - PROTECTED_TABLES
          next if tables.empty?

          # Rails' own truncate_tables, which wraps the statements in
          # disable_referential_integrity so foreign keys don't dictate an
          # ordering. Note it does **not** restart identity sequences, and
          # that is worth keeping: ids never repeat across resets, so a stale
          # id held over from a previous journey fails to find its record
          # instead of quietly matching a different one.
          connection.truncate_tables(*tables)
        end
      end

      # Active Storage writes to tmp/e2e_storage in this environment (see
      # config/storage.yml). Truncating `active_storage_blobs` drops the rows
      # and leaves the files, so without this the directory grows for the
      # life of the checkout — and a test asserting "this event has no
      # banner" could be looking at a file from three runs ago.
      #
      # Deletes the *contents*, not the directory: Active Storage's Disk
      # service resolves its root once, and removing the directory out from
      # under a running server produces an Errno::ENOENT on the next upload.
      def purge_uploads!
        service = ActiveStorage::Blob.service
        return unless service.respond_to?(:root)

        root = Pathname.new(service.root.to_s)
        return unless root.to_s.include?("e2e")

        FileUtils.rm_rf(root.children) if root.exist?
      rescue SystemCallError => e
        # Not fatal. A stale upload is a much smaller problem than a reset
        # that refuses to work, and silence here would be worse than either.
        Rails.logger.warn("[e2e reset] could not purge uploads: #{e.class} #{e.message}")
      end

      # State that lives in this process rather than in the database, and so
      # survives a truncation.
      def clear_process_state!
        # rack-attack is enabled outside the test environment, which includes
        # this one — deliberately, because leaving it out of the stack would
        # mean the suite exercises a middleware arrangement production never
        # runs. But its counters are keyed on 127.0.0.1, and every journey
        # shares that address: six sign-ins across six journeys would trip
        # `signin/ip/burst` (6 per 20 seconds) on a suite that is behaving
        # perfectly. Clearing between journeys keeps the middleware real and
        # the limits per-journey.
        #
        # Worth knowing: this means the suite cannot catch a throttle that is
        # too *tight* for a single journey's legitimate traffic. If a journey
        # ever starts getting 429s, that is a finding about the limit, not a
        # reason to widen this.
        Rack::Attack.cache.store.clear if defined?(Rack::Attack) && Rack::Attack.cache.store.respond_to?(:clear)

        # Mail accumulates in memory under the :test delivery method
        # (config/environments/e2e.rb) and would otherwise carry across
        # journeys.
        ActionMailer::Base.deliveries.clear if ActionMailer::Base.respond_to?(:deliveries)
      end
    end
  end
end
