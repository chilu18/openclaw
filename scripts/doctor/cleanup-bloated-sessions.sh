#!/bin/bash
# Clean up bloated OpenClaw sessions that are stuck in death spiral
# Addresses #20910: Session bloat death spiral

set -e

echo "🧹 OpenClaw Session Cleanup Tool"
echo "================================"
echo ""

SESSIONS_DIR="${HOME}/.openclaw/agents/default/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
    echo "❌ Sessions directory not found: $SESSIONS_DIR"
    echo "   Check your agent ID and workspace location"
    exit 1
fi

echo "📂 Scanning: $SESSIONS_DIR"
echo ""

# Function to get session size in KB
get_session_size() {
    local session_file="$1"
    du -k "$session_file" | cut -f1
}

# Function to count turns in session
count_turns() {
    local session_file="$1"
    jq '.turns | length' "$session_file" 2>/dev/null || echo "0"
}

# Function to check if session had recent failures
check_failures() {
    local session_file="$1"
    # Check last 5 turns for errors
    jq -r '.turns[-5:] | .[] | select(.error) | .error' "$session_file" 2>/dev/null | head -5
}

# Thresholds
SIZE_THRESHOLD=5000  # KB (5MB)
TURN_THRESHOLD=100   # turns

BLOATED_SESSIONS=()
TOTAL_SIZE=0
SCANNED=0

echo "🔍 Analyzing sessions..."
echo ""

for session_file in "$SESSIONS_DIR"/*.json; do
    if [ ! -f "$session_file" ]; then
        continue
    fi

    SCANNED=$((SCANNED + 1))
    SESSION_NAME=$(basename "$session_file" .json)
    SIZE=$(get_session_size "$session_file")
    TURNS=$(count_turns "$session_file")

    TOTAL_SIZE=$((TOTAL_SIZE + SIZE))

    # Check if bloated
    if [ "$SIZE" -gt "$SIZE_THRESHOLD" ] || [ "$TURNS" -gt "$TURN_THRESHOLD" ]; then
        BLOATED_SESSIONS+=("$session_file|$SIZE|$TURNS")

        echo "⚠️  Bloated session: $SESSION_NAME"
        echo "   Size: ${SIZE}KB (threshold: ${SIZE_THRESHOLD}KB)"
        echo "   Turns: $TURNS (threshold: $TURN_THRESHOLD)"

        # Check for errors
        ERRORS=$(check_failures "$session_file")
        if [ -n "$ERRORS" ]; then
            echo "   Recent errors:"
            echo "$ERRORS" | sed 's/^/     /'
        fi
        echo ""
    fi
done

echo "📊 Summary"
echo "=========="
echo "Sessions scanned: $SCANNED"
echo "Total size: $((TOTAL_SIZE / 1024))MB"
echo "Bloated sessions: ${#BLOATED_SESSIONS[@]}"
echo ""

if [ "${#BLOATED_SESSIONS[@]}" -eq 0 ]; then
    echo "✅ No bloated sessions found!"
    echo ""
    echo "💡 Tip: Run this script regularly to catch session bloat early"
    exit 0
fi

# Ask for confirmation
echo "⚠️  Session Bloat Death Spiral Risk"
echo ""
echo "Bloated sessions often enter a death spiral:"
echo "1. Failed turn leaves large context"
echo "2. Next turn has less space for new content"
echo "3. Next turn guaranteed to fail (context overflow)"
echo "4. Cycle repeats until session is unusable"
echo ""
echo "Options:"
echo "  1) Archive and reset bloated sessions (recommended)"
echo "  2) Archive only (keep in backup folder)"
echo "  3) Delete bloated sessions (no backup)"
echo "  4) Cancel (no changes)"
echo ""

read -p "Choose option (1-4): " OPTION

case $OPTION in
    1)
        echo ""
        echo "🗄️  Archiving and resetting bloated sessions..."
        echo ""

        ARCHIVE_DIR="${HOME}/.openclaw/sessions-archive/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$ARCHIVE_DIR"

        for entry in "${BLOATED_SESSIONS[@]}"; do
            SESSION_FILE=$(echo "$entry" | cut -d'|' -f1)
            SESSION_NAME=$(basename "$SESSION_FILE")

            # Archive
            cp "$SESSION_FILE" "$ARCHIVE_DIR/"
            echo "✅ Archived: $SESSION_NAME → $ARCHIVE_DIR/"

            # Reset (create fresh empty session)
            SESSION_ID=$(basename "$SESSION_NAME" .json)
            cat > "$SESSION_FILE" <<EOF
{
  "id": "$SESSION_ID",
  "turns": [],
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "resetAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "resetReason": "Bloat cleanup - archived original"
}
EOF
            echo "♻️  Reset: $SESSION_NAME (fresh session created)"
            echo ""
        done

        echo "✅ Cleanup complete!"
        echo ""
        echo "Archived to: $ARCHIVE_DIR"
        echo "Sessions reset: ${#BLOATED_SESSIONS[@]}"
        ;;

    2)
        echo ""
        echo "🗄️  Archiving bloated sessions (no reset)..."
        echo ""

        ARCHIVE_DIR="${HOME}/.openclaw/sessions-archive/$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$ARCHIVE_DIR"

        for entry in "${BLOATED_SESSIONS[@]}"; do
            SESSION_FILE=$(echo "$entry" | cut -d'|' -f1)
            SESSION_NAME=$(basename "$SESSION_FILE")

            cp "$SESSION_FILE" "$ARCHIVE_DIR/"
            echo "✅ Archived: $SESSION_NAME → $ARCHIVE_DIR/"
        done

        echo ""
        echo "✅ Archive complete!"
        echo "   Original sessions unchanged"
        ;;

    3)
        echo ""
        echo "🗑️  Deleting bloated sessions (no backup)..."
        echo ""
        read -p "⚠️  Are you sure? This cannot be undone! (yes/no): " CONFIRM

        if [ "$CONFIRM" = "yes" ]; then
            for entry in "${BLOATED_SESSIONS[@]}"; do
                SESSION_FILE=$(echo "$entry" | cut -d'|' -f1)
                SESSION_NAME=$(basename "$SESSION_FILE")

                rm "$SESSION_FILE"
                echo "❌ Deleted: $SESSION_NAME"
            done
            echo ""
            echo "✅ Deletion complete"
        else
            echo "Cancelled"
        fi
        ;;

    4)
        echo "Cancelled"
        exit 0
        ;;

    *)
        echo "Invalid option"
        exit 1
        ;;
esac

echo ""
echo "💡 Prevention Tips"
echo "=================="
echo ""
echo "1. Enable automatic session reset on overflow:"
echo "   (Feature request #20910 - not yet implemented)"
echo ""
echo "2. Use shorter context windows for fallback models"
echo ""
echo "3. Monitor session sizes regularly:"
echo "   ./scripts/doctor/cleanup-bloated-sessions.sh"
echo ""
echo "4. Use /new command proactively when context gets large"
echo ""
echo "5. Configure max turns per session:"
echo "   {\"agents\": {\"defaults\": {\"maxTurnsPerSession\": 50}}}"
echo ""
