#!/usr/bin/env bash
# Measures downtime on the server itself: sends ~10 requests/second through
# Nginx while a deployment runs, then reports how many failed.
#
#   zero-downtime-check.sh start    # begin sending requests in the background
#   zero-downtime-check.sh stop     # stop, print a summary, exit 1 if any failed
set -uo pipefail

LOG="${ZDT_LOG:-/tmp/shopflow-zdt.log}"
PID_FILE="${LOG}.pid"
URL="${ZDT_URL:-http://127.0.0.1/api/status}"

case "${1:-}" in
  start)
    rm -f "$LOG"
    nohup bash -c '
      while true; do
        body="$(curl -s --max-time 3 -w " HTTP%{http_code}" "'"$URL"'")"
        code="${body##* HTTP}"
        color="$(echo "$body" | grep -o "\"color\":\"[a-z]*\"" | cut -d\" -f4)"
        version="$(echo "$body" | grep -o "\"version\":\"[^\"]*\"" | cut -d\" -f4)"
        echo "$(date +%H:%M:%S.%N | cut -c1-12) $code ${color:--} ${version:--}"
        sleep 0.1
      done' > "$LOG" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 1
    echo "Traffic monitor started (PID $(cat "$PID_FILE")) -> $URL"
    ;;
  stop)
    [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
    total="$(wc -l < "$LOG" | tr -d ' ')"
    failed="$(awk '$2 != 200' "$LOG" | wc -l | tr -d ' ')"
    echo "============================================================"
    echo " Zero-downtime check: $total requests, $failed failed"
    echo "============================================================"
    echo "Responses by environment/version:"
    awk '{print "  " $3, "v" $4}' "$LOG" | sort | uniq -c
    echo "Moments the serving environment changed:"
    awk '{k=$3" "$4} k!=p {print "  " $1, $3, "v" $4; p=k}' "$LOG"
    if [ "$failed" -gt 0 ]; then
      echo "Failed requests:"; awk '$2 != 200' "$LOG" | head -20
      exit 1
    fi
    echo "RESULT: ZERO failed requests during the deployment"
    ;;
  *)
    echo "Usage: $0 start|stop"; exit 2 ;;
esac
