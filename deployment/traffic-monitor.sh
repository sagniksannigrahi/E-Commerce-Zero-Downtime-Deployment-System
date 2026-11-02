#!/usr/bin/env bash
# Sends a request every 0.25s and prints which colour answered.
# Run it in a separate terminal during a deployment to PROVE zero downtime.
#
# Usage: deployment/traffic-monitor.sh [URL]      (default http://3.80.226.178)
URL="${1:-http://3.80.226.178}"
ok=0; fail=0
trap 'echo; echo "Summary: $ok successful, $fail failed requests"; exit 0' INT
echo "Monitoring $URL/api/status (Ctrl+C to stop)"
while true; do
  body="$(curl -s -o - -w ' HTTP%{http_code}' --max-time 3 "$URL/api/status" 2>/dev/null)"
  code="${body##* HTTP}"
  if [ "$code" = "200" ]; then
    ok=$((ok + 1))
    color="$(echo "$body" | grep -o '"color": *"[a-z]*"' | grep -o '[a-z]*"$' | tr -d '"')"
    version="$(echo "$body" | grep -o '"version": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')"
    printf '%s  200  %-5s  v%-8s ok=%d fail=%d\n' "$(date '+%H:%M:%S')" "$color" "$version" "$ok" "$fail"
  else
    fail=$((fail + 1))
    printf '%s  %s  FAILED            ok=%d fail=%d\n' "$(date '+%H:%M:%S')" "${code:-ERR}" "$ok" "$fail"
  fi
  sleep 0.25
done
