#!/bin/bash
# Plugin load failure detection tool
# Addresses #20914: Plugin load failure allows all tool calls

set -e

echo "🔌 Plugin Load Failure Detector"
echo "==============================="
echo ""

CONFIG_FILE="${HOME}/.openclaw/openclaw.json"
LOGS_DIR="${HOME}/.openclaw/logs"
PLUGINS_DIR="${HOME}/.openclaw/plugins"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "📂 Scanning plugin configuration and logs..."
echo ""

ISSUES=0

# Get configured plugins
CONFIGURED_PLUGINS=$(jq -r '.plugins.enabled // [] | .[]' "$CONFIG_FILE" 2>/dev/null || echo "")

if [ -z "$CONFIGURED_PLUGINS" ]; then
    echo "ℹ️  No plugins configured"
    exit 0
fi

echo "📋 Configured Plugins"
echo "===================="
echo ""

# Check each configured plugin
LOADED_PLUGINS=0
FAILED_PLUGINS=0

while IFS= read -r plugin_name; do
    if [ -z "$plugin_name" ]; then
        continue
    fi

    echo "Checking: $plugin_name"

    # Check if plugin directory exists
    PLUGIN_DIR="$PLUGINS_DIR/$plugin_name"
    if [ ! -d "$PLUGIN_DIR" ]; then
        echo "  ❌ Plugin directory not found: $PLUGIN_DIR"
        ((FAILED_PLUGINS++))
        ((ISSUES++))
        echo ""
        continue
    fi

    # Check if plugin has package.json
    if [ ! -f "$PLUGIN_DIR/package.json" ]; then
        echo "  ⚠️  Missing package.json"
        ((FAILED_PLUGINS++))
        ((ISSUES++))
        echo ""
        continue
    fi

    # Check if plugin has main entry point
    MAIN_FILE=$(jq -r '.main // "index.js"' "$PLUGIN_DIR/package.json")
    if [ ! -f "$PLUGIN_DIR/$MAIN_FILE" ]; then
        echo "  ⚠️  Main file not found: $MAIN_FILE"
        ((FAILED_PLUGINS++))
        ((ISSUES++))
        echo ""
        continue
    fi

    # Check logs for plugin load errors
    if [ -d "$LOGS_DIR" ]; then
        LOAD_ERRORS=$(grep -r "plugin.*$plugin_name.*fail\|Error.*$plugin_name" "$LOGS_DIR" 2>/dev/null | wc -l || echo "0")

        if [ "$LOAD_ERRORS" -gt 0 ]; then
            echo "  ❌ Found $LOAD_ERRORS load error(s) in logs"

            # Show recent errors
            echo "  Recent errors:"
            grep -r "plugin.*$plugin_name.*fail\|Error.*$plugin_name" "$LOGS_DIR" 2>/dev/null | tail -3 | sed 's/^/    /'

            ((FAILED_PLUGINS++))
            ((ISSUES++))
            echo ""
            continue
        fi
    fi

    # Check if plugin actually loaded (look for success message)
    if [ -d "$LOGS_DIR" ]; then
        LOAD_SUCCESS=$(grep -r "plugin.*$plugin_name.*loaded\|$plugin_name.*initialized" "$LOGS_DIR" 2>/dev/null | wc -l || echo "0")

        if [ "$LOAD_SUCCESS" -eq 0 ]; then
            echo "  ⚠️  No load success messages in logs (may not be loaded)"
            ((FAILED_PLUGINS++))
            ((ISSUES++))
            echo ""
            continue
        fi
    fi

    echo "  ✅ Appears healthy"
    ((LOADED_PLUGINS++))
    echo ""

done <<< "$CONFIGURED_PLUGINS"

echo "📊 Summary"
echo "=========="
echo "Configured plugins: $(echo "$CONFIGURED_PLUGINS" | wc -l)"
echo "Loaded successfully: $LOADED_PLUGINS"
echo "Failed to load: $FAILED_PLUGINS"
echo ""

if [ "$FAILED_PLUGINS" -eq 0 ]; then
    echo "✅ All plugins loaded successfully"
    echo ""
    echo "💡 Tip: Check plugin health regularly:"
    echo "   ./scripts/doctor/detect-plugin-failures.sh"
    echo ""
    exit 0
fi

echo "⚠️  Found $FAILED_PLUGINS failed plugin(s)"
echo ""
echo "⚠️  Security Risk: Plugin Fail-Open (#20914)"
echo ""
echo "When security plugins fail to load (missing dependency, version"
echo "mismatch, import error), their tool restrictions silently disappear."
echo "All previously blocked tools become allowed without any visible"
echo "indication."
echo ""
echo "Security Impact"
echo "==============="
echo ""
echo "Example scenario:"
echo ""
echo "1. Install 'okaidokai' plugin to block 'exec' and 'nodes.run'"
echo "2. Plugin fails to load after OpenClaw update"
echo "3. 'exec' and 'nodes.run' now allowed for all users"
echo "4. No error shown to user or operator"
echo "5. Only signal is buried in gateway.err.log"
echo ""
echo "Affected security controls:"
echo "- Tool firewall plugins → restricted tools now executable"
echo "- Access control plugins → authorization checks bypassed"
echo "- Audit plugins → sensitive actions not logged"
echo ""
echo "🔧 Immediate Actions"
echo "===================="
echo ""
echo "1. Check error logs for plugin load failures:"
echo "   tail -100 ~/.openclaw/logs/gateway.err.log | grep -i plugin"
echo ""
echo "2. Verify plugin dependencies are installed:"
echo "   cd ~/.openclaw/plugins/<plugin-name>"
echo "   npm install"
echo ""
echo "3. Check plugin compatibility with current OpenClaw version:"
echo "   openclaw plugins check <plugin-name>"
echo ""
echo "4. As backup, use gateway-level tool policies:"
echo ""
cat <<'JSON'
   {
     "agents": {
       "defaults": {
         "allowedTools": ["web_search", "web_fetch", "read", "write"]
       }
     }
   }
JSON
echo ""
echo "   Note: Explicitly list allowed tools (allowlist), not blocked tools (denylist)"
echo ""
echo "🛡️  Short-Term Mitigations"
echo "========================="
echo ""
echo "1. Monitor plugin health with cron:"
echo ""
cat <<'CRON'
   # Add to crontab
   */10 * * * * /path/to/detect-plugin-failures.sh | \
     grep "❌\|⚠️" && \
     echo "Plugin failure detected" | mail -s "OpenClaw Alert" admin@example.com
CRON
echo ""
echo "2. Implement plugin health check endpoint:"
echo "   curl http://localhost:3030/api/plugins/health"
echo ""
echo "3. Alert on plugin failures in logs:"
echo ""
cat <<'ALERT'
   journalctl --user -u openclaw-gateway -f | \
     grep -i "plugin.*fail" | \
     while read -r line; do
       echo "⚠️ Plugin failure: $line"
       # Send notification
     done
ALERT
echo ""
echo "4. Use gateway-level tool restrictions as backup:"
echo ""
echo "   Don't rely solely on plugins for critical security controls."
echo "   Gateway-level allowedTools acts as defense-in-depth."
echo ""
echo "🔧 Fixing Failed Plugins"
echo "========================"
echo ""
echo "Common failure reasons:"
echo ""
echo "1. Missing dependencies:"
echo "   cd ~/.openclaw/plugins/<plugin-name>"
echo "   npm install"
echo ""
echo "2. Version incompatibility:"
echo "   openclaw plugins update <plugin-name>"
echo ""
echo "3. Import errors (ESM vs CommonJS):"
echo "   Check plugin package.json for correct 'type' field"
echo ""
echo "4. Permission issues:"
echo "   chmod +x ~/.openclaw/plugins/<plugin-name>/*.js"
echo ""
echo "📚 Long-Term Fix (Core Changes Required)"
echo "========================================="
echo ""
echo "Required changes (not yet implemented):"
echo ""
echo "1. Plugin restriction manifests should persist"
echo "   - Store tool restrictions separately from plugin code"
echo "   - Apply restrictions even if plugin fails to load"
echo ""
echo "2. Fail-closed behavior by default"
echo "   - Failed plugin = automatic denial of its tools"
echo "   - Clear error in agent session: 'Tool blocked: plugin failed to load'"
echo ""
echo "3. Health endpoint for plugin status"
echo "   - GET /api/plugins/health returns status of each plugin"
echo "   - Programmatic detection of failures"
echo ""
echo "4. Validate plugin loads on gateway start"
echo "   - Fail to start if critical plugins don't load"
echo "   - Configure which plugins are critical"
echo ""
echo "📚 Related Documentation"
echo "========================"
echo ""
echo "- Security Hardening: docs/troubleshooting/security-hardening.md"
echo "- Plugin Development: docs/plugins/development.md"
echo "- Tool Restrictions: docs/gateway/tool-restrictions.md"
echo ""
echo "External Resources:"
echo "- Issue #20914: https://github.com/openclaw/openclaw/issues/20914"
echo "- Issue #20435: https://github.com/openclaw/openclaw/issues/20435"
echo ""

exit 1
