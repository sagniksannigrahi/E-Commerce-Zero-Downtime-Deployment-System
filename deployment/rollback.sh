#!/usr/bin/env bash
# =============================================================================
# ShopFlow instant rollback
#
# After a deployment the previous colour is kept running as a hot standby.
# This script switches Nginx back to it - no rebuild, takes ~2 seconds.
#
#   1. Find the active colour and the standby colour.
#   2. Health-check the standby. If it is not healthy, do nothing.
#   3. Atomically switch Nginx to the standby and reload gracefully.
#   4. Verify through Nginx; if that fails, restore the previous config.
#
# Usage:  rollback.sh
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deployment/lib.sh
source "$SCRIPT_DIR/lib.sh"

acquire_lock

ACTIVE="$(active_color)"
[ "$ACTIVE" != "none" ] || die "Nginx is not pointing at any environment - nothing to roll back."
STANDBY="$(other_color "$ACTIVE")"

echo "============================================================"
echo " ShopFlow Rollback: $(upper "$ACTIVE") -> $(upper "$STANDBY")"
echo "============================================================"

step "1/3 Checking that the standby $(upper "$STANDBY") environment is healthy"
HEALTH_RETRIES="${ROLLBACK_HEALTH_RETRIES:-3}"
if ! health_check "$STANDBY"; then
  record_history ROLLBACK_REFUSED "standby=$STANDBY not healthy; active=$ACTIVE"
  die "Standby $(upper "$STANDBY") is not running/healthy, so rollback is not possible. $(upper "$ACTIVE") is still live."
fi

step "2/3 Switching Nginx traffic to $(upper "$STANDBY")"
switch_traffic "$STANDBY" || die "Nginx switch failed; previous configuration restored."

step "3/3 Verifying through Nginx"
if ! verify_public "$STANDBY"; then
  restore_upstream || true
  record_history ROLLBACK_FAILED "standby=$STANDBY; restored=$ACTIVE"
  die "Verification failed - restored $(upper "$ACTIVE")."
fi

echo "$STANDBY" > "$STATE_DIR/active_color"
record_history ROLLBACK "active=$STANDBY previous=$ACTIVE"
echo
echo "============================================================"
echo " ROLLBACK COMPLETE: $(upper "$STANDBY") is live again"
echo " ($(upper "$ACTIVE") is still running - run rollback.sh again to undo)"
echo "============================================================"
