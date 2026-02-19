---
summary: "PTY race conditions and terminal state corruption"
title: "PTY Race Conditions"
---

# PTY Race Conditions

**Issue**: #20797

PTY (pseudo-terminal) operations in OpenClaw can race with each other, leading to corrupted terminal state, dropped output, or stuck processes.

## Understanding PTY in OpenClaw

OpenClaw uses PTY for:

- **Shell tool execution** - Running bash commands in persistent shell
- **Interactive sessions** - Streaming command output to users
- **Process control** - Sending signals (Ctrl+C, Ctrl+Z)
- **Terminal emulation** - ANSI color codes, cursor movement

**Architecture:**

```
Agent → Shell Tool → PTY Master → PTY Slave → bash process
         ↓
    Read/Write
    Operations
         ↓
    Race Window!
```

## The Race Condition

### Scenario 1: Concurrent Writes

**What happens:**

Two threads write to PTY simultaneously:

```
Thread A: Write "echo hello"
Thread B: Write "ls -la"

Expected: Commands execute sequentially
Actual:   "echlso  -hlelloal"  (interleaved)
```

**Result:** Corrupted input to shell

### Scenario 2: Read During Resize

**What happens:**

Terminal resize signal arrives while reading output:

```
Thread A: Reading output from command
Signal:   SIGWINCH (resize) → reset PTY state
Thread A: Continues reading from reset PTY

Expected: Complete output
Actual:   Truncated output, missing lines
```

**Result:** Lost command output

### Scenario 3: Close During Write

**What happens:**

PTY closed (process exit) while write in progress:

```
Thread A: Writing next command
Thread B: Process exits → close PTY
Thread A: Write fails → uncaught exception

Expected: Graceful cleanup
Actual:   Hung shell tool, future commands fail
```

**Result:** Shell tool permanently stuck

## How to Detect

### Symptom 1: Garbled Shell Output

**User report:**

```
User: "Run ls command"
Agent: *shows corrupted output*
```

**In logs:**

```
[error] Shell output parse failed: unexpected character at position 42
[warn]  PTY read incomplete, retrying...
```

**Check:**

```bash
journalctl --user -u openclaw-gateway | grep -i "pty.*race\|shell.*corrupt"
```

### Symptom 2: Commands Never Complete

**User report:**

```
User: "Run npm install"
Agent: *spinner forever, never returns*
```

**In logs:**

```
[warn]  Shell command timeout after 120s
[error] PTY read: Resource temporarily unavailable (EAGAIN)
```

**Check:**

```bash
# List hung shell processes
ps aux | grep openclaw | grep -E "bash|sh" | grep -v grep
```

### Symptom 3: Shell Tool Becomes Unresponsive

**User report:**

```
User: "Run any command"
Agent: "Shell tool unavailable"
```

**In logs:**

```
[error] Shell tool: PTY master closed unexpectedly
[error] Failed to initialize shell session
```

**Check:**

```bash
# Check PTY allocation
ls -la /dev/pts/
```

## Root Causes

### 1. Missing PTY Write Lock

**Code location:** `tools/shell/pty-manager.ts`

**Issue:**

```typescript
// ❌ No lock - concurrent writes can interleave
async write(data: string) {
  await this.ptyMaster.write(data);
}
```

**Fix:**

```typescript
// ✅ Lock ensures sequential writes
private writeLock = new AsyncLock();

async write(data: string) {
  await this.writeLock.acquire('write', async () => {
    await this.ptyMaster.write(data);
  });
}
```

### 2. Read Buffer Not Protected

**Code location:** `tools/shell/output-reader.ts`

**Issue:**

```typescript
// ❌ Buffer accessed from multiple threads
this.outputBuffer += chunk;
```

**Fix:**

```typescript
// ✅ Atomic append with lock
await this.bufferLock.acquire("append", async () => {
  this.outputBuffer += chunk;
});
```

### 3. Resize Handler Not Debounced

**Code location:** `tools/shell/pty-manager.ts`

**Issue:**

```typescript
// ❌ Every resize event immediately resets PTY
process.on("SIGWINCH", () => {
  this.pty.resize(cols, rows);
});
```

**Fix:**

```typescript
// ✅ Debounce resize events
private resizeDebounce = debounce(() => {
  this.pty.resize(this.cols, this.rows);
}, 100);

process.on('SIGWINCH', () => {
  this.resizeDebounce();
});
```

### 4. No Close Coordination

**Code location:** `tools/shell/shell-tool.ts`

**Issue:**

```typescript
// ❌ Close without waiting for pending operations
async dispose() {
  this.pty.kill();
}
```

**Fix:**

```typescript
// ✅ Wait for pending operations before close
async dispose() {
  await this.writeLock.waitForUnlock();
  await this.readLock.waitForUnlock();
  this.pty.kill();
}
```

## Workarounds

### Option 1: Disable Concurrent Shell Operations

**Limitation:** Only one shell command at a time

**Configuration:**

```json
{
  "tools": {
    "shell": {
      "concurrency": 1,
      "queueMode": "sequential"
    }
  }
}
```

**Pros:** Eliminates write races

**Cons:** Slower execution, commands wait in queue

### Option 2: Use Process Isolation

**Approach:** Each command gets its own PTY

**Configuration:**

```json
{
  "tools": {
    "shell": {
      "mode": "isolated",
      "reuseShell": false
    }
  }
}
```

**Pros:** No shared state, no races

**Cons:** Higher overhead, state not preserved between commands

### Option 3: Increase Operation Timeouts

**Rationale:** Give more time for races to resolve

**Configuration:**

```json
{
  "tools": {
    "shell": {
      "timeout": 300000,
      "readTimeout": 60000
    }
  }
}
```

**Pros:** Reduces timeout errors

**Cons:** Doesn't fix root cause, longer hangs

## Testing PTY Race Conditions

### Test 1: Concurrent Shell Commands

**Setup:**

```bash
# Enable shell tool
openclaw config set tools.shell.enabled true
```

**Test script:**

```javascript
// Send multiple commands simultaneously
const commands = ["echo 'Command 1'", "echo 'Command 2'", "echo 'Command 3'"];

await Promise.all(commands.map((cmd) => shellTool.execute(cmd)));
```

**Expected:** All three outputs appear correctly

**Failure mode:** Interleaved output, missing lines

### Test 2: Resize During Command

**Setup:**

```bash
# Run long-running command
openclaw shell execute "find / -name '*.log' 2>/dev/null"
```

**Test:**

```bash
# While command running, resize terminal
stty cols 120 rows 40
stty cols 80 rows 24
stty cols 200 rows 60
# Rapid resizes
```

**Expected:** Command output unaffected

**Failure mode:** Output truncated, process hung

### Test 3: Rapid Command Sequence

**Test script:**

```bash
# Send 100 commands as fast as possible
for i in {1..100}; do
  echo "echo '$i'" | openclaw shell execute --stdin &
done
wait
```

**Expected:** All 100 numbers printed in order

**Failure mode:** Missing numbers, duplicates, garbled output

### Test 4: Kill During Write

**Setup:**

```bash
# Start interactive shell session
openclaw shell interactive
```

**Test:**

```bash
# Type command but don't press enter
echo "sleep 60"

# Kill shell process externally
pkill -9 -f openclaw.*shell

# Try to send more commands
openclaw shell execute "ls"
```

**Expected:** Error message, new shell spawned

**Failure mode:** Hung, no error, subsequent commands fail

## Monitoring PTY Health

### Check Active PTY Sessions

```bash
# List PTY devices in use
ls -la /dev/pts/ | grep openclaw

# Or via lsof
lsof | grep /dev/pts | grep openclaw
```

### Monitor PTY Errors

```bash
# Watch for PTY-related errors
journalctl --user -u openclaw-gateway -f | grep -i pty
```

**Healthy output:**

```
[info] PTY initialized: /dev/pts/3
[info] Shell ready on PTY 3
```

**Unhealthy output:**

```
[error] PTY write EAGAIN (retry 3/5)
[error] PTY read incomplete, buffer size 4096
[warn]  PTY resize race detected
```

### PTY Resource Limits

```bash
# Check PTY limit
cat /proc/sys/kernel/pty/max

# Check current usage
ls /dev/pts/ | wc -l

# Set higher limit if needed
sudo sysctl -w kernel.pty.max=4096
```

## Prevention Best Practices

### 1. Use Shell Tool Sequentially

**Avoid:**

```typescript
// Concurrent shell operations
await Promise.all([
  shellTool.execute("git pull"),
  shellTool.execute("npm install"),
  shellTool.execute("npm test"),
]);
```

**Prefer:**

```typescript
// Sequential shell operations
await shellTool.execute("git pull");
await shellTool.execute("npm install");
await shellTool.execute("npm test");
```

### 2. Handle Shell Tool Errors Gracefully

```typescript
try {
  const result = await shellTool.execute("command");
} catch (error) {
  if (error.code === "PTY_CLOSED") {
    // Reinitialize shell
    await shellTool.reset();
    // Retry
    const result = await shellTool.execute("command");
  }
}
```

### 3. Set Appropriate Timeouts

```json
{
  "tools": {
    "shell": {
      "timeout": 120000,
      "readTimeout": 30000,
      "writeTimeout": 5000
    }
  }
}
```

### 4. Monitor Shell Health

```bash
# Add to cron or systemd timer
*/5 * * * * openclaw shell health | grep -q "healthy" || systemctl --user restart openclaw-gateway
```

## Long-Term Fix

**Status:** Core code changes required

**PR available:** Not yet (as of 2026.2.19)

**Required changes:**

1. Add write lock to PTY manager (`AsyncLock` or `Mutex`)
2. Protect read buffer with lock
3. Debounce resize events (100ms window)
4. Coordinate close with pending operations
5. Add PTY health monitoring endpoint
6. Implement automatic PTY recovery

**Complexity:** Medium (requires careful testing)

**Risk:** High (PTY is critical infrastructure)

## Related Issues

- **#20797**: PTY race conditions (this issue)
- **#18060**: Session lock races (related locking issue)
- **#6766**: Registry write races (similar pattern)

## Related Documentation

- [Shell Tool Configuration](/tools/shell)
- [Tool Execution](/concepts/tools)
- [Process Management](/gateway/process-management)

## External Resources

- PTY Programming Guide: <https://man7.org/linux/man-pages/man7/pty.7.html>
- Node-pty Library: <https://github.com/microsoft/node-pty>
- Issue #20797: <https://github.com/openclaw/openclaw/issues/20797>

---

**Last updated**: February 19, 2026
**Status**: Workarounds available, core fix required
