#!/usr/bin/env bash
# =============================================================================
# ShopFlow Blue-Green deployment
#
#   1. Find the ACTIVE colour (the one Nginx sends traffic to).
#   2. Build the new image and start it in the INACTIVE colour.
#      The active colour keeps serving users the whole time.
#   3. Health-check the new container directly.
#        - unhealthy -> stop it, leave traffic alone, exit with an error.
#   4. Atomically point Nginx at the new colour and reload gracefully.
#   5. Verify the switch through Nginx.
#        - failure -> restore the previous Nginx upstream (automatic rollback).
#   6. Keep the old colour running so `rollback.sh` can switch back instantly.
#
# Usage:  deploy.sh [--simulate-failure]
#   --simulate-failure   build a deliberately broken release (its /health
#                        returns 503) to demonstrate that traffic is NOT switched.
#
# Environment: APP_VERSION, BUILD_SHA (set by GitHub Actions).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=deployment/lib.sh
source "$SCRIPT_DIR/lib.sh"

SIMULATE_UNHEALTHY=false
for arg in "$@"; do
  case "$arg" in
    --simulate-failure) SIMULATE_UNHEALTHY=true ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg" ;;
  esac
done

APP_VERSION="${APP_VERSION:-$(cat "$RELEASE_DIR/VERSION" 2>/dev/null || echo dev)}"
BUILD_SHA="${BUILD_SHA:-manual}"
RELEASE_ID="${BUILD_SHA}-$(date -u '+%Y%m%d%H%M%S')"
IMAGE="shopflow:${RELEASE_ID}"
COMPOSE_FILE="$RELEASE_DIR/docker-compose.yml"

acquire_lock
ensure_state_env

ACTIVE="$(active_color)"
if [ "$ACTIVE" = "none" ]; then
  TARGET="blue"
else
  TARGET="$(other_color "$ACTIVE")"
fi
TARGET_UP="$(upper "$TARGET")"
TARGET_PORT="$(port_for "$TARGET")"
TARGET_IMAGE_KEY="${TARGET_UP}_IMAGE"
PREVIOUS_TARGET_IMAGE="$(env_get "$TARGET_IMAGE_KEY")"
ACTIVE_NOTE="keeps serving users during the deployment"
if [ "$ACTIVE" = "none" ] || ! curl -fsS --max-time 2 "http://127.0.0.1:$(port_for "$ACTIVE")/health" >/dev/null 2>&1; then
  ACTIVE_NOTE="not running (first deployment)"
fi

echo "============================================================"
echo " ShopFlow Blue-Green Deployment"
echo "   Version  : v$APP_VERSION  (build $BUILD_SHA)"
echo "   Release  : $RELEASE_ID"
echo "   Active   : $(upper "$ACTIVE") -> $ACTIVE_NOTE"
echo "   Target   : $TARGET_UP (port $TARGET_PORT)"
[ "$SIMULATE_UNHEALTHY" = "true" ] && echo "   MODE     : SIMULATED FAILURE (this release is broken on purpose)"
echo "============================================================"

stop_target() {
  log "Stopping $TARGET_UP container (it never received live traffic)"
  docker stop "shopflow-$TARGET" >/dev/null 2>&1 || true
  env_set "$TARGET_IMAGE_KEY" "$PREVIOUS_TARGET_IMAGE"
}

# -------------------------------------------------------------- 1. build
step "1/6 Building image $IMAGE"
docker build -t "$IMAGE" \
  --build-arg APP_VERSION="$APP_VERSION" \
  --build-arg BUILD_SHA="$BUILD_SHA" \
  --build-arg RELEASE_ID="$RELEASE_ID" \
  --build-arg SIMULATE_UNHEALTHY="$SIMULATE_UNHEALTHY" \
  "$RELEASE_DIR"

# -------------------------------------------------------------- 2. start inactive colour
step "2/6 Starting $TARGET_UP environment (the $(upper "$ACTIVE") environment is untouched)"
env_set "$TARGET_IMAGE_KEY" "$IMAGE"
if ! compose "$COMPOSE_FILE" up -d --no-deps --no-build --force-recreate "shopflow-$TARGET"; then
  stop_target
  record_history FAILED "start $TARGET release=$RELEASE_ID"
  die "Could not start the $TARGET_UP container. Traffic was NOT switched."
fi

# -------------------------------------------------------------- 3. health check
step "3/6 Health-checking $TARGET_UP directly on http://127.0.0.1:$TARGET_PORT/health"
if ! health_check "$TARGET" "$RELEASE_ID"; then
  warn "New release failed its health check. Last container logs:"
  docker logs --tail 20 "shopflow-$TARGET" 2>&1 || true
  stop_target
  record_history FAILED_HEALTHCHECK "target=$TARGET release=$RELEASE_ID active=$ACTIVE"
  die "Deployment ABORTED. Traffic was NOT switched - users are still served by $(upper "$ACTIVE")."
fi

# -------------------------------------------------------------- 4. switch traffic
step "4/6 Switching Nginx traffic $(upper "$ACTIVE") -> $TARGET_UP"
if ! switch_traffic "$TARGET"; then
  stop_target
  record_history FAILED_SWITCH "target=$TARGET release=$RELEASE_ID"
  die "Nginx switch failed. Previous configuration restored; $(upper "$ACTIVE") still live."
fi

# -------------------------------------------------------------- 5. verify through nginx
step "5/6 Verifying live traffic through Nginx ($PUBLIC_HEALTH_URL)"
if ! verify_public "$TARGET" "$RELEASE_ID"; then
  warn "Verification through Nginx failed - AUTOMATIC ROLLBACK"
  restore_upstream || warn "Rollback of Nginx config failed - manual attention needed"
  stop_target
  record_history ROLLED_BACK "target=$TARGET release=$RELEASE_ID restored=$ACTIVE"
  die "Deployment rolled back. $(upper "$ACTIVE") is serving traffic again."
fi

# -------------------------------------------------------------- 6. finish
step "6/6 Finishing up"
echo "$TARGET" > "$STATE_DIR/active_color"
record_history SUCCESS "active=$TARGET release=$RELEASE_ID version=$APP_VERSION previous=$ACTIVE"
if [ "$ACTIVE" != "none" ]; then
  log "$(upper "$ACTIVE") is kept running as a hot standby -> run rollback.sh to switch back instantly"
fi

# Remove images that are no longer used by either colour (saves disk on t3.micro)
KEEP_BLUE="$(env_get BLUE_IMAGE)"
KEEP_GREEN="$(env_get GREEN_IMAGE)"
for img in $(docker images shopflow --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true); do
  if [ "$img" != "$KEEP_BLUE" ] && [ "$img" != "$KEEP_GREEN" ]; then
    docker rmi "$img" >/dev/null 2>&1 && log "Removed old image $img" || true
  fi
done
docker image prune -f >/dev/null 2>&1 || true

# Keep only the 5 most recent release directories
if [ -d "$SHOPFLOW_HOME/releases" ]; then
  ls -1dt "$SHOPFLOW_HOME"/releases/*/ 2>/dev/null | tail -n +6 | while read -r old; do
    [ "${old%/}" != "$RELEASE_DIR" ] && rm -rf "${old%/}" && log "Removed old release dir $old"
  done || true
fi

echo
echo "============================================================"
echo " DEPLOYMENT SUCCESSFUL: v$APP_VERSION is live on $TARGET_UP"
echo "============================================================"
