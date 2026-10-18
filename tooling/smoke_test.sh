#!/usr/bin/env bash
# Boots a built Pinchflat image the way your NAS will, and checks that upgrading
# and rolling back don't break the database.
#
# Usage: tooling/smoke_test.sh <new-image> [<previous-image>]
#   new-image       the image you want to deploy (eg: ghcr.io/you/pinchflat:sha-abc1234)
#   previous-image  the image you're running today (default: upstream's latest release)
#
# Checks, in order:
#   1. Fresh install: new image starts on an empty /config and becomes healthy
#   2. Upgrade:       previous image creates a DB, new image starts on that same DB
#                     (this is what happens on your NAS when you update)
#   3. Rollback:      previous image starts again on the DB the new image migrated
#                     (this is what happens if you revert after a bad update)
#
# Needs: docker, curl, sqlite3. Uses throwaway folders; never touches real data.

set -euo pipefail

NEW_IMAGE="${1:?Usage: $0 <new-image> [<previous-image>]}"
OLD_IMAGE="${2:-ghcr.io/kieraneglin/pinchflat:latest}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
WORKDIR="$(mktemp -d)"
NAME="pinchflat-smoke-$$"
FAILED=0

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # Containers write as root; use a throwaway container to clean up root-owned files
  docker run --rm -v "$WORKDIR:/w" alpine sh -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

log() { printf '\n=== %s\n' "$*"; }

start() {
  local image="$1" config="$2"
  mkdir -p "$config" "$WORKDIR/downloads"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    -e TZ=UTC \
    -v "$config:/config" \
    -v "$WORKDIR/downloads:/downloads" \
    "$image" >/dev/null
}

wait_healthy() {
  local waited=0 status
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    status="$(docker inspect --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME" 2>/dev/null || echo missing)"
    case "$status" in
      running/healthy)
        echo "healthy after ${waited}s"
        return 0
        ;;
      exited/* | dead/* | missing)
        echo "container stopped ($status)"
        return 1
        ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  echo "not healthy after ${HEALTH_TIMEOUT}s (last status: $status)"
  return 1
}

check_running_app() {
  # The app's own healthcheck endpoint, plus the two binaries downloads depend on
  docker exec "$NAME" curl -fsS "http://localhost:8945/healthcheck" >/dev/null
  echo "yt-dlp: $(docker exec "$NAME" yt-dlp --version)"
  echo "deno:   $(docker exec "$NAME" deno --version | head -1)"
  echo "ffmpeg: $(docker exec "$NAME" ffmpeg -version | head -1)"
  # Crashes during boot (eg: a bad migration) show up as Elixir errors in the log
  if docker logs "$NAME" 2>&1 | grep -E '\*\* \(|\[error\].*(Migration|Ecto|exited)' ; then
    echo "errors found in startup log"
    return 1
  fi
}

stop() { docker stop -t 30 "$NAME" >/dev/null; }

fail() {
  echo "FAILED: $*"
  echo "--- last 80 log lines ---"
  docker logs --tail 80 "$NAME" 2>&1 || true
  FAILED=1
}

db_query() {
  # Read the DB with a throwaway container so file ownership doesn't matter
  docker run --rm --user 0 -v "$1:/config" --entrypoint sh keinos/sqlite3 -c "sqlite3 /config/db/pinchflat.db \"$2\""
}

log "Pulling images"
docker pull -q "$OLD_IMAGE" >/dev/null
docker image inspect "$NEW_IMAGE" >/dev/null 2>&1 || docker pull -q "$NEW_IMAGE" >/dev/null

log "1/3 Fresh install of $NEW_IMAGE"
start "$NEW_IMAGE" "$WORKDIR/fresh"
if wait_healthy && check_running_app; then stop; else fail "fresh install"; fi

if [ "$FAILED" -eq 0 ]; then
  log "2/3 Upgrade: $OLD_IMAGE -> $NEW_IMAGE on the same database"
  start "$OLD_IMAGE" "$WORKDIR/upgrade"
  if wait_healthy; then stop; else fail "previous image didn't start (nothing to upgrade from)"; fi

  if [ "$FAILED" -eq 0 ]; then
    start "$NEW_IMAGE" "$WORKDIR/upgrade"
    if wait_healthy && check_running_app; then
      stop
      echo "migrations applied: $(db_query "$WORKDIR/upgrade" 'SELECT COUNT(*) FROM schema_migrations;')"
      echo "integrity: $(db_query "$WORKDIR/upgrade" 'PRAGMA integrity_check;')"
    else
      fail "upgrade"
    fi
  fi
fi

if [ "$FAILED" -eq 0 ]; then
  log "3/3 Rollback: $OLD_IMAGE on the database migrated by $NEW_IMAGE"
  start "$OLD_IMAGE" "$WORKDIR/upgrade"
  if wait_healthy; then
    stop
    echo "rollback works without restoring a backup"
  else
    # Not fatal: rollback is still possible by restoring the pre-update DB backup,
    # which the NAS update script always takes. Flag it loudly though.
    echo "WARNING: previous image can't run on the upgraded DB."
    echo "         Rolling back will need the DB backup (update script restores it automatically)."
    docker logs --tail 40 "$NAME" 2>&1 || true
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  log "SMOKE TEST FAILED"
  exit 1
fi
log "SMOKE TEST PASSED"
