#!/usr/bin/env bash
# Boots a built Pinchflat image the way a real install would, and checks that upgrading
# and rolling back don't break the database.
#
# Usage: tooling/smoke_test.sh <new-image> [<previous-image>]
#   new-image       the image you want to deploy (eg: ghcr.io/you/pinchflat:sha-abc1234)
#   previous-image  the image you're running today (default: upstream's latest release)
#
# Checks, in order:
#   1. Fresh install: new image starts on an empty /config and becomes healthy
#   2. Upgrade:       previous image creates a DB, new image starts on that same DB
#                     (this is what happens when an existing install updates)
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
# Anything else that aborts the script (eg: an image pull) gets reported too
trap 'annotate "Smoke test aborted" "line $LINENO: $BASH_COMMAND"' ERR

log() { printf '\n=== %s\n' "$*"; }

start() {
  local image="$1" config="$2"
  CURRENT_IMAGE="$image"
  REASON=""
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
        REASON="container stopped after ${waited}s ($status)"
        echo "$REASON"
        return 1
        ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  REASON="not healthy after ${HEALTH_TIMEOUT}s (last status: $status)"
  echo "$REASON"
  return 1
}

REASON=""

check_running_app() {
  # Each check sets REASON so a failure says exactly what broke. (`set -e` doesn't apply
  # inside a function called from `if`, so every check returns explicitly.)
  local out
  docker exec "$NAME" curl -fsS "http://localhost:8945/healthcheck" >/dev/null ||
    { REASON="healthcheck endpoint failed"; return 1; }
  # The binaries downloads depend on
  out="$(docker exec "$NAME" yt-dlp --version 2>&1)" || { REASON="yt-dlp doesn't run: $out"; return 1; }
  echo "yt-dlp: $out"
  out="$(docker exec "$NAME" deno --version 2>&1)" || { REASON="deno doesn't run: $out"; return 1; }
  echo "deno:   $(head -1 <<<"$out")"
  out="$(docker exec "$NAME" ffmpeg -version 2>&1)" || { REASON="ffmpeg doesn't run: $(head -5 <<<"$out")"; return 1; }
  echo "ffmpeg: $(head -1 <<<"$out")"
  # Crashes during boot (eg: a bad migration) show up as Elixir errors in the log.
  # Ignored:
  #   - a pooled connection finding the DB busy while the first boot migrates it. The pool
  #     just retries it, and the app is already healthy by the time we get here.
  #   - yt-dlp's own exit codes (eg: `yt-dlp --update` rate-limited by GitHub on shared CI
  #     runners). Pinchflat handles those; they aren't app crashes.
  out="$(docker logs "$NAME" 2>&1 |
    grep -E '\*\* \(|\[error\].*(Migration|Ecto|exited)' |
    grep -vE 'failed to connect: \*\* \(Exqlite\.Error\) database is (locked|busy)' |
    grep -vF '[command_wrapper]' || true)"
  if [ -n "$out" ]; then
    REASON="errors in startup log: $(head -5 <<<"$out")"
    return 1
  fi
}

stop() { docker stop -t 30 "$NAME" >/dev/null; }

# In GitHub Actions, also raise the failure as an annotation: annotations show on the run's
# summary page and through the API, so the cause is readable without opening the full log.
annotate() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  local title="$1" msg="$2"
  msg="${msg//'%'/'%25'}"
  msg="${msg//$'\r'/'%0D'}"
  msg="${msg//$'\n'/'%0A'}"
  echo "::error title=${title}::${msg}"
}

fail() {
  local state logs
  state="$(docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} health={{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME" 2>&1 || true)"
  logs="$(docker logs --tail 80 "$NAME" 2>&1 || true)"
  echo "FAILED: $* ${REASON:+($REASON)}"
  echo "container: $state"
  echo "--- last 80 log lines ---"
  echo "$logs"
  annotate "Smoke test failed: $*" "${REASON:-no detail}
image: ${CURRENT_IMAGE:-?}
container: $state
--- last 30 log lines ---
$(tail -30 <<<"$logs")"
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
    # Not fatal: rollback is still possible by restoring a DB backup taken before
    # updating. Flag it loudly though.
    echo "WARNING: previous image can't run on the upgraded DB."
    echo "         Rolling back will need a database backup taken before the update."
    docker logs --tail 40 "$NAME" 2>&1 || true
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  log "SMOKE TEST FAILED"
  exit 1
fi
log "SMOKE TEST PASSED"
