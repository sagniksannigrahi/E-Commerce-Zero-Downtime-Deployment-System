#!/usr/bin/env bash
# Shows which colour is live, container status, and recent deployments.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deployment/lib.sh
source "$SCRIPT_DIR/lib.sh"

ACTIVE="$(active_color)"
echo "Live environment (from Nginx): $(upper "$ACTIVE")"
echo
for color in blue green; do
  port="$(port_for "$color")"
  marker="standby"; [ "$color" = "$ACTIVE" ] && marker="LIVE"
  body="$(curl -fsS --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null || echo 'not responding')"
  printf '  %-6s port %s  [%-7s]  %s\n' "$(upper "$color")" "$port" "$marker" "$body"
done
echo
docker ps -a --filter name=shopflow- --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
echo
echo "Through Nginx: $(curl -fsS --max-time 2 "$PUBLIC_HEALTH_URL" 2>/dev/null || echo 'not responding')"
if [ -f "$HISTORY_FILE" ]; then
  echo
  echo "Recent deployments:"
  tail -n 8 "$HISTORY_FILE" | sed 's/^/  /'
fi
