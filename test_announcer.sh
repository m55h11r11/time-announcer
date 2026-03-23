#!/bin/bash
# Time Announcer Benchmark — monitors for 30 minutes and reports hits/misses
# Usage: ./test_announcer.sh [duration_minutes]

DURATION_MIN=${1:-30}
DURATION_SEC=$((DURATION_MIN * 60))
LOG_FILE="/tmp/time_announcer_test_$(date +%Y%m%d_%H%M%S).log"
START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION_SEC))

echo "╔══════════════════════════════════════════════╗"
echo "║     TIME ANNOUNCER BENCHMARK TEST            ║"
echo "╠══════════════════════════════════════════════╣"
echo "║ Duration: ${DURATION_MIN} minutes"
echo "║ Log file: $LOG_FILE"
echo "║ Started:  $(date '+%H:%M:%S')"
echo "║ Ends at:  $(date -v+${DURATION_MIN}M '+%H:%M:%S')"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Check if TimeAnnouncer is running
if ! pgrep -f TimeAnnouncer > /dev/null; then
    echo "❌ TimeAnnouncer is NOT running! Start it first."
    exit 1
fi
echo "✅ TimeAnnouncer is running (PID $(pgrep -f TimeAnnouncer))"
echo ""

# Check lid state
LID_STATE=$(ioreg -r -k AppleClamshellState -d 1 | grep AppleClamshellState | awk '{print $NF}')
echo "🖥  Lid state: $LID_STATE"
echo ""

# Calculate all expected 5-minute slots during the test window
declare -a EXPECTED_SLOTS
declare -A SLOT_STATUS

NOW_SEC=$(date +%s)
NOW_MIN=$(date +%M | sed 's/^0//')
NOW_SEC_OF_MIN=$(date +%S | sed 's/^0//')

# Next 5-min boundary
NEXT_SLOT_MIN=$(( (NOW_MIN / 5 + 1) * 5 ))
SECS_TO_NEXT=$(( (NEXT_SLOT_MIN - NOW_MIN) * 60 - NOW_SEC_OF_MIN ))
NEXT_SLOT_EPOCH=$(( NOW_SEC + SECS_TO_NEXT ))

# Build list of expected slots
SLOT_EPOCH=$NEXT_SLOT_EPOCH
while [ $SLOT_EPOCH -lt $END_TIME ]; do
    SLOT_TIME=$(date -r $SLOT_EPOCH '+%H:%M')
    EXPECTED_SLOTS+=("$SLOT_TIME")
    SLOT_STATUS["$SLOT_TIME"]="MISSED"
    SLOT_EPOCH=$((SLOT_EPOCH + 300))
done

TOTAL_EXPECTED=${#EXPECTED_SLOTS[@]}
echo "📋 Expected announcements: $TOTAL_EXPECTED"
echo "   Slots: ${EXPECTED_SLOTS[*]}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Monitoring... (press Ctrl+C to stop early and see results)"
echo ""

# Write header to log
echo "TIME_ANNOUNCER_TEST started at $(date)" > "$LOG_FILE"
echo "Expected slots: ${EXPECTED_SLOTS[*]}" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"

HITS=0
MISSES=0

# Trap Ctrl+C to show results
show_results() {
    echo ""
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║           BENCHMARK RESULTS                  ║"
    echo "╠══════════════════════════════════════════════╣"

    # Count final stats
    HITS=0
    MISSES=0
    for slot in "${EXPECTED_SLOTS[@]}"; do
        if [ "${SLOT_STATUS[$slot]}" = "HIT" ]; then
            HITS=$((HITS + 1))
        elif [ "${SLOT_STATUS[$slot]}" = "MISSED" ]; then
            # Only count as missed if the slot time has passed
            SLOT_EPOCH=$(date -j -f "%H:%M" "$slot" +%s 2>/dev/null)
            if [ $? -eq 0 ] && [ $(date +%s) -gt $((SLOT_EPOCH + 120)) ]; then
                MISSES=$((MISSES + 1))
            else
                SLOT_STATUS["$slot"]="PENDING"
            fi
        fi
    done

    CHECKED=$((HITS + MISSES))

    echo "║"
    for slot in "${EXPECTED_SLOTS[@]}"; do
        case "${SLOT_STATUS[$slot]}" in
            HIT)
                DELAY="${SLOT_DELAY[$slot]}"
                echo "║  ✅ $slot — announced (${DELAY}s after mark)"
                ;;
            MISSED)
                echo "║  ❌ $slot — MISSED"
                ;;
            PENDING)
                echo "║  ⏳ $slot — not yet reached"
                ;;
        esac
    done
    echo "║"
    echo "╠══════════════════════════════════════════════╣"

    if [ $CHECKED -gt 0 ]; then
        RATE=$((HITS * 100 / CHECKED))
        echo "║  Hits: $HITS / $CHECKED  ($RATE%)"
    else
        echo "║  No slots reached yet"
    fi
    echo "║  Missed: $MISSES"
    echo "║  Log: $LOG_FILE"
    echo "╚══════════════════════════════════════════════╝"

    echo "---" >> "$LOG_FILE"
    echo "RESULTS: $HITS hits, $MISSES misses out of $CHECKED checked" >> "$LOG_FILE"

    exit 0
}
trap show_results INT TERM

declare -A SLOT_DELAY

# Main monitoring loop
while [ $(date +%s) -lt $END_TIME ]; do
    CURRENT_MIN=$(date +%M | sed 's/^0//')
    CURRENT_SEC=$(date +%S | sed 's/^0//')
    CURRENT_HOUR=$(date +%H)
    CURRENT_SLOT=$(date '+%H:%M' -j -f "%H:%M:%S" "${CURRENT_HOUR}:$(printf '%02d' $((CURRENT_MIN / 5 * 5))):00" 2>/dev/null)

    # Are we in a 5-minute slot window (within first 2 min)?
    SLOT_OFFSET=$(( (CURRENT_MIN % 5) * 60 + CURRENT_SEC ))

    if [ $SLOT_OFFSET -ge 0 ] && [ $SLOT_OFFSET -le 120 ]; then
        # Check if audio is playing (say or AVSpeechSynthesizer)
        if [ "${SLOT_STATUS[$CURRENT_SLOT]}" = "MISSED" ]; then
            # Check if speech synthesis is active or say process ran
            SPEAKING=$(log show --last 5s --predicate 'process == "com.apple.speech.speechsynthesisd" OR process == "say"' 2>/dev/null | grep -c "speech" 2>/dev/null || echo "0")

            # Alternative: check if say process or speech is happening
            SAY_RUNNING=$(pgrep -c say 2>/dev/null || echo "0")

            # Also monitor the synthesizer by checking coreaudiod activity
            # Best approach: just check if we're past the slot mark and the app is healthy
            if [ $SLOT_OFFSET -le 5 ]; then
                # We're within 5 seconds of the mark — give it a moment
                sleep 2
                SLOT_OFFSET=$(( ($(date +%M | sed 's/^0//') % 5) * 60 + $(date +%S | sed 's/^0//') ))
            fi

            # If we're between 2-30 seconds into the slot, check for speech activity
            if [ $SLOT_OFFSET -ge 2 ] && [ $SLOT_OFFSET -le 30 ]; then
                # Check for any recent audio activity from our app
                APP_PID=$(pgrep -f TimeAnnouncer)
                if [ -n "$APP_PID" ]; then
                    # Check if com.apple.speech.speechsynthesisd has been active
                    SPEECH_ACTIVE=$(pgrep -c speechsynthesisd 2>/dev/null || echo "0")
                    SAY_ACTIVE=$(pgrep -c say 2>/dev/null || echo "0")

                    if [ "$SPEECH_ACTIVE" -gt 0 ] || [ "$SAY_ACTIVE" -gt 0 ]; then
                        SLOT_STATUS["$CURRENT_SLOT"]="HIT"
                        SLOT_DELAY["$CURRENT_SLOT"]="$SLOT_OFFSET"
                        HITS=$((HITS + 1))
                        echo "$(date '+%H:%M:%S') ✅ $CURRENT_SLOT announced (${SLOT_OFFSET}s after mark)"
                        echo "$(date '+%H:%M:%S') HIT $CURRENT_SLOT delay=${SLOT_OFFSET}s" >> "$LOG_FILE"
                    fi
                fi
            fi

            # If we're past 30 seconds and still no hit, mark it detected via process check
            if [ $SLOT_OFFSET -ge 30 ] && [ "${SLOT_STATUS[$CURRENT_SLOT]}" = "MISSED" ]; then
                # Final check — did the announcement happen?
                # We can verify by checking the app is still alive and kicking
                APP_PID=$(pgrep -f TimeAnnouncer)
                if [ -z "$APP_PID" ]; then
                    echo "$(date '+%H:%M:%S') ⚠️  TimeAnnouncer crashed or stopped!"
                    echo "$(date '+%H:%M:%S') CRASH detected" >> "$LOG_FILE"
                fi
            fi
        fi
    fi

    # If we're 120+ seconds past a slot and it's still MISSED, finalize it
    if [ $SLOT_OFFSET -ge 120 ] && [ "${SLOT_STATUS[$CURRENT_SLOT]}" = "MISSED" ]; then
        SLOT_STATUS["$CURRENT_SLOT"]="MISSED"
        MISSES=$((MISSES + 1))
        echo "$(date '+%H:%M:%S') ❌ $CURRENT_SLOT MISSED!"
        echo "$(date '+%H:%M:%S') MISS $CURRENT_SLOT" >> "$LOG_FILE"
        # Prevent re-counting
        SLOT_STATUS["$CURRENT_SLOT"]="MISS_COUNTED"
    fi

    sleep 3
done

show_results
