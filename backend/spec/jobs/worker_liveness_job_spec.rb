require "rails_helper"

RSpec.describe WorkerLivenessJob, type: :job do
  # The log line IS the product here — infrastructure/monitoring.tf's metric
  # filter matches on it, so its shape is a contract with Terraform rather than
  # a debugging convenience. Changing the `event` value silently disables the
  # alarm: the filter stops matching, the metric goes to zero, and (because the
  # alarm treats missing data as breaching) you get a page instead of silence.
  # That's the safe direction to fail, but it's still a false page.
  def captured_lines
    lines = []
    allow(Rails.logger).to receive(:info) { |msg| lines << msg }
    allow(Rails.logger).to receive(:warn) { |msg| lines << msg }
    described_class.perform_now
    lines
  end

  def liveness_payload
    line = captured_lines.find { |l| l.to_s.include?("solid_queue.liveness") }
    JSON.parse(line)
  end

  it "emits a single-line JSON object the metric filter can match" do
    payload = liveness_payload

    expect(payload["event"]).to eq("solid_queue.liveness")
  end

  it "carries the queue figures whoever opens the log group will want" do
    expect(liveness_payload.keys).to include(
      "ready", "scheduled", "failed", "oldest_ready_age_seconds", "processes"
    )
  end

  # Solid Queue's models live in Gemfile's :production group, so they don't
  # exist here at all. The job still has to emit its line — a liveness probe
  # that raises in any environment is one refactor away from raising in the
  # one that matters.
  it "runs without Solid Queue's models loaded" do
    expect { described_class.perform_now }.not_to raise_error
  end

  it "reports zeroes rather than nil when there is nothing to count" do
    payload = liveness_payload

    expect(payload["ready"]).to eq(0)
    expect(payload["oldest_ready_age_seconds"]).to eq(0)
  end

  describe "the backlog warning" do
    it "stays quiet at a normal queue depth" do
      expect(captured_lines.none? { |l| l.to_s.include?("solid_queue.backlog") }).to be(true)
    end

    # Logged, never raised. A job that raised here would stop emitting the
    # liveness line at exactly the moment the numbers became interesting —
    # turning "the worker is behind" into "the worker looks dead", which is a
    # different alarm and a different response.
    it "adds a second line once the backlog is deep, and still emits liveness" do
      allow_any_instance_of(described_class)
        .to receive(:ready_count).and_return(described_class::BACKLOG_WARNING_THRESHOLD)

      lines = captured_lines

      expect(lines.count { |l| l.to_s.include?("solid_queue.liveness") }).to eq(1)
      expect(lines.count { |l| l.to_s.include?("solid_queue.backlog") }).to eq(1)
    end
  end

  # If this schedule is lengthened without widening the alarm's evaluation
  # window in infrastructure/monitoring.tf, a healthy worker starts paging.
  # The two numbers are coupled and live in different repositories of truth,
  # so one of them gets a test.
  it "is scheduled every five minutes in production" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))
                   .dig("production", "worker_liveness")

    expect(schedule).to include("class" => "WorkerLivenessJob", "schedule" => "every 5 minutes")
  end
end
