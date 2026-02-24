---
summary: "Thread ID leakage in error messages and logs"
title: "Thread ID Leakage"
---

# Thread ID Leakage

**Issue**: #18528

Thread IDs, conversation IDs, and session identifiers can leak through error messages, logs, and API responses, potentially exposing internal routing information or enabling unauthorized access to conversations.

## What is Thread ID Leakage?

**Thread ID:** Internal identifier for conversation context (Discord thread, Telegram chat, session ID)

**Leakage:** Exposing these IDs where they shouldn't appear:

- User-facing error messages
- Public API responses
- Client-side logs
- Stack traces sent to users
- Debug output in production
- External webhooks

## Security Impact

### 1. Conversation Enumeration

**Attack:** Use leaked thread IDs to enumerate other conversations

```bash
# If error exposes: "thread_12345"
# Attacker tries:
curl -H "Authorization: Bearer token" \
  https://openclaw.example.com/api/threads/12346
curl -H "Authorization: Bearer token" \
  https://openclaw.example.com/api/threads/12347
# Sequential scanning to find accessible threads
```

**Impact:** Access to conversations not owned by attacker

### 2. Cross-Session Contamination

**Attack:** Inject thread ID into API request to access different session

```bash
# Normal request:
POST /api/chat
{"message": "Hello", "threadId": "my-thread"}

# With leaked thread ID:
POST /api/chat
{"message": "Hello", "threadId": "leaked-admin-thread"}
```

**Impact:** Messages sent to wrong conversation, data leakage

### 3. Replay Attacks

**Attack:** Replay thread ID to resume closed session

```bash
# User's session expired, but error message leaked thread ID
# Attacker reuses thread ID:
POST /api/chat
{"message": "Extract secrets", "threadId": "expired-session-id"}
```

**Impact:** Unauthorized session resumption

## Common Leakage Vectors

### Vector 1: Error Messages

**Vulnerable code:**

```typescript
// ❌ Exposes internal thread ID to user
throw new Error(`Thread ${threadId} not found`);
```

**User sees:**

```
Error: Thread thread_a8f3j9dk2l not found
```

**Fix:**

```typescript
// ✅ Generic message, log details internally
logger.error(`Thread not found`, { threadId });
throw new Error(`Conversation not found`);
```

### Vector 2: API Responses

**Vulnerable API:**

```json
// ❌ Response includes internal IDs
{
  "error": "Rate limit exceeded",
  "details": {
    "threadId": "thread_internal_12345",
    "userId": "user_8362",
    "retryAfter": 60
  }
}
```

**Fix:**

```json
// ✅ No internal IDs exposed
{
  "error": "Rate limit exceeded",
  "retryAfter": 60
}
```

### Vector 3: Stack Traces

**Vulnerable:**

```typescript
// ❌ Unhandled exception exposes stack with thread ID
async function processMessage(threadId: string, message: string) {
  const thread = await getThread(threadId); // throws if not found
  // Stack trace includes threadId parameter
}
```

**User sees:**

```
Error: Cannot read property 'messages' of undefined
  at processMessage (agent.ts:42:15)
  at threadId: "internal_thread_abc123"
```

**Fix:**

```typescript
// ✅ Catch and sanitize errors before sending to user
async function processMessage(threadId: string, message: string) {
  try {
    const thread = await getThread(threadId);
    // ...
  } catch (error) {
    logger.error("Message processing failed", { threadId, error });
    throw new Error("Unable to process message");
  }
}
```

### Vector 4: Webhook Payloads

**Vulnerable webhook:**

```json
// ❌ Webhook to external service includes internal IDs
POST https://external-analytics.com/events
{
  "event": "message_sent",
  "threadId": "internal_session_xyz",
  "userId": "user_4821",
  "message": "Hello"
}
```

**Fix:**

```json
// ✅ Use opaque identifiers or hash internal IDs
POST https://external-analytics.com/events
{
  "event": "message_sent",
  "sessionHash": "a3f8b2c1...",
  "message": "Hello"
}
```

### Vector 5: Client-Side Logs

**Vulnerable:**

```typescript
// ❌ Console logs in production
console.log("Thread loaded:", threadId);
// User opens DevTools → sees internal thread ID
```

**Fix:**

```typescript
// ✅ Conditional logging, only in development
if (process.env.NODE_ENV === "development") {
  console.log("Thread loaded:", threadId);
}
```

## Detection Methods

### Method 1: Scan Error Messages

**Check user-facing errors for leaked IDs:**

```bash
# Search logs for error messages containing thread IDs
journalctl --user -u openclaw-gateway | \
  grep -E "Error.*thread_[a-z0-9]+" | \
  grep -v "Internal error log"
```

**Red flags:**

- Error messages with `thread_`, `session_`, `conv_` prefixes
- UUIDs or long alphanumeric strings in user errors
- Database IDs (numeric) in error text

### Method 2: Inspect API Responses

**Test API for ID leakage:**

```bash
# Trigger error conditions
curl -X POST https://openclaw.example.com/api/chat \
  -H "Authorization: Bearer invalid" \
  -d '{"message": "test"}' \
  | jq '.error'

# Check response for internal IDs
# Should see: "Authentication required"
# Should NOT see: "Thread thread_abc123 requires auth"
```

### Method 3: Monitor External Webhooks

**Check webhook payloads:**

```bash
# Inspect webhook logs
tail -f ~/.openclaw/logs/webhooks.log | \
  grep -E "threadId|sessionId|conversationId"
```

**Safe:** Opaque hashes, user-provided identifiers

**Unsafe:** Internal IDs, database keys, UUIDs

### Method 4: Review Client-Side Code

**Check for console.log in production:**

```bash
# Search for console logs that might leak IDs
grep -r "console.log.*thread" src/
grep -r "console.log.*session" src/
```

## Remediation

### Step 1: Audit Error Handling

**Find all error throws/returns:**

```bash
# Search codebase for error patterns
grep -r "throw new Error" . | grep -i "thread\|session\|conv"
grep -r "return.*error" . | grep -i "thread\|session\|conv"
```

**Review each for ID exposure:**

- Does error message include internal ID?
- Is ID necessary for user to understand error?
- Can ID be logged internally instead?

### Step 2: Implement Error Sanitization

**Create sanitizer utility:**

```typescript
// utils/error-sanitizer.ts
export function sanitizeError(error: Error, context?: any): Error {
  // Log full details internally
  logger.error(error.message, { context, stack: error.stack });

  // Return generic error to user
  const sanitizedMessage = error.message
    .replace(/thread_[a-z0-9]+/gi, "[thread]")
    .replace(/session_[a-z0-9]+/gi, "[session]")
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, "[id]");

  return new Error(sanitizedMessage);
}
```

**Use in error handlers:**

```typescript
try {
  await processThread(threadId);
} catch (error) {
  throw sanitizeError(error, { threadId });
}
```

### Step 3: Use Opaque Identifiers

**Instead of exposing internal IDs, use opaque tokens:**

```typescript
// Generate opaque token for external use
import { createHash } from "crypto";

function getPublicThreadId(internalThreadId: string): string {
  return createHash("sha256")
    .update(internalThreadId + process.env.THREAD_ID_SECRET)
    .digest("hex")
    .substring(0, 16);
}

// Reverse lookup (store mapping in DB)
function getInternalThreadId(publicThreadId: string): string {
  return threadIdMapping.get(publicThreadId);
}
```

**Usage:**

```typescript
// In API response
return {
  success: true,
  threadId: getPublicThreadId(thread.id), // ✅ Opaque
};
```

### Step 4: Configure Production Logging

**Disable debug logs in production:**

```json
{
  "gateway": {
    "logging": {
      "level": "info",
      "includeThreadIds": false,
      "sanitizeErrors": true
    }
  }
}
```

**Log levels:**

- `debug`: Include thread IDs (development only)
- `info`: Generic messages, no IDs
- `warn`: Sanitized warnings
- `error`: Sanitized errors logged, full details to file

### Step 5: Validate External Integrations

**Check all outbound webhooks:**

```bash
# List configured webhooks
openclaw config get cron.jobs | jq '.[] | select(.webhook) | .webhook.url'
```

**For each webhook:**

- Does payload include internal IDs?
- Is external service trusted?
- Can payload use opaque identifiers instead?

## Testing for Leakage

### Test 1: Invalid Thread ID

**Request:**

```bash
curl -X POST https://openclaw.example.com/api/chat \
  -H "Authorization: Bearer valid-token" \
  -d '{"threadId": "nonexistent", "message": "test"}'
```

**Expected response:**

```json
{
  "error": "Conversation not found"
}
```

**❌ Leaking response:**

```json
{
  "error": "Thread thread_abc123 not found",
  "hint": "Valid threads: [thread_xyz789, thread_def456]"
}
```

### Test 2: Unauthorized Access

**Request:**

```bash
curl -X GET https://openclaw.example.com/api/threads/thread_12345 \
  -H "Authorization: Bearer other-user-token"
```

**Expected response:**

```json
{
  "error": "Access denied"
}
```

**❌ Leaking response:**

```json
{
  "error": "Thread thread_12345 belongs to user_67890"
}
```

### Test 3: Error Stack Trace

**Trigger exception:**

```bash
# Send malformed request
curl -X POST https://openclaw.example.com/api/chat \
  -H "Authorization: Bearer valid-token" \
  -d 'invalid json'
```

**Expected response:**

```json
{
  "error": "Invalid request format"
}
```

**❌ Leaking response:**

```json
{
  "error": "JSON parse error at position 5",
  "stack": "at parseMessage (agent.ts:42)\n  threadId: thread_abc123"
}
```

## Monitoring Leakage

### Log Pattern Detection

**Create alert for leaked IDs in user-facing logs:**

```bash
# Add to monitoring script
journalctl --user -u openclaw-gateway -f | \
  grep -E "(thread_|session_|conv_)[a-z0-9]+" | \
  grep -v "Internal:" | \
  while read -r line; do
    echo "⚠️ Potential thread ID leak: $line"
    # Send alert
  done
```

### API Response Monitoring

**Sample API responses for ID patterns:**

```bash
# Monitor API traffic
tcpdump -i any -A 'tcp port 3030' | \
  grep -E "thread_|session_|conv_"
```

## Best Practices

### 1. Principle of Least Information

**Only expose what users need:**

- ✅ "Conversation not found"
- ❌ "Thread thread_abc123 not found"

### 2. Separate Internal and External IDs

**Internal:** UUIDs, database keys (never exposed)

**External:** Opaque tokens, hashes (safe to expose)

### 3. Sanitize All User-Facing Output

**Rule:** Assume all output reaches users, sanitize by default

```typescript
// Middleware to sanitize all responses
app.use((req, res, next) => {
  const originalJson = res.json;
  res.json = function (data) {
    return originalJson.call(this, sanitizeResponseData(data));
  };
  next();
});
```

### 4. Log Internally, Show Generically

**Pattern:**

```typescript
// Log detailed error internally
logger.error("Thread operation failed", {
  threadId,
  userId,
  operation,
  error,
});

// Show generic error to user
res.status(500).json({ error: "Operation failed" });
```

### 5. Regular Security Audits

**Schedule:**

- Monthly: Review error messages in logs
- Quarterly: Scan codebase for new error throws
- Before release: Test API for leakage patterns

## Configuration

**Recommended settings:**

```json
{
  "gateway": {
    "logging": {
      "sanitizeErrors": true,
      "includeInternalIds": false,
      "stackTracesInProduction": false
    },
    "api": {
      "errorFormat": "generic",
      "includeHints": false
    }
  }
}
```

## Related Issues

- **#18528**: Thread ID leakage (this issue)
- **#20912**: API key exposure in prompts (related info leak)
- **#20914**: Plugin fail-open (authorization bypass)

## Related Documentation

- [Security Hardening](/troubleshooting/security-hardening)
- [API Authentication](/gateway/authentication)
- [Gateway Troubleshooting](/gateway/troubleshooting)

## External Resources

- OWASP Information Exposure: <https://owasp.org/www-community/vulnerabilities/Information_exposure_through_an_error_message>
- Issue #18528: <https://github.com/openclaw/openclaw/issues/18528>

---

**Last updated**: February 19, 2026
**Status**: Remediation guidance available, audit required per deployment
