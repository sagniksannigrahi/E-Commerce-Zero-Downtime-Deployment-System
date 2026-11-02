#!/usr/bin/env bash
# Shared helpers for deploy.sh, rollback.sh and status.sh.
# Every path/command can be overridden with an environment variable, which
# lets the automated tests run these scripts with fake docker/curl/nginx.

SHOPFLOW_HOME="${SHOPFLOW_HOME:-/opt/shopflow}"
STATE_DIR="$SHOPFLOW_HOME/state"
STATE_ENV="$STATE_DIR/compose.env"          # SECRET_KEY, BLUE_IMAGE, GREEN_IMAGE
LOCK_DIR="$STATE_DIR/deploy.lock"
HISTORY_FILE="$STATE_DIR/deployments.log"
UPSTREAM_BACKUP="$STATE_DIR/active_upstream.conf.previous"

NGINX_UPSTREAM_FILE="${NGINX_UPSTREAM_FILE:-/etc/nginx/shopflow/active_upstream.conf}"
NGINX_TEST_CMD="${NGINX_TEST_CMD:-sudo -n nginx -t -q}"
NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-sudo -n systemctl reload nginx}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-http://127.0.0.1/health}"

HEALTH_RETRIES="${HEALTH_RETRIES:-30}"     # 30 x 2s = up to 60s for a new container
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-10}"   # checks through Nginx after switching
VERIFY_REQUIRED="${VERIFY_REQUIRED:-3}"    # consecutive successes needed
VERIFY_INTERVAL="${VERIFY_INTERVAL:-1}"

COMPOSE_PROJECT="shopflow"

# ------------------------------------------------------------------ logging
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ colours
port_for() {
  case "$1" in
    blue)  echo 5001 ;;
    green) echo 5002 ;;
    *) die "unknown colour '$1'" ;;
  esac
}

other_color() {
  case "$1" in
    blue)  echo green ;;
    green) echo blue ;;
    *) die "unknown colour '$1'" ;;
  esac
}

upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

# The Nginx upstream file is the single source of truth for which colour
# is receiving live traffic.
active_color() {
  if [ ! -f "$NGINX_UPSTREAM_FILE" ]; then
    echo none
  elif grep -q '127\.0\.0\.1:5001' "$NGINX_UPSTREAM_FILE"; then
    echo blue
  elif grep -q '127\.0\.0\.1:5002' "$NGINX_UPSTREAM_FILE"; then
    echo green
  else
    echo none
  fi
}

# ------------------------------------------------------------------ locking
# mkdir is atomic: only one process can create the directory, so only one
# deployment (or rollback) can run at a time.
release_lock() { rm -rf "$LOCK_DIR"; }

acquire_lock() {
  mkdir -p "$STATE_DIR"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local holder
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ps -p "$holder" >/dev/null 2>&1; then
      die "Another deployment is already running (PID $holder). Refusing to start a second one."
    fi
    warn "Removing stale lock left behind by PID ${holder:-unknown}"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || die "Could not acquire deployment lock"
  fi
  echo $$ > "$LOCK_DIR/pid"
  trap release_lock EXIT
}

# ------------------------------------------------------------------ state env file
env_get() {  # env_get KEY
  [ -f "$STATE_ENV" ] || return 0
  grep -E "^$1=" "$STATE_ENV" | tail -n 1 | cut -d= -f2-
}

env_set() {  # env_set KEY VALUE   (rewrites the file atomically)
  local tmp
  tmp="$(mktemp "$STATE_DIR/.compose.env.XXXXXX")"
  if [ -f "$STATE_ENV" ]; then
    grep -vE "^$1=" "$STATE_ENV" > "$tmp" || true
  fi
  echo "$1=$2" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_ENV"
}

ensure_state_env() {
  mkdir -p "$STATE_DIR"
  if [ -z "$(env_get SECRET_KEY)" ]; then
    log "Generating a persistent SECRET_KEY (shared by blue and green)"
    env_set SECRET_KEY "$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  [ -n "$(env_get BLUE_IMAGE)" ]  || env_set BLUE_IMAGE  "shopflow:none"
  [ -n "$(env_get GREEN_IMAGE)" ] || env_set GREEN_IMAGE "shopflow:none"
}

# ------------------------------------------------------------------ docker
compose() {  # compose <compose-file> <args...>
  local file="$1"; shift
  docker compose -p "$COMPOSE_PROJECT" -f "$file" --env-file "$STATE_ENV" "$@"
}

# ------------------------------------------------------------------ health checks
# health_check COLOUR [EXPECTED_RELEASE]
# Calls the container directly (bypassing Nginx) until it reports healthy.
health_check() {
  local color="$1" expected="${2:-}" port body i
  port="$(port_for "$color")"
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    if body="$(curl -fsS --max-time 3 "http://127.0.0.1:$port/health" 2>/dev/null)" \
       && echo "$body" | grep -q '"status": *"healthy"' \
       && echo "$body" | grep -q "\"color\": *\"$color\"" \
       && { [ -z "$expected" ] || echo "$body" | grep -qF "$expected"; }; then
      log "Health check PASSED for $(upper "$color") on port $port (attempt $i): $body"
      return 0
    fi
    log "  $(upper "$color") not healthy yet (attempt $i/$HEALTH_RETRIES)"
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

# verify_public COLOUR [EXPECTED_RELEASE]
# Calls the app THROUGH Nginx and requires several consecutive answers from
# the expected colour - proves the switch really happened.
verify_public() {
  local color="$1" expected="${2:-}" body i streak=0
  for i in $(seq 1 "$VERIFY_ATTEMPTS"); do
    if body="$(curl -fsS --max-time 3 "$PUBLIC_HEALTH_URL" 2>/dev/null)" \
       && echo "$body" | grep -q "\"color\": *\"$color\"" \
       && { [ -z "$expected" ] || echo "$body" | grep -qF "$expected"; }; then
      streak=$((streak + 1))
      if [ "$streak" -ge "$VERIFY_REQUIRED" ]; then
        log "Verified through Nginx: $VERIFY_REQUIRED consecutive responses from $(upper "$color")"
        return 0
      fi
    else
      streak=0
    fi
    sleep "$VERIFY_INTERVAL"
  done
  return 1
}

# ------------------------------------------------------------------ nginx switching
write_upstream() {  # write_upstream COLOUR   (atomic: write temp file, then rename)
  local color="$1" port tmp
  port="$(port_for "$color")"
  tmp="$(mktemp "$(dirname "$NGINX_UPSTREAM_FILE")/.active_upstream.XXXXXX")"
  printf '# Managed by ShopFlow deploy.sh - do not edit by hand\n# active colour: %s\nserver 127.0.0.1:%s;\n' \
    "$color" "$port" > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$NGINX_UPSTREAM_FILE"
}

reload_nginx() {
  $NGINX_TEST_CMD && $NGINX_RELOAD_CMD
}

restore_upstream() {
  if [ ! -f "$UPSTREAM_BACKUP" ]; then
    warn "No previous Nginx upstream backup to restore"
    return 1
  fi
  local tmp
  tmp="$(mktemp "$(dirname "$NGINX_UPSTREAM_FILE")/.active_upstream.XXXXXX")"
  cp "$UPSTREAM_BACKUP" "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$NGINX_UPSTREAM_FILE"
  if reload_nginx; then
    log "Restored previous Nginx upstream ($(active_color)) and reloaded Nginx"
  else
    warn "Restored previous upstream file but Nginx reload failed - check 'sudo nginx -t'"
    return 1
  fi
}

switch_traffic() {  # switch_traffic COLOUR
  local color="$1"
  if [ -f "$NGINX_UPSTREAM_FILE" ]; then
    cp "$NGINX_UPSTREAM_FILE" "$UPSTREAM_BACKUP"
  fi
  write_upstream "$color"
  if ! reload_nginx; then
    warn "Nginx rejected the new configuration - restoring the previous one"
    restore_upstream || true
    return 1
  fi
  log "Nginx now sends traffic to $(upper "$color") (port $(port_for "$color")) - reloaded gracefully"
}

record_history() {  # record_history RESULT DETAILS...
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "${*:2}" >> "$HISTORY_FILE"
}
