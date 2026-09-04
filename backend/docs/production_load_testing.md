# Production Load Testing Guide (New Environment)

## When Safe to Test on Production

**Only test on production when:**
- Environment is NEW with NO real users
- Payment gateway is in SANDBOX/TEST mode
- You have a complete data cleanup plan
- You're using dedicated test events
- You can monitor closely during the test

## Pre-Test Checklist

### 1. Environment Verification
- [ ] Production has NO real users or real events
- [ ] Payment gateway (PayWay) is in SANDBOX/TEST mode
- [ ] Database backups are current and accessible
- [ ] Monitoring and alerting are configured
- [ ] You have database access for cleanup

### 2. Test Event Preparation
- [ ] Create dedicated test event (use provided script)
- [ ] Event is FREE (price_cents: 0) to avoid payment processing
- [ ] Event has high capacity (extra_large plan: 30,000)
- [ ] Event is clearly marked as test event in title/description
- [ ] Note the event ID for load testing

### 3. Load Test Preparation
- [ ] Install test dependencies: `bundle install`
- [ ] Review load test script safety checks
- [ ] Prepare environment variables
- [ ] Have monitoring dashboard ready
- [ ] Prepare rollback plan

## Testing Process

### Step 1: Create Test Event

```bash
cd backend
bundle exec ruby scripts/create_test_event.rb
```

This will:
- Create a test organization (if needed)
- Create a free test event with high capacity
- Output the event ID for load testing
- Require confirmation if running in production

**Output example:**
```
Creating test event for load testing...
Environment: production
==================================================
✓ Organization: Load Test Organization (load-test-org)
✓ Event created:
  ID: 550e8400-e29b-41d4-a716-446655440000
  Title: Load Test Event 20260903-145500
  Capacity: 1000
  Price: 0 cents
  Published: true

Use this event ID for load testing:
EVENT_ID=550e8400-e29b-41d4-a716-446655440000
```

### Step 2: Run Load Test

```bash
# Set environment variables
export API_BASE_URL=https://rally.kh
export EVENT_ID=<event-id-from-step-1>
export NUM_USERS=500
export RAMP_UP=30

# Run load test
bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

The script will:
- Detect production environment and show safety warning
- Require manual confirmation before proceeding
- Execute concurrent registration requests
- Monitor and report results
- Save detailed results to JSON file

**Safety confirmation:**
```
⚠️  WARNING: Testing against PRODUCTION environment
Ensure:
  1. Production has NO real users
  2. Payment gateway is in SANDBOX/TEST mode
  3. You have data cleanup plan ready
  4. You're using dedicated TEST events

Continue? (type 'yes' to confirm): yes
```

**Load test scenarios:**

**Baseline Test** (Normal load):
```bash
NUM_USERS=50 RAMP_UP=10 bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

**Peak Load Test** (Expected traffic):
```bash
NUM_USERS=200 RAMP_UP=30 bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

**Stress Test** (Extreme conditions):
```bash
NUM_USERS=500 RAMP_UP=60 bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb
```

### Step 3: Monitor During Test

While the load test runs, monitor:

**Application Metrics:**
- Registration success rate (should be near capacity limit)
- Response times (p50, p95, p99)
- Error rates
- Database connection pool usage

**Database Metrics:**
- Lock wait times (should be < 100ms)
- Query performance
- Transaction duration
- Connection count

**Infrastructure:**
- CPU usage
- Memory usage
- Network throughput

**Key Success Indicators:**
- ✅ Capacity never exceeded
- ✅ No duplicate registrations
- ✅ Response times < 2s (p95)
- ✅ Error rate < 1%
- ✅ Database lock wait time < 100ms

**Warning Signs:**
- ⚠️ Response time p95 > 2s
- ⚠️ Error rate > 1%
- ⚠️ Database lock wait time > 100ms
- ⚠️ Memory usage > 80%

**Critical Issues (Stop Test):**
- ❌ Capacity exceeded
- ❌ Error rate > 5%
- ❌ Database lock wait time > 200ms
- ❌ Memory usage > 90%

### Step 4: Review Results

The load test saves detailed results to a JSON file:
```
load_test_results_20260903_145500.json
```

**Review the results:**
```bash
cat load_test_results_20260903_145500.json | jq '.'
```

**Key metrics to check:**
- Total requests vs successful
- Success rate percentage
- Average response time
- Requests per second
- Failure breakdown by status code

### Step 5: Clean Up Test Data

```bash
# Dry run first to see what will be deleted
DRY_RUN=true TEST_EVENT_ID=<event-id> bundle exec ruby scripts/cleanup_test_data.rb

# If satisfied, run actual cleanup
TEST_EVENT_ID=<event-id> bundle exec ruby scripts/cleanup_test_data.rb
```

The cleanup script will:
- Show what data will be deleted
- Require confirmation in production
- Delete test event and all related data
- Optionally delete test users

**Cleanup options:**

**Clean up specific event:**
```bash
TEST_EVENT_ID=<event-id> bundle exec ruby scripts/cleanup_test_data.rb
```

**Clean up entire test organization:**
```bash
TEST_ORG_SLUG=load-test-org bundle exec ruby scripts/cleanup_test_data.rb
```

**Clean up test users as well:**
```bash
TEST_EVENT_ID=<event-id> CLEANUP_TEST_USERS=true bundle exec ruby scripts/cleanup_test_data.rb
```

## Verification After Cleanup

```bash
# Connect to production database
rails dbconsole

# Verify no test data remains
SELECT COUNT(*) FROM events WHERE title LIKE 'Load Test%';
SELECT COUNT(*) FROM registrations WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%test%@example.com');
SELECT COUNT(*) FROM organizations WHERE slug = 'load-test-org';
```

All counts should be 0.

## Emergency Procedures

### If Test Goes Wrong

**Immediate Actions:**
1. Stop the load test (Ctrl+C)
2. Check database for any capacity violations
3. Review error logs
4. Clean up test data immediately

**If Real Users Register During Test:**
1. Stop the test immediately
2. Identify real registrations (by email pattern)
3. Preserve real user data
4. Only clean up test data
5. Contact affected users if needed

### Rollback Plan

If the load test causes issues:

```bash
# 1. Stop any running load tests
# 2. Scale down if needed
kamal scale web=1

# 3. Clean up test data
TEST_EVENT_ID=<event-id> bundle exec ruby scripts/cleanup_test_data.rb

# 4. Restart services
kamal app restart

# 5. Verify system health
curl https://rally.kh/health
```

## Post-Test Analysis

### Performance Review

Document the results:
- Maximum concurrent users handled successfully
- Response times at different load levels
- Database performance under load
- Any bottlenecks identified
- Capacity enforcement verification

### Infrastructure Adjustments

Based on results, consider:
- Increasing database connection pool size
- Adding more web servers
- Optimizing database queries
- Adjusting SolidQueue worker count
- Implementing caching where appropriate

### Documentation Updates

Update:
- Production readiness documentation
- Load testing procedures
- Infrastructure capacity planning
- Monitoring thresholds

## Safety Reminders

**Before Each Test:**
1. Verify production has no real users
2. Confirm payment gateway is in sandbox mode
3. Create fresh test event
4. Have cleanup script ready
5. Start monitoring

**During Test:**
1. Watch metrics closely
2. Be ready to stop immediately
3. Monitor for any real user activity
4. Keep cleanup script handy

**After Test:**
1. Clean up all test data
2. Verify cleanup completeness
3. Document results
4. Update procedures based on findings

## When NOT to Test on Production

**Do NOT test on production if:**
- Real users exist in the system
- Real events are active
- Payment gateway is in live mode
- You cannot monitor during the test
- You don't have a cleanup plan
- Database backups are not current

In these cases, use a staging environment instead.

## Conclusion

Testing on a new production environment is safe when:
- No real users or data exist
- Payment processing is disabled/sandboxed
- You have complete cleanup procedures
- You monitor closely throughout
- You document results and learnings

This approach validates your infrastructure can handle real traffic while protecting actual users and data.
