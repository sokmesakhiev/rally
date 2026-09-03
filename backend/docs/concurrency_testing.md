# Concurrency Testing for Event Registration

## Overview

This document describes the concurrency testing strategy for Rally's event registration system, designed to ensure data integrity and capacity enforcement under heavy concurrent load.

## Problem Statement

When multiple users attempt to register for an event simultaneously, race conditions can occur that may:
- Exceed event capacity limits
- Create duplicate registrations
- Cause inconsistent database state
- Lead to poor user experience

## Current Implementation Analysis

### Registration Flow

1. **Controller Layer** (`RegistrationsController#create`)
   - Validates guest/user information
   - Wraps registration in a transaction
   - Creates registration record
   - Associates event types and survey answers

2. **Model Layer** (`Registration#event_not_full`)
   - Checks event capacity
   - Validates against active registrations
   - Uses pessimistic locking to prevent race conditions

### Identified Concurrency Points

1. **Capacity Check Race Condition**
   - Original: `event.registrations.active.count >= event.capacity`
   - Risk: Multiple concurrent requests could pass the check before any registration is created
   - Solution: Added pessimistic locking with `event.reload(lock: true)`

2. **Duplicate Registration**
   - Protected by database uniqueness constraint: `user_id + event_id`
   - Additional validation in model

3. **Event Type Capacity**
   - Similar race condition for event type limits
   - Requires separate locking strategy

## Testing Strategy

### 1. Unit-Level Concurrency Tests

**File**: `spec/requests/concurrent_registrations_spec.rb`

#### Test Cases

##### Capacity Limit Enforcement
```ruby
it "prevents exceeding capacity under concurrent load" do
  # 20 concurrent attempts for 5-capacity event
  # Verifies exactly 5 succeed, 15 fail with "full" error
end
```

##### Duplicate Registration Prevention
```ruby
it "prevents duplicate registrations under concurrent load" do
  # Same user attempts 10 concurrent registrations
  # Verifies only 1 succeeds
end
```

##### Event Type Capacity
```ruby
it "handles event type capacity correctly under concurrent load" do
  # Tests limited capacity event types
  # Verifies type-level capacity limits
end
```

##### Data Consistency Under High Load
```ruby
it "maintains data consistency with high concurrency" do
  # 200 concurrent registration attempts
  # Verifies final state consistency
  # Checks for duplicate user registrations
end
```

### 2. Database Locking Verification

#### Pessimistic Locking
- Added `event.reload(lock: true)` in `Registration#event_not_full`
- Ensures atomic capacity check and registration
- Prevents race conditions between read and write operations

#### Transaction Isolation
- Registration creation wrapped in transaction
- All related operations (event types, answers) atomic
- Rollback on any validation failure

### 3. Load Testing

**File**: `spec/load_testing/concurrent_registration_load_test.rb`

#### Usage
```bash
# Basic load test
bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb

# Custom configuration
API_BASE_URL=http://localhost:3001 \
EVENT_ID=event-uuid \
NUM_USERS=100 \
RAMP_UP=5 \
bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

#### Metrics Collected
- Total requests and success rate
- Response times (min, max, average)
- Requests per second
- Failure breakdown by status code
- Detailed JSON output for analysis

#### Load Test Scenarios
- **Light Load**: 10 concurrent users
- **Medium Load**: 50 concurrent users  
- **Heavy Load**: 100+ concurrent users
- **Stress Test**: 200+ concurrent users

## Implementation Changes

### 1. Database Locking

**File**: `app/models/registration.rb`

```ruby
def event_not_full
  return unless event&.capacity
  # Use pessimistic locking to prevent race conditions
  event.reload(lock: true)
  if event.registrations.active.count >= event.capacity
    errors.add(:base, :event_full, message: "This event is full")
  end
end
```

### 2. Test Dependencies

**File**: `Gemfile`

```ruby
group :test do
  gem "shoulda-matchers", "~> 8.0"
  gem "database_cleaner-active_record"
  gem "concurrent-ruby", "~> 1.2"  # Added for concurrency testing
end
```

## Running the Tests

### RSpec Concurrency Tests

```bash
# Run all concurrency tests
bundle exec rspec spec/requests/concurrent_registrations_spec.rb

# Run specific test
bundle exec rspec spec/requests/concurrent_registrations_spec.rb:23
```

### Load Testing

```bash
# Install dependencies
bundle install

# Run load test
bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

## Performance Considerations

### Pessimistic Locking Impact
- **Pros**: Guarantees data integrity, prevents race conditions
- **Cons**: Can create contention under very high load
- **Mitigation**: Keep lock duration short, only lock during critical section

### Alternative Approaches Considered

1. **Optimistic Locking**
   - Use version numbers or timestamps
   - Retry on conflict
   - Better for high contention scenarios
   - More complex implementation

2. **Queue-Based Registration**
   - Serialize all registrations through a queue
   - Eliminates race conditions
   - Adds latency
   - More complex architecture

3. **Redis Distributed Lock**
   - External locking mechanism
   - Works across multiple servers
   - Additional infrastructure dependency
   - Overkill for single-server deployment

## Monitoring and Alerts

### Key Metrics to Monitor
- Registration failure rate (especially "full" errors)
- Average registration time
- Database lock wait time
- Concurrent registration attempts

### Alert Thresholds
- Failure rate > 5%: Investigate capacity issues
- Average registration time > 2s: Performance degradation
- Lock wait time > 100ms: Contention issues

## Future Improvements

1. **Event Type Locking**
   - Add pessimistic locking for event type capacity checks
   - Similar pattern to event-level locking

2. **Waitlist Concurrency**
   - Test concurrent waitlist additions
   - Verify promotion logic under load

3. **Payment Concurrency**
   - Test concurrent payment processing
   - Verify payment state consistency

4. **Distributed Locking**
   - Consider Redis locks for multi-server deployments
   - Implement when scaling beyond single server

## Troubleshooting

### Common Issues

#### Test Failures
- **Issue**: Tests fail randomly
- **Solution**: Ensure proper test isolation, use DatabaseCleaner

#### Lock Timeouts
- **Issue**: Lock wait timeout errors
- **Solution**: Increase database lock timeout, optimize queries

#### Performance Degradation
- **Issue**: Slow response times under load
- **Solution**: Add database indexes, optimize queries, consider caching

## References

- Rails Guide: Pessimistic Locking
- PostgreSQL Documentation: Row-Level Locking
- Concurrent Ruby Gem Documentation
- Rack Attack for Rate Limiting

## Conclusion

The concurrency testing strategy ensures Rally's registration system maintains data integrity and enforces capacity limits even under heavy concurrent load. The combination of pessimistic locking, comprehensive test coverage, and load testing provides confidence in the system's reliability during high-traffic events.
