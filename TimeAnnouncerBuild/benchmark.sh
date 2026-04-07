#!/bin/bash
# Time Announcer Benchmark — reads the app's log and reports hits/misses
# Usage: ./benchmark.sh           (analyze all log data)
#        ./benchmark.sh 60        (analyze last 60 minutes)
#        ./benchmark.sh live      (watch live, report as slots pass)

LOG="/Users/mshrmnsr/Scripts/TimeAnnouncerBuild/announcer.log"

if [ ! -f "$LOG" ]; then
    echo "❌ No log file found. Is TimeAnnouncer running?"
    echo "   Expected: $LOG"
    exit 1
fi

MODE="${1:-all}"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║        TIME ANNOUNCER BENCHMARK                  ║"
echo "╠══════════════════════════════════════════════════╣"
echo ""

# Show all log events
if [ "$MODE" = "live" ]; then
    echo "  📡 Live monitoring — watching log for announcements..."
    echo "  Press Ctrl+C to stop and see summary."
    echo ""
    echo "  ── Events ──"
    tail -f "$LOG" | while read -r line; do
        if echo "$line" | grep -q "ANNOUNCE"; then
            SLOT=$(echo "$line" | grep -oE 'slot=[0-9:]+' | cut -d= -f2)
            DELAY=$(echo "$line" | grep -oE 'delay=[0-9]+' | cut -d= -f2)
            echo "  ✅ $(date '+%H:%M:%S') Announced $SLOT (${DELAY}s delay)"
        elif echo "$line" | grep -q "LID_CLOSED"; then
            echo "  💤 $(date '+%H:%M:%S') Lid closed — paused"
        elif echo "$line" | grep -q "LID_OPENED"; then
            echo "  🖥  $(date '+%H:%M:%S') Lid opened — resumed"
        elif echo "$line" | grep -q "SCREEN_SLEEP"; then
            echo "  😴 $(date '+%H:%M:%S') Screen sleep"
        elif echo "$line" | grep -q "SCREEN_WAKE"; then
            echo "  ☀️  $(date '+%H:%M:%S') Screen wake"
        elif echo "$line" | grep -q "LAUNCH"; then
            echo "  🚀 $(date '+%H:%M:%S') App launched"
        fi
    done
    exit 0
fi

# Analyze mode — parse all ANNOUNCE entries
if [ "$MODE" = "all" ]; then
    FILTER_AFTER="1970-01-01"
else
    # Last N minutes
    FILTER_AFTER=$(date -v-${MODE}M '+%Y-%m-%dT%H:%M:%S')
fi

echo "  📋 Log file: $LOG"
echo "  📊 Analyzing: $([ "$MODE" = "all" ] && echo "all data" || echo "last ${MODE} minutes")"
echo ""

# Extract all ANNOUNCE events
ANNOUNCES=$(grep "ANNOUNCE" "$LOG" | while read -r line; do
    TS=$(echo "$line" | awk '{print $1}')
    SLOT=$(echo "$line" | grep -oE 'slot=[0-9:]+' | cut -d= -f2)
    DELAY=$(echo "$line" | grep -oE 'delay=[0-9]+' | cut -d= -f2)
    echo "$TS $SLOT $DELAY"
done)

if [ -z "$ANNOUNCES" ]; then
    echo "  ⚠️  No announcements found in log yet."
    echo "  Let the app run for a few 5-minute cycles, then try again."
    exit 0
fi

# Get time range from log
FIRST_TS=$(grep "ANNOUNCE\|LAUNCH" "$LOG" | head -1 | awk '{print $1}')
LAST_TS=$(grep "ANNOUNCE\|LAUNCH" "$LOG" | tail -1 | awk '{print $1}')
FIRST_TIME=$(echo "$FIRST_TS" | sed 's/T/ /' | cut -d. -f1 | awk '{print $2}')
LAST_TIME=$(echo "$LAST_TS" | sed 's/T/ /' | cut -d. -f1 | awk '{print $2}')

echo "  ⏰ First event: $FIRST_TIME"
echo "  ⏰ Last event:  $LAST_TIME"
echo ""

# Count announcements and analyze delays
TOTAL=0
ON_TIME=0    # delay <= 3s
LATE=0       # delay 3-30s
VERY_LATE=0  # delay > 30s
MAX_DELAY=0
TOTAL_DELAY=0

echo "  ── Announcements ──"
echo "$ANNOUNCES" | while read -r TS SLOT DELAY; do
    TIME=$(echo "$TS" | sed 's/T/ /' | cut -d. -f1 | awk '{print $2}')
    if [ "$DELAY" -le 3 ]; then
        ICON="✅"
    elif [ "$DELAY" -le 30 ]; then
        ICON="🟡"
    else
        ICON="🔴"
    fi
    echo "  $ICON $SLOT announced at $TIME (${DELAY}s delay)"
done

echo ""

# Stats
TOTAL=$(echo "$ANNOUNCES" | wc -l | tr -d ' ')
ON_TIME=$(echo "$ANNOUNCES" | awk '$3 <= 3' | wc -l | tr -d ' ')
LATE=$(echo "$ANNOUNCES" | awk '$3 > 3 && $3 <= 30' | wc -l | tr -d ' ')
VERY_LATE=$(echo "$ANNOUNCES" | awk '$3 > 30' | wc -l | tr -d ' ')
MAX_DELAY=$(echo "$ANNOUNCES" | awk '{print $3}' | sort -n | tail -1)
AVG_DELAY=$(echo "$ANNOUNCES" | awk '{sum+=$3; n++} END {if(n>0) printf "%.1f", sum/n; else print "0"}')

# Check for gaps (missed slots)
echo "  ── Gap Analysis ──"
PREV_SLOT=""
GAPS=0
echo "$ANNOUNCES" | awk '{print $2}' | sort -u | while read -r SLOT; do
    if [ -n "$PREV_SLOT" ]; then
        # Convert HH:MM to minutes
        PREV_H=$(echo "$PREV_SLOT" | cut -d: -f1 | sed 's/^0//')
        PREV_M=$(echo "$PREV_SLOT" | cut -d: -f2 | sed 's/^0//')
        CURR_H=$(echo "$SLOT" | cut -d: -f1 | sed 's/^0//')
        CURR_M=$(echo "$SLOT" | cut -d: -f2 | sed 's/^0//')

        PREV_TOTAL=$((PREV_H * 60 + PREV_M))
        CURR_TOTAL=$((CURR_H * 60 + CURR_M))
        DIFF=$((CURR_TOTAL - PREV_TOTAL))

        # Handle midnight wrap
        if [ $DIFF -lt 0 ]; then DIFF=$((DIFF + 1440)); fi

        if [ $DIFF -gt 5 ]; then
            MISSED=$(( (DIFF / 5) - 1 ))
            echo "  ❌ GAP: $PREV_SLOT → $SLOT (${DIFF}min, ~${MISSED} missed slots)"
            GAPS=$((GAPS + MISSED))
        fi
    fi
    PREV_SLOT="$SLOT"
done

echo ""
echo "  ── Summary ──"
echo "  Total announcements: $TOTAL"
echo "  ✅ On time (≤3s):    $ON_TIME"
echo "  🟡 Late (3-30s):     $LATE"
echo "  🔴 Very late (>30s): $VERY_LATE"
echo "  📊 Avg delay:        ${AVG_DELAY}s"
echo "  📊 Max delay:        ${MAX_DELAY}s"
echo ""
echo "╚══════════════════════════════════════════════════╝"
