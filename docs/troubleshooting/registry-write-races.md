---
summary: "Concurrent registry write operations causing data corruption"
title: "Registry Write Race Conditions"
---

# Registry Write Race Conditions

**Issue**: #6766

Concurrent write operations to OpenClaw's registries (model registry, provider registry, tool registry) can race with each other, leading to data corruption, lost updates, or inconsistent state.

## Understanding OpenClaw Registries

OpenClaw maintains several registries for runtime state:

**Model Registry:**

- Maps model IDs to model configurations
- Updated on: model add/remove, config reload
- File: `~/.openclaw/agents/default/state/models.json`

**Provider Registry:**

- Maps provider IDs to provider instances
- Updated on: provider initialization, credential changes
- File: `~/.openclaw/agents/default/state/providers.json`

**Tool Registry:**

- Maps tool names to tool definitions
- Updated on: plugin load, tool enable/disable
- File: `~/.openclaw/agents/default/state/tools.json`

**Session Registry:**

- Maps session IDs to session state
- Updated on: every message, session create/destroy
- File: `~/.openclaw/agents/default/sessions/*.json`

## The Write Race

**Classic race condition:**

```
Thread A: Read registry → [{model1}, {model2}]
Thread B: Read registry → [{model1}, {model2}]
Thread A: Add {model3} → [{model1}, {model2}, {model3}]
Thread A: Write registry
Thread B: Add {model4} → [{model1}, {model2}, {model4}]
Thread B: Write registry (overwrites A's changes!)
Final: [{model1}, {model2}, {model4}]  ← model3 lost!
```

**Result:** Lost update - Thread A's model3 disappears

## Race Scenarios

### Race 1: Concurrent Model Registration

**Scenario:**

1. Two plugins both register models on startup
2. Both read current registry simultaneously
3. Both add their models to the in-memory copy
4. Both write back to disk
5. Second write overwrites first write

**Impact:** First plugin's models missing from registry

**Example:**

```typescript
// Plugin A
async registerModel() {
  const registry = await readRegistry(); // [{default-model}]
  registry.push({ id: "plugin-a-model", ... });
  await writeRegistry(registry); // [{default-model}, {plugin-a-model}]
}

// Plugin B (running concurrently)
async registerModel() {
  const registry = await readRegistry(); // [{default-model}]  ← Same base!
  registry.push({ id: "plugin-b-model", ... });
  await writeRegistry(registry); // [{default-model}, {plugin-b-model}]  ← Overwrites A!
}
```

### Race 2: Simultaneous Provider Updates

**Scenario:**

1. Admin updates provider config via API
2. Simultaneously, auto-refresh rotates provider credentials
3. Both operations read-modify-write provider registry
4. One update is lost

**Impact:** Stale credentials or lost configuration

### Race 3: Tool Enable/Disable Race

**Scenario:**

1. User disables tool via UI
2. Simultaneously, plugin re-enables same tool
3. Final state depends on write order

**Impact:** Tool state inconsistent with user intent

### Race 4: Session Update Flood

**Scenario:**

1. High-frequency updates to session (every message)
2. Multiple threads handling messages for same session
3. Concurrent writes to session file

**Impact:** Lost messages, corrupted session state

## Detection

### Symptom 1: Missing Registry Entries

**User report:**

```
Admin: "Added model via API"
User: "Model not showing up"
Admin: *Restart gateway*
User: "Still missing"
```

**Check logs:**

```bash
journalctl --user -u openclaw-gateway | \
  grep "Registry write" | grep "conflict\|lost"
```

### Symptom 2: Registry Corruption

**Error on startup:**

```
[error] Failed to parse models.json: Unexpected token at position 542
[error] Registry file corrupted, using fallback
```

**File inspection:**

```bash
cat ~/.openclaw/agents/default/state/models.json
# Shows: {"models":[{"id":"model1"},{"id":"model2"{"id":"model3"}]}
#                                                  ^ Missing comma
```

### Symptom 3: Inconsistent State After Restart

**Behavior:**

1. Model shows as "enabled" in UI
2. Restart gateway
3. Model now shows as "disabled"
4. No config changes made

**Cause:** Conflicting writes, last write before shutdown had wrong state

### Symptom 4: Duplicate Entries

**Registry check:**

```bash
jq '.models[].id' ~/.openclaw/agents/default/state/models.json | sort | uniq -d
# Output: claude-opus-4-6
# Duplicate entry from race condition
```

## Root Causes

### Cause 1: No Write Locking

**Vulnerable code:**

```typescript
// ❌ No lock - concurrent writes race
class Registry {
  async addModel(model: Model) {
    const current = await this.read(); // Read
    current.models.push(model); // Modify
    await this.write(current); // Write
  }
}
```

**Timeline of race:**

```
T1: Thread A reads ([]​)
T2: Thread B reads ([]​)
T3: Thread A writes ([A])
T4: Thread B writes ([B])  ← Overwrites A
```

**Fix:**

```typescript
// ✅ Lock ensures serial access
class Registry {
  private writeLock = new AsyncLock();

  async addModel(model: Model) {
    await this.writeLock.acquire("write", async () => {
      const current = await this.read();
      current.models.push(model);
      await this.write(current);
    });
  }
}
```

### Cause 2: Non-Atomic File Writes

**Vulnerable code:**

```typescript
// ❌ Write not atomic - partial writes on crash
async write(data: any) {
  await fs.writeFile(this.path, JSON.stringify(data));
}
```

**Problem:** If process crashes during write, file corrupted

**Fix:**

```typescript
// ✅ Atomic write via temp file + rename
async write(data: any) {
  const tempPath = `${this.path}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(data));
  await fs.rename(tempPath, this.path); // Atomic on POSIX
}
```

### Cause 3: No Write Coalescing

**Issue:** High-frequency updates cause write storms

**Vulnerable code:**

```typescript
// ❌ Every message triggers immediate registry write
async handleMessage(message: Message) {
  session.messages.push(message);
  await registry.saveSession(session); // Write on every message!
}
```

**Problem:** 100 messages/sec = 100 writes/sec → races

**Fix:**

```typescript
// ✅ Debounced writes, batch updates
class Registry {
  private pendingWrites = new Map<string, any>();
  private writeDebounce = debounce(() => this.flushWrites(), 1000);

  async saveSession(session: Session) {
    this.pendingWrites.set(session.id, session);
    this.writeDebounce();
  }

  private async flushWrites() {
    await this.writeLock.acquire("batch", async () => {
      for (const [id, session] of this.pendingWrites) {
        await this.writeSessionFile(id, session);
      }
      this.pendingWrites.clear();
    });
  }
}
```

### Cause 4: No Conflict Detection

**Issue:** Overwrite without detecting conflict

**Vulnerable code:**

```typescript
// ❌ Always overwrites, no conflict detection
async save(data: any) {
  await this.write(data);
}
```

**Fix:**

```typescript
// ✅ Compare timestamps, detect conflicts
async save(data: any, expectedVersion?: number) {
  const current = await this.read();

  if (expectedVersion && current.version !== expectedVersion) {
    throw new ConflictError("Registry modified by another process");
  }

  data.version = (current.version || 0) + 1;
  await this.write(data);
}
```

## Workarounds

### Workaround 1: Sequential Operations

**Approach:** Avoid concurrent registry operations

**Implementation:**

```typescript
// ❌ Concurrent
await Promise.all([
  registry.addModel(model1),
  registry.addModel(model2),
  registry.addModel(model3),
]);

// ✅ Sequential
await registry.addModel(model1);
await registry.addModel(model2);
await registry.addModel(model3);
```

**Pros:** Eliminates races

**Cons:** Slower, not always possible

### Workaround 2: Batch Operations

**Approach:** Group updates into single write

**Implementation:**

```typescript
// ✅ Single write, no race window
await registry.addModels([model1, model2, model3]);
```

**Pros:** Atomic, fast

**Cons:** Requires batch API support

### Workaround 3: File Locking

**Approach:** Use OS-level file locks

**Implementation:**

```bash
# Use flock to prevent concurrent writes
flock ~/.openclaw/agents/default/state/models.json.lock \
  openclaw models add claude-opus-4-6
```

**Pros:** Works across processes

**Cons:** Requires flock support, complex error handling

### Workaround 4: Retry on Conflict

**Approach:** Detect conflicts, retry with fresh read

**Implementation:**

```typescript
async function addModelWithRetry(model: Model, maxRetries = 5) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      const current = await registry.read();
      const version = current.version;
      current.models.push(model);
      await registry.save(current, version); // Throws on conflict
      return;
    } catch (error) {
      if (error instanceof ConflictError && i < maxRetries - 1) {
        await sleep(100 * Math.random()); // Random backoff
        continue;
      }
      throw error;
    }
  }
}
```

**Pros:** Eventually succeeds

**Cons:** Retries increase latency

## Testing Registry Races

### Test 1: Concurrent Model Registration

**Script:**

```bash
#!/bin/bash
# concurrent-model-add.sh

# Add 10 models concurrently
for i in {1..10}; do
  openclaw models add "test-model-$i" \
    --provider anthropic \
    --modelId claude-opus-4-6 &
done
wait

# Check count
COUNT=$(openclaw models list --json | jq '. | length')
if [ "$COUNT" -ne 10 ]; then
  echo "❌ Race detected: expected 10, got $COUNT"
  exit 1
else
  echo "✅ All 10 models registered"
fi
```

**Expected:** All 10 models present

**Failure:** < 10 models (lost updates)

### Test 2: High-Frequency Session Updates

**Script:**

```typescript
// flood-session-updates.ts
const sessionId = "test-session";

// 100 concurrent writes to same session
const updates = Array.from({ length: 100 }, (_, i) => i);
await Promise.all(
  updates.map((i) =>
    registry.updateSession(sessionId, {
      messages: [...session.messages, { id: i, text: `Message ${i}` }],
    }),
  ),
);

// Verify all messages present
const session = await registry.getSession(sessionId);
if (session.messages.length !== 100) {
  console.error(`❌ Race detected: expected 100, got ${session.messages.length}`);
} else {
  console.log("✅ All 100 messages saved");
}
```

### Test 3: Plugin Load Race

**Setup:**

```bash
# Install multiple plugins
openclaw plugins install plugin-a plugin-b plugin-c plugin-d plugin-e

# Restart to trigger concurrent plugin initialization
systemctl --user restart openclaw-gateway

# Check tool registry
EXPECTED_TOOLS=25  # 5 plugins × 5 tools each
ACTUAL_TOOLS=$(openclaw tools list --json | jq '. | length')

if [ "$ACTUAL_TOOLS" -ne "$EXPECTED_TOOLS" ]; then
  echo "❌ Race detected: expected $EXPECTED_TOOLS, got $ACTUAL_TOOLS"
fi
```

### Test 4: Crash During Write

**Script:**

```bash
#!/bin/bash
# crash-during-write.sh

# Start rapid writes
for i in {1..1000}; do
  openclaw models update claude-opus --config '{"temp":0.7}' &

  # Randomly kill process
  if [ $((RANDOM % 100)) -eq 0 ]; then
    pkill -9 openclaw
    sleep 1
    systemctl --user start openclaw-gateway
  fi
done
wait

# Check for corruption
if ! jq . ~/.openclaw/agents/default/state/models.json >/dev/null 2>&1; then
  echo "❌ Registry corrupted"
  exit 1
else
  echo "✅ Registry intact"
fi
```

## Monitoring

### Check Registry Health

**Script:**

```bash
#!/bin/bash
# check-registry-health.sh

REGISTRY_FILES=(
  "$HOME/.openclaw/agents/default/state/models.json"
  "$HOME/.openclaw/agents/default/state/providers.json"
  "$HOME/.openclaw/agents/default/state/tools.json"
)

ISSUES=0

for file in "${REGISTRY_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "⚠️ Missing: $file"
    ((ISSUES++))
    continue
  fi

  # Check JSON validity
  if ! jq . "$file" >/dev/null 2>&1; then
    echo "❌ Corrupted: $file"
    ((ISSUES++))
    continue
  fi

  # Check for duplicates
  DUPLICATES=$(jq -r '.[].id // .models[].id // .tools[].name // .providers[].id' "$file" 2>/dev/null | sort | uniq -d)
  if [ -n "$DUPLICATES" ]; then
    echo "⚠️ Duplicates in $file: $DUPLICATES"
    ((ISSUES++))
  fi
done

if [ $ISSUES -eq 0 ]; then
  echo "✅ All registries healthy"
  exit 0
else
  echo "❌ Found $ISSUES issue(s)"
  exit 1
fi
```

**Run in cron:**

```bash
*/10 * * * * /path/to/check-registry-health.sh || \
  echo "Registry corruption detected" | mail -s "OpenClaw Alert" admin@example.com
```

### Log Registry Writes

**Configuration:**

```json
{
  "gateway": {
    "logging": {
      "registryWrites": {
        "enabled": true,
        "level": "debug",
        "includeStackTrace": true
      }
    }
  }
}
```

**Monitor for conflicts:**

```bash
journalctl --user -u openclaw-gateway -f | \
  grep "Registry.*conflict\|Registry.*overwrite"
```

## Prevention Best Practices

### 1. Use Batch APIs

**Prefer:**

```typescript
await registry.addModels([model1, model2, model3]); // Single write
```

**Over:**

```typescript
await registry.addModel(model1); // Three writes
await registry.addModel(model2);
await registry.addModel(model3);
```

### 2. Debounce High-Frequency Updates

**For session updates:**

```typescript
const debouncedSave = debounce((session) => {
  registry.saveSession(session);
}, 1000);

// Use debounced version
debouncedSave(session);
```

### 3. Validate Before Writing

**Check for conflicts:**

```typescript
const before = await registry.read();
// ... modifications ...
const after = await registry.read();

if (before.version !== after.version) {
  throw new Error("Conflict detected, retry");
}

await registry.write(modified);
```

### 4. Use Versioning

**Track versions:**

```json
{
  "version": 42,
  "models": [...]
}
```

**Reject stale writes:**

```typescript
if (data.version <= currentVersion) {
  throw new Error("Stale write rejected");
}
```

### 5. Implement Write Coalescing

**Batch updates:**

```typescript
class Registry {
  private pendingUpdates: Map<string, Update> = new Map();

  async scheduleUpdate(key: string, update: Update) {
    this.pendingUpdates.set(key, update);
    this.triggerFlush();
  }

  private async flush() {
    const updates = Array.from(this.pendingUpdates.entries());
    this.pendingUpdates.clear();
    await this.batchWrite(updates);
  }
}
```

## Long-Term Fix

**Status:** Core code changes required

**PR available:** Not yet (as of 2026.2.19)

**Required changes:**

1. Add write locks to all registries (`AsyncLock`)
2. Implement atomic file writes (temp + rename)
3. Add version tracking for conflict detection
4. Implement write coalescing for high-frequency updates
5. Add registry health monitoring
6. Auto-recovery from corrupted registries

**Complexity:** Medium (affects all registry operations)

**Risk:** High (registries are critical infrastructure)

## Related Issues

- **#6766**: Registry write races (this issue)
- **#20769**: Reset-model race conditions
- **#18060**: Session lock races

## Related Documentation

- [Model Configuration](/concepts/models)
- [Gateway State Management](/gateway/state-management)
- [Plugin Development](/plugins/development)

## External Resources

- File Locking Best Practices: <https://man7.org/linux/man-pages/man2/flock.2.html>
- Atomic File Operations: <https://lwn.net/Articles/457667/>
- Issue #6766: <https://github.com/openclaw/openclaw/issues/6766>

---

**Last updated**: February 19, 2026
**Status**: Workarounds available, core fix required
