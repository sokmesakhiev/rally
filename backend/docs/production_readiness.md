# Production Readiness for High-Concurrency Events

## Core Principle: Never Test Directly on Production

Testing concurrent registrations on production is dangerous because:
- Creates real registrations and processes payments
- Fills capacity for actual events
- Impacts real users' experience
- Triggers rate limits and affects legitimate traffic
- Cannot be easily rolled back

## Recommended Testing Strategy

### 1. Staging Environment (Primary Testing)

**Purpose**: Mirror production configuration for safe load testing

**Requirements**:
- Same infrastructure as production (server specs, database size)
- Production-like data (similar event counts, user base)
- Same environment variables and configuration
- Isolated payment gateway (sandbox mode)
- Same monitoring and logging setup

**Load Testing Process**:
```bash
# 1. Deploy to staging
kamal deploy staging

# 2. Run load tests against staging
API_BASE_URL=https://staging.rally.kh \
EVENT_ID=test-event-uuid \
NUM_USERS=500 \
RAMP_UP=30 \
bundle exec ruby spec/load_testing/concurrent_registration_load_test.rb

# 3. Monitor staging metrics
# - CPU, memory, database connections
# - Response times, error rates
# - Lock wait times, database performance
```

**Staging Load Test Scenarios**:
- **Baseline**: 50 concurrent users (normal load)
- **Peak Load**: 200 concurrent users (expected peak)
- **Stress Test**: 500+ concurrent users (extreme conditions)
- **Sustained Load**: 100 users/minute for 30 minutes

### 2. Production Monitoring (Read-Only)

**Purpose**: Verify production handles real traffic without interference

**Safe Production Tests**:
- Health check endpoints
- Read-only API calls (event listings, public data)
- Synthetic user journeys (browse events, view details)
- Database query performance monitoring
- Connection pool monitoring

**Never in Production**:
- Registration creation
- Payment processing
- Data modifications
- Capacity-affecting operations

### 3. Canary Deployment Strategy

**Purpose**: Gradual rollout with real traffic monitoring

**Process**:
1. Deploy new version to 10% of servers
2. Monitor metrics for 15-30 minutes
3. If metrics are healthy, expand to 50%
4. Monitor for another 15-30 minutes
5. If still healthy, roll out to 100%

**Monitoring During Canary**:
- Registration success rate
- Response time percentiles (p50, p95, p99)
- Error rates by endpoint
- Database lock wait times
- Memory and CPU usage
- Queue depths (SolidQueue)

**Rollback Triggers**:
- Error rate > 1%
- p95 response time > 2s
- Database lock wait time > 100ms
- Memory usage > 80%
- Any capacity enforcement failures

### 4. Production Readiness Checklist

#### Infrastructure
- [ ] Staging environment mirrors production specs
- [ ] Database has sufficient indexes for registration queries
- [ ] Connection pools sized for expected concurrency
- [ ] Load balancer configured for health checks
- [ ] Auto-scaling rules in place (if using cloud)
- [ ] CDN configured for static assets

#### Application
- [ ] Pessimistic locking implemented and tested
- [ ] Database transactions properly scoped
- [ ] Rate limiting configured (Rack::Attack)
- [ ] Error tracking (Sentry) configured
- [ ] Performance monitoring (APM) configured
- [ ] Logging includes request IDs for tracing

#### Testing
- [ ] Concurrency tests pass in CI
- [ ] Load tests pass on staging (200+ concurrent users)
- [ ] Database performance tests pass
- [ ] Payment gateway sandbox tested
- [ ] Failover scenarios tested (database restart, etc.)

#### Monitoring & Alerting
- [ ] Registration success rate > 99%
- [ ] Response time p95 < 1s
- [ ] Database lock wait time < 50ms
- [ ] Error rate < 0.5%
- [ ] Queue processing time < 5s
- [ ] Alerts configured for all thresholds

#### Documentation
- [ ] Runbook for high-concurrency events
- [ ] Emergency rollback procedures documented
- [ ] Capacity planning guidelines documented
- [ ] Monitoring dashboards created

### 5. High-Concurrency Event Runbook

**Pre-Event Preparation** (1-2 weeks before):
1. Run staging load tests with expected user count
2. Review and tune database indexes
3. Verify auto-scaling configuration
4. Test failover scenarios
5. Prepare emergency rollback plan
6. Set up enhanced monitoring dashboards

**Day of Event**:
1. Monitor baseline metrics 1 hour before registration opens
2. Have extra capacity ready (scale up if needed)
3. Ensure on-call engineer is available
4. Monitor registration success rate and response times
5. Watch for lock contention and database performance

**During Registration Surge**:
1. Monitor capacity enforcement (should never exceed limit)
2. Watch for error spikes
3. Check database connection pool usage
4. Monitor SolidQueue job processing
5. Be ready to scale up if needed

**Post-Event**:
1. Review performance metrics
2. Analyze any errors or slowdowns
3. Document lessons learned
4. Update load test scenarios based on actual traffic
5. Plan improvements for next event

### 6. Production Monitoring Setup

#### Key Metrics to Monitor

**Application Metrics**:
- Registration success rate
- Response time (p50, p95, p99)
- Error rate by endpoint
- Request rate per second
- Database query performance

**Database Metrics**:
- Connection pool usage
- Lock wait times
- Query performance
- Transaction duration
- Deadlock count

**Infrastructure Metrics**:
- CPU usage
- Memory usage
- Disk I/O
- Network throughput
- Load balancer health

**Business Metrics**:
- Active registrations per event
- Capacity utilization
- Payment success rate waitlist size

#### Alert Thresholds

**Critical Alerts** (immediate action):
- Registration success rate < 95%
- Error rate > 5%
- Database lock wait time > 200ms
- Memory usage > 90%
- Capacity enforcement failure detected

**Warning Alerts** (investigate soon):
- Registration success rate < 99%
- Error rate > 1%
- Response time p95 > 2s
- Database lock wait time > 100ms
- Memory usage > 80%

### 7. Load Testing Tools Comparison

**For Staging**:
- **Custom Ruby script**: Good for specific API testing
- **k6**: Modern, scriptable, good for HTTP load testing
- **Locust**: Python-based, distributed testing
- **JMeter**: Comprehensive but complex

**For Production Monitoring**:
- **Synthetic monitoring**: Pingdom, New Relic Synthetics
- **APM tools**: New Relic, Datadog, Sentry
- **Log analysis**: ELK Stack, CloudWatch Logs

### 8. Emergency Procedures

**If Issues Detected During High Load**:

1. **Immediate Actions**:
   - Check error logs and metrics
   - Identify bottleneck (database, application, infrastructure)
   - Scale up resources if possible
   - Consider rate limiting if overwhelmed

2. **Rollback if Needed**:
   ```bash
   # Rollback to previous version
   kamal rollback
   
   # Or scale down to reduce load
   kamal scale web=1
   ```

3. **Communication**:
   - Notify team of issues
   - Update status page if public-facing
   - Communicate with affected users if needed

### 9. Continuous Improvement

**After Each High-Load Event**:
1. Review metrics and identify bottlenecks
2. Update load test scenarios based on actual traffic patterns
3. Implement performance improvements
4. Update documentation and runbooks
5. Share lessons learned with team

**Regular Testing**:
- Monthly: Run load tests on staging
- Quarterly: Review and update infrastructure capacity
- Annually: Full disaster recovery test

## Conclusion

The key to handling high-concurrency events is:
1. **Never test on production** - use staging
2. **Comprehensive monitoring** - know when issues occur
3. **Gradual rollout** - canary deployments
4. **Preparation** - have runbooks and procedures ready
5. **Continuous improvement** - learn from each event

This approach ensures production readiness while protecting real users and data.
