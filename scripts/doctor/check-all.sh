#!/bin/bash
# Comprehensive OpenClaw health check
# Runs all diagnostic scripts and provides overall health report

set -e

echo "🏥 OpenClaw Comprehensive Health Check"
echo "======================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Color codes for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to run a check
run_check() {
    local script_name="$1"
    local description="$2"
    local script_path="$SCRIPT_DIR/$script_name"

    ((TOTAL_CHECKS++))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Check $TOTAL_CHECKS: $description"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ ! -f "$script_path" ]; then
        echo -e "${YELLOW}⚠️  Script not found: $script_path${NC}"
        ((WARNINGS++))
        return
    fi

    if [ ! -x "$script_path" ]; then
        echo -e "${YELLOW}⚠️  Script not executable: $script_path${NC}"
        ((WARNINGS++))
        return
    fi

    # Run the check and capture exit code
    if "$script_path" 2>&1; then
        echo -e "${GREEN}✅ PASSED${NC}"
        ((PASSED_CHECKS++))
    else
        local exit_code=$?
        echo -e "${RED}❌ FAILED (exit code: $exit_code)${NC}"
        ((FAILED_CHECKS++))
    fi
}

# Start time
START_TIME=$(date +%s)

echo "Starting comprehensive health check at $(date)"
echo ""

# Security checks
echo "🔒 Security Checks"
echo "=================="

run_check "detect-leaked-secrets.sh" "API key exposure detection"
run_check "detect-ipv6-ssrf.sh" "IPv6 SSRF bypass detection"
run_check "detect-plugin-failures.sh" "Plugin load failure detection"
run_check "validate-discord-media.sh" "Discord media validation"

# Session and state checks
echo ""
echo "💾 Session & State Checks"
echo "========================="

run_check "cleanup-bloated-sessions.sh" "Session bloat detection" || true
run_check "check-auth-cooldowns.sh" "Auth cooldown health check"

# File system checks
echo ""
echo "📁 File System Checks"
echo "====================="

# Check for registry corruption
((TOTAL_CHECKS++))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Check $TOTAL_CHECKS: Registry integrity check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

REGISTRY_FILES=(
    "$HOME/.openclaw/agents/default/state/models.json"
    "$HOME/.openclaw/agents/default/state/providers.json"
    "$HOME/.openclaw/agents/default/state/tools.json"
)

REGISTRY_ISSUES=0

for file in "${REGISTRY_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}⚠️  Missing: $(basename "$file")${NC}"
        ((WARNINGS++))
        continue
    fi

    if ! jq . "$file" >/dev/null 2>&1; then
        echo -e "${RED}❌ Corrupted: $(basename "$file")${NC}"
        ((REGISTRY_ISSUES++))
    else
        echo -e "${GREEN}✅ Valid: $(basename "$file")${NC}"
    fi
done

if [ "$REGISTRY_ISSUES" -eq 0 ]; then
    echo -e "${GREEN}✅ PASSED${NC}"
    ((PASSED_CHECKS++))
else
    echo -e "${RED}❌ FAILED${NC}"
    ((FAILED_CHECKS++))
fi

# Check session lock files
((TOTAL_CHECKS++))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Check $TOTAL_CHECKS: Session lock health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

LOCK_FILES=$(find /tmp -name "openclaw-session-*.lock" 2>/dev/null || echo "")

if [ -z "$LOCK_FILES" ]; then
    echo "No session locks found (OK)"
    echo -e "${GREEN}✅ PASSED${NC}"
    ((PASSED_CHECKS++))
else
    ORPHANED=0
    ACTIVE=0

    while IFS= read -r lock_file; do
        if [ ! -f "$lock_file" ]; then
            continue
        fi

        LOCK_DATA=$(cat "$lock_file" 2>/dev/null)
        PID=$(echo "$LOCK_DATA" | jq -r '.pid // empty' 2>/dev/null)

        if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
            echo -e "${YELLOW}⚠️  Orphaned lock: $(basename "$lock_file")${NC}"
            ((ORPHANED++))
        else
            echo -e "${GREEN}✅ Active lock: $(basename "$lock_file") (PID $PID)${NC}"
            ((ACTIVE++))
        fi
    done <<< "$LOCK_FILES"

    if [ "$ORPHANED" -eq 0 ]; then
        echo -e "${GREEN}✅ PASSED${NC}"
        ((PASSED_CHECKS++))
    else
        echo -e "${YELLOW}⚠️  WARNING: $ORPHANED orphaned lock(s)${NC}"
        ((WARNINGS++))
        ((PASSED_CHECKS++))  # Warnings don't fail the check
    fi
fi

# Log file checks
((TOTAL_CHECKS++))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Check $TOTAL_CHECKS: Log file health"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

LOGS_DIR="$HOME/.openclaw/logs"

if [ ! -d "$LOGS_DIR" ]; then
    echo -e "${YELLOW}⚠️  Logs directory not found${NC}"
    ((WARNINGS++))
    ((PASSED_CHECKS++))
else
    # Check for excessive log sizes
    LARGE_LOGS=$(find "$LOGS_DIR" -type f -size +100M 2>/dev/null || echo "")

    if [ -z "$LARGE_LOGS" ]; then
        echo "No excessively large log files (OK)"
    else
        echo -e "${YELLOW}⚠️  Large log files found:${NC}"
        echo "$LARGE_LOGS" | while IFS= read -r log; do
            SIZE=$(du -h "$log" | cut -f1)
            echo "   $(basename "$log"): $SIZE"
        done
        ((WARNINGS++))
    fi

    # Check for recent errors
    RECENT_ERRORS=$(find "$LOGS_DIR" -type f -name "*.log" -mtime -1 -exec grep -l "ERROR\|FATAL" {} \; 2>/dev/null | wc -l || echo "0")

    if [ "$RECENT_ERRORS" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  $RECENT_ERRORS log file(s) with recent errors${NC}"
        ((WARNINGS++))
    else
        echo "No recent errors in logs (OK)"
    fi

    echo -e "${GREEN}✅ PASSED${NC}"
    ((PASSED_CHECKS++))
fi

# Configuration validation
((TOTAL_CHECKS++))
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Check $TOTAL_CHECKS: Configuration validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CONFIG_FILE="$HOME/.openclaw/openclaw.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Config file not found${NC}"
    ((FAILED_CHECKS++))
else
    if ! jq . "$CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${RED}❌ Config file is invalid JSON${NC}"
        ((FAILED_CHECKS++))
    else
        echo "Config file is valid JSON"

        # Check for common misconfigurations
        CONFIG_ISSUES=0

        # Check if gateway bind is 0.0.0.0 without auth
        BIND=$(jq -r '.gateway.bind // "lan"' "$CONFIG_FILE")
        AUTH_MODE=$(jq -r '.gateway.auth.mode // "none"' "$CONFIG_FILE")

        if [ "$BIND" = "0.0.0.0" ] && [ "$AUTH_MODE" = "none" ]; then
            echo -e "${RED}❌ Gateway bound to 0.0.0.0 without authentication${NC}"
            ((CONFIG_ISSUES++))
        fi

        # Check if sandbox is disabled
        SANDBOX=$(jq -r '.agents.defaults.sandbox.enabled // true' "$CONFIG_FILE")
        if [ "$SANDBOX" = "false" ]; then
            echo -e "${YELLOW}⚠️  Sandbox disabled (security risk)${NC}"
            ((WARNINGS++))
        fi

        if [ "$CONFIG_ISSUES" -eq 0 ]; then
            echo -e "${GREEN}✅ PASSED${NC}"
            ((PASSED_CHECKS++))
        else
            echo -e "${RED}❌ FAILED${NC}"
            ((FAILED_CHECKS++))
        fi
    fi
fi

# End time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Final report
echo ""
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Final Health Report"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Checks completed: $TOTAL_CHECKS"
echo -e "Passed: ${GREEN}$PASSED_CHECKS${NC}"
echo -e "Failed: ${RED}$FAILED_CHECKS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo "Duration: ${DURATION}s"
echo ""

if [ "$FAILED_CHECKS" -eq 0 ]; then
    if [ "$WARNINGS" -eq 0 ]; then
        echo -e "${GREEN}✅ OpenClaw is healthy!${NC}"
        echo ""
        echo "All checks passed with no warnings."
        echo ""
        exit 0
    else
        echo -e "${YELLOW}⚠️  OpenClaw is mostly healthy, but has warnings${NC}"
        echo ""
        echo "Review warnings above and address them as needed."
        echo ""
        exit 0
    fi
else
    echo -e "${RED}❌ OpenClaw has issues that need attention${NC}"
    echo ""
    echo "Failed checks: $FAILED_CHECKS"
    echo "Review failed checks above and take corrective action."
    echo ""
    echo "Quick fixes:"
    echo "  - Leaked secrets: Move API keys to auth profiles"
    echo "  - Registry corruption: Restore from backup or reset"
    echo "  - Plugin failures: Check logs and reinstall dependencies"
    echo "  - Configuration issues: Review and fix config errors"
    echo ""
    exit 1
fi
