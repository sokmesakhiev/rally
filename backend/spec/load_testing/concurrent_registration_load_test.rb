#!/usr/bin/env ruby
# Load test script for concurrent event registrations
# Usage: bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
#
# PRODUCTION TESTING SAFEGUARDS:
# - Only use on production with NO real users
# - Ensure payment gateway is in TEST/SANDBOX mode
# - Use dedicated test events
# - Have data cleanup plan ready
# - Monitor closely during test

require 'net/http'
require 'uri'
require 'json'
require 'concurrent'
require 'benchmark'

# Configuration
BASE_URL = ENV['API_BASE_URL'] || 'http://localhost:3001'
EVENT_ID = ENV['EVENT_ID'] || 'test-event-id'
NUM_CONCURRENT_USERS = ENV['NUM_USERS']&.to_i || 100
RAMP_UP_SECONDS = ENV['RAMP_UP']&.to_i || 5

# Safety checks
if BASE_URL.include?('production') || BASE_URL.include?('rally.kh')
  puts "⚠️  WARNING: Testing against PRODUCTION environment"
  puts "Ensure:"
  puts "  1. Production has NO real users"
  puts "  2. Payment gateway is in SANDBOX/TEST mode"
  puts "  3. You have data cleanup plan ready"
  puts "  4. You're using dedicated TEST events"
  print "\nContinue? (type 'yes' to confirm): "
  confirmation = gets.chomp
  exit(1) unless confirmation.downcase == 'yes'
end

class ConcurrentRegistrationLoadTest
  def initialize(event_id, num_users, ramp_up)
    @event_id = event_id
    @num_users = num_users
    @ramp_up = ramp_up
    @results = Concurrent::Array.new
    @mutex = Mutex.new
  end

  def run
    puts "Starting concurrent registration load test..."
    puts "Event ID: #{@event_id}"
    puts "API Base URL: #{BASE_URL}"
    puts "Concurrent users: #{@num_users}"
    puts "Ramp-up time: #{@ramp_up} seconds"
    puts "=" * 50

    # Test connectivity first
    test_connectivity

    time = Benchmark.realtime do
      execute_concurrent_requests
    end

    print_results(time)
  end

  private

  def test_connectivity
    puts "\nTesting connectivity to #{BASE_URL}..."
    begin
      uri = URI("#{BASE_URL}/api/v1/events/#{@event_id}")

      http = Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == 'https',
        verify_mode: OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 10,
        read_timeout: 10
      )

      # Try a simple GET request to test connectivity
      request = Net::HTTP::Get.new(uri.path)
      response = http.request(request)
      http.finish

      puts "✓ Connectivity test passed (Status: #{response.code})"
    rescue => e
      puts "✗ Connectivity test failed: #{e.class.name}: #{e.message}"
      puts "Please check:"
      puts "  - API_BASE_URL is correct"
      puts "  - Server is running"
      puts "  - Network/firewall allows connections"
      puts "  - Event ID exists"
      exit(1)
    end
  end

  def execute_concurrent_requests
    thread_pool = Concurrent::ThreadPoolExecutor.new(
      min_threads: 1,
      max_threads: @num_users,
      max_queue: 0,
      fallback_policy: :caller_runs
    )

    @num_users.times do |i|
      delay = (i.to_f / @num_users) * @ramp_up
      thread_pool.post do
        sleep(delay)
        execute_request(i)
      end
    end

    thread_pool.shutdown
    thread_pool.wait_for_termination(300) # 5 minute timeout
  end

  def execute_request(user_index)
    start_time = Time.now
    user = create_test_user(user_index)

    begin
      uri = URI("#{BASE_URL}/api/v1/events/#{@event_id}/registrations")

      # Debug: print URI info
      if user_index == 0
        @mutex.synchronize { puts "Target URI: #{uri}" }
        @mutex.synchronize { puts "Scheme: #{uri.scheme}, Host: #{uri.host}, Port: #{uri.port}" }
      end

      http = Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == 'https',
        verify_mode: OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 30,
        read_timeout: 30
      )

      request = Net::HTTP::Post.new(uri.path, { 'Content-Type' => 'application/json' })
      request.body = {
        guest: {
          name: "Test User #{user_index}",
          email: "test#{user_index}@example.com",
          phone: "+8551234567#{format('%02d', user_index % 100)}"
        }
      }.to_json

      response = http.request(request)
      http.finish
      duration = Time.now - start_time

      @mutex.synchronize do
        @results << {
          user_index: user_index,
          status: response.code.to_i,
          duration: duration,
          success: response.code.to_i == 201,
          body: response.body[0..500] # Limit body size to avoid memory issues
        }
      end
    rescue => e
      duration = Time.now - start_time
      @mutex.synchronize do
        @results << {
          user_index: user_index,
          status: 0,
          duration: duration,
          success: false,
          error: "#{e.class.name}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        }
      end
    end
  end

  def create_test_user(index)
    # In a real scenario, you'd create actual users or use existing ones
    # For load testing, we're using guest checkout
    nil
  end

  def print_results(total_time)
    successful = @results.select { |r| r[:success] }
    failed = @results.reject { |r| r[:success] }

    durations = @results.map { |r| r[:duration] }
    avg_duration = durations.sum / durations.size if durations.any?
    max_duration = durations.max
    min_duration = durations.min

    puts "\nResults:"
    puts "=" * 50
    puts "Total time: #{total_time.round(2)}s"
    puts "Total requests: #{@results.size}"
    puts "Successful: #{successful.size}"
    puts "Failed: #{failed.size}"
    puts "Success rate: #{(successful.size.to_f / @results.size * 100).round(2)}%"
    puts "\nResponse times:"
    puts "Average: #{avg_duration&.round(3)}s"
    puts "Min: #{min_duration&.round(3)}s"
    puts "Max: #{max_duration&.round(3)}s"
    puts "Requests/sec: #{@results.size / total_time}"

    if failed.any?
      puts "\nFailure breakdown:"
      failed.group_by { |f| f[:status] }.each do |status, failures|
        puts "  Status #{status}: #{failures.size}"
        # Show first few error messages
        failures.first(3).each do |failure|
          puts "    Error: #{failure[:body]}"
        end
      end
    end

    # Save detailed results
    save_results(successful, failed, total_time)
  end

  def save_results(successful, failed, total_time)
    results_data = {
      timestamp: Time.now.iso8601,
      event_id: @event_id,
      total_requests: @results.size,
      successful: successful.size,
      failed: failed.size,
      total_time: total_time,
      success_rate: (successful.size.to_f / @results.size * 100).round(2),
      requests_per_second: @results.size / total_time,
      results: @results
    }

    filename = "load_test_results_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    File.write(filename, JSON.pretty_generate(results_data))
    puts "\nDetailed results saved to: #{filename}"
  end
end

# Run the load test
if __FILE__ == $PROGRAM_NAME
  test = ConcurrentRegistrationLoadTest.new(EVENT_ID, NUM_CONCURRENT_USERS, RAMP_UP_SECONDS)
  test.run
end
