#!/bin/bash
HOUR=$(date '+%-I')
MINUTE=$(date '+%-M')

if [ "$MINUTE" -eq 0 ]; then
    say "${HOUR} o'clock"
else
    say "${HOUR} ${MINUTE}"
fi
