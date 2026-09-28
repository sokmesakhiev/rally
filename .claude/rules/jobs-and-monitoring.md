# Background jobs (Solid Queue), cache, and the worker liveness alarm

Loaded on demand — see the trigger table in CLAUDE.md. Everything here is
hard-won detail about *why* the code is shaped the way it is; it was moved out
of CLAUDE.md verbatim, not rewritten.

### Backend: background jobs & cache (Solid Queue / Solid Cache)

`config/environments/production.rb` sets `config.active_job.queue_adapter = :solid_queue` and `config.cache_store = :solid_cache_store`, and `config/database.yml` has matching `queue`/`cache` roles (plus `cable`, unused — see below) pointed at separate databases on the same RDS instance as `primary` (same `url: ENV["DATABASE_URL"]`, just an overridden `database:` name — the standard Rails multi-database-on-one-server pattern). The `solid_queue`/`solid_cache` gems themselves live in Gemfile's `:production` group — development/test use the in-memory/null adapters instead (`config/environments/development.rb`, `test.rb`), so nothing extra is needed to run specs or `bin/rails server` locally.

- **Jobs run in their own ECS service**, not inside Puma. `aws_ecs_service.worker` runs the same image with `command = ["./bin/jobs"]`, no port mapping and no load balancer. `config/puma.rb` still has `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` for single-process local/dev use, but `SOLID_QUEUE_IN_PUMA` is deliberately **absent** from `infrastructure/ecs.tf` — setting it would put the supervisor back inside the web task alongside the separate one, so jobs would be processed twice over (harmlessly, since claims are uniquely indexed, but at double the cost and with the CPU contention this split exists to remove). The concrete driver was `Certificates::RenderPdf`, which shells out to LibreOffice and was doing that inside the process serving requests.

  Four things follow from there being two services:

  - **The web task owns migrations.** `bin/docker-entrypoint` runs `db:prepare` only when the command is `./bin/rails server` (overridable with `RUN_DB_PREPARE=true|false`). Both services boot from the same image and a deploy rolls both, so letting each migrate means N concurrent runs; Rails' advisory lock makes that safe but not free — the losers block, and on the web side that blocking is spent inside the health check's `startPeriod`. `scripts/deploy.sh` and `deploy-backend` in `.github/workflows/deploy.yml` therefore roll **web first, wait for stable, then worker**, so the schema is current before new job code runs. A job that does land in that window fails and is retried rather than lost.
  - **A backend deploy must redeploy both services.** Two `update-service --force-new-deployment` calls, not one. Miss the second and jobs keep running the previous image silently and indefinitely. CI needs the `ECS_WORKER_SERVICE` repo secret (the `ecs_worker_service_name` output); the step emits a `::warning::` rather than failing if it's unset, which is the one way this can go wrong quietly.
  - **The worker task has no `healthCheck`, on purpose.** The supervisor is PID 1, so if it dies the container exits and ECS replaces the task; if a forked child dies the supervisor replaces it. The gap a probe couldn't close either — supervisor alive but wedged — shows up only as `solid_queue_processes.last_heartbeat_at` going stale, which wants a CloudWatch alarm. One consequence: the deployment circuit breaker sees "reached RUNNING" as success, so it catches crash-on-boot but not a worker that boots and then fails every job.
  - **Recurring jobs moved with it.** `config/recurring.yml`'s hourly sweeps now run on the worker, so `ecs_worker_desired_count = 0` stops them — including `ReleaseAbandonedRegistrationsJob`, which is what frees capacity held by abandoned registrations. Scaling *up* is safe: `solid_queue_recurring_executions` is uniquely indexed on `(task_key, run_at)`, so N schedulers still enqueue each occurrence once, and `solid_queue_claimed_executions` is uniquely indexed on `job_id`, so N workers split jobs rather than duplicating them.

- **Terraform owns the task definitions again.** `aws_ecs_task_definition.app` used to carry `ignore_changes = [container_definitions]` and the service `ignore_changes = [task_definition]`, on the grounds that the deploy script managed them. It doesn't — both deploy paths only force a new deployment of the revision the service already points at, and `var.rails_image_tag` is the mutable `":latest"`, so container definitions never actually drifted. What the ignores did instead was make every environment change unappliable, which is why `SOLID_QUEUE_IN_PUMA` couldn't simply be deleted and why `ENABLE_PING_CHANNEL` was awkward to set. Both are gone; `desired_count` stays ignored on both services because that genuinely is adjusted out of band. **Read the plan on the next `terraform apply`** — if anyone hand-registered a revision while the ignores were in place, this is the apply that reverts it.
- `db:prepare` (run automatically on container boot, see `bin/docker-entrypoint`) creates and schema-loads all databases declared under `production:` in `database.yml`, including `cable`. That database sat empty and unused for a long time — `cable.yml` named `solid_cable` while neither the gem nor ActionCable itself was loaded — but as of the support-chat work it is live. See "Backend: ActionCable" below.
- `config/recurring.yml` schedules two hourly jobs in production: `SolidQueue::Job.clear_finished_in_batches`, and `ReleaseAbandonedRegistrationsJob`. The latter frees capacity held by paid-event registrations abandoned before payment — `RegistrationsController#create` writes the row *before* any KHQR payment succeeds, and `Registration::active` (what `Event#full?` counts) excludes only cancelled rows, so an unpaid registration holds a real slot indefinitely. See `Registrations::ReleaseAbandoned`: an hour's grace from the most recent payment attempt (or from the registration itself when the payment screen was never opened), re-checked under a row lock so a late ABA webhook can't get a paid registration cancelled. Free registrations are created with `payment_status: "paid"` and so can never match — there's a spec pinning that, because if the default changed this job would cancel every free registration on the platform.
- Related: the unique index on `registrations(event_id, user_id)` is **partial** (`WHERE deleted_at IS NULL`), and `Registration`'s uniqueness validation carries a matching `conditions:`. `#discard!` keeps the row for its payment history but the person is no longer registered, so they must be able to sign up again — this was a live bug before, reachable via `RegistrationsController#destroy`.
- `app/jobs/` holds the real jobs (certificates, event-change notifications, the ABA webhook processor, push delivery, and the sweep above); mailers additionally use `deliver_later`, which exercises the same adapter.

### Monitoring: the worker liveness alarm

`infrastructure/monitoring.tf` holds the stack's first alarms. They exist for
one gap: the worker task has no ECS `healthCheck` on purpose, so "supervisor
alive but not doing work" is invisible from the ECS side — and that became
load-bearing when certificate generation moved onto the worker.

- **The signal is a log line, not `solid_queue_processes.last_heartbeat_at`.**
  Two reasons, and the second is the real one. Practically, that column is in
  Postgres and CloudWatch can't read Postgres — bridging it needs a VPC Lambda
  or a reporter thread in the *web* task, since the worker can't report on
  itself and a recurring job is the very thing being tested. Substantively,
  **the heartbeat is written by its own thread and says nothing about whether
  jobs run**: a worker wedged on a stuck LibreOffice render keeps its heartbeat
  perfectly fresh. `WorkerLivenessJob` runs every 5 minutes and logs one JSON
  line, so the line appearing proves scheduler → dispatcher → claim → execute
  all work.
- **The metric filter matches the JSON field** (`{ $.event = "solid_queue.liveness" }`),
  not a substring, so the string appearing inside a stack trace can't forge an
  "everything is fine". `default_value = 0` makes an empty period report zero
  rather than no-data, which is what makes the alarm's own history honest.
- **`treat_missing_data = "breaching"` on liveness, `"missing"` on the ECS task
  count.** Opposite settings, deliberately: a worker that stopped logging and a
  log pipeline that stopped delivering are indistinguishable and both mean "you
  don't know if jobs run", but Container Insights legitimately stops publishing
  for a service scaled to zero, where `breaching` would page forever.
- **15 minutes = three expected lines.** One missed period is a deploy severing
  the worker mid-schedule; three is not. **`config/recurring.yml`'s
  `worker_liveness` schedule and this window are coupled across two
  repositories of truth**, so a spec pins the schedule — lengthening it without
  widening the window turns a healthy worker into a page.
- **A deep backlog logs a second line, it never raises.** A liveness probe that
  raised when the numbers got interesting would turn "the worker is behind"
  into "the worker looks dead" — different alarm, different response.
- **`alarm_email` is a variable and defaults to empty**, so the topic and alarms
  exist with nothing subscribed. Worth knowing: an email subscription sits in
  `PendingConfirmation` until the link is clicked and **`terraform apply`
  reports success either way** — `terraform output alarm_subscription_check`
  prints the command that distinguishes configured from working. It currently
  points at the account owner's own address; move it to a shared alias the day
  a second person is on call.
- **Deploy the backend *before* applying the liveness alarm.** The alarm treats
  missing data as breaching, and `WorkerLivenessJob` only exists once the image
  carrying it is running. Apply first and the alarm goes to ALARM about fifteen
  minutes later and stays there — a false page on day one, which is the fastest
  way to teach yourself to ignore it. Order: deploy backend → confirm the line
  is flowing → `terraform apply`. The check is:

  ```
  aws logs tail /ecs/rally-production --since 15m \
    --filter-pattern '{ $.event = "solid_queue.liveness" }'
  ```

  `tail` is the subcommand that takes a human `--since`; `filter-log-events`
  does not, and wants `--start-time` in epoch *milliseconds* instead
  (`--start-time $(( ($(date +%s) - 900) * 1000 ))`). Expect roughly three
  lines per fifteen minutes. **No output means don't apply yet** — either the
  worker hasn't got the image or it isn't running jobs, and both are exactly
  what the alarm is for.
- **A missing `ECS_WORKER_SERVICE` secret now fails the deploy** rather than
  emitting a `::warning::` and exiting 0. That step is the only path by which
  `WorkerLivenessJob` reaches production, so skipping it means the alarm fires
  forever against a deploy that reported success — and the old `exit 0` also
  let the "✅ Rally backend deployed" Telegram message go out. Failing routes
  to the `if: failure()` notification instead, so the channel anyone actually
  reads says what really happened.
