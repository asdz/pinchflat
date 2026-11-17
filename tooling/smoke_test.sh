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
#   4. Slow query:    a database query that runs past its timeout only fails that one
#                     query. It must not take the whole app down
#
# Needs: docker, curl, sqlite3. Uses throwaway folders; never touches real data.
#
# Set SLOW_QUERY_CHECK=warn to report a failed check 4 without failing the run.

set -euo pipefail

NEW_IMAGE="${1:?Usage: $0 <new-image> [<previous-image>]}"
OLD_IMAGE="${2:-ghcr.io/kieraneglin/pinchflat:latest}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
SLOW_QUERY_CHECK="${SLOW_QUERY_CHECK:-fail}"
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

# On large libraries and slow disks a query can outlive its timeout. The database driver
# then closes that connection while the query is still running. Older driver versions
# (exqlite < 0.37) crashed the whole Erlang VM when the abandoned query finally finished,
# which showed up as the container restarting for no logged reason. So: run a query that
# takes far longer than its timeout, give it time to finish, and make sure the app is still
# there and still able to use its database.
check_slow_query_survival() {
  local out status
  # Counting to 150 million takes SQLite tens of seconds; the timeout is 1 second.
  out="$(timeout 300 docker exec "$NAME" /app/bin/pinchflat rpc '
    sql = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 150000000) SELECT count(*) FROM c"
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        case Ecto.Adapters.SQL.query(Pinchflat.Repo, sql, [], timeout: 1_000, log: false) do
          {:ok, _} -> "finished"
          {:error, _} -> "was abandoned"
        end
      rescue
        _ -> "raised"
      catch
        _, _ -> "exited"
      end

    IO.puts("slow query #{outcome} after #{System.monotonic_time(:millisecond) - started}ms")
  ' 2>&1)" || true
  echo "$out"
  SLOW_QUERY_RESULT="$(grep '^slow query ' <<<"$out" | tail -1 || true)"

  # Old drivers crash when the abandoned query completes, which can be a little after the
  # command above returns. Give it a moment, then look.
  sleep 30
  status="$(docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
  [ "$status" = "running" ] ||
    { REASON="${SLOW_QUERY_RESULT:-slow query never returned}, and the app died (container $status)"; return 1; }
  [ -n "$SLOW_QUERY_RESULT" ] ||
    { REASON="couldn't run the slow query inside the container: $(tail -3 <<<"$out")"; return 1; }
  docker exec "$NAME" curl -fsS "http://localhost:8945/healthcheck" >/dev/null ||
    { REASON="$SLOW_QUERY_RESULT, then the healthcheck stopped answering"; return 1; }
  out="$(timeout 60 docker exec "$NAME" /app/bin/pinchflat rpc \
    'IO.puts("db ok: #{inspect(Pinchflat.Repo.query!("SELECT 1").rows)}")' 2>&1)" || true
  grep -q '^db ok: ' <<<"$out" ||
    { REASON="$SLOW_QUERY_RESULT, then the database stopped answering: $(tail -3 <<<"$out")"; return 1; }
  echo "$SLOW_QUERY_RESULT; app and database still fine afterwards"
  annotate "Slow query check passed" "$SLOW_QUERY_RESULT; app and database still fine afterwards ($CURRENT_IMAGE)" notice
}

stop() { docker stop -t 30 "$NAME" >/dev/null; }

# In GitHub Actions, also raise the failure as an annotation: annotations show on the run's
# summary page and through the API, so the cause is readable without opening the full log.
annotate() {
  [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  local title="$1" msg="$2" level="${3:-error}"
  msg="${msg//'%'/'%25'}"
  msg="${msg//$'\r'/'%0D'}"
  msg="${msg//$'\n'/'%0A'}"
  echo "::${level} title=${title}::${msg}"
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

log "1/4 Fresh install of $NEW_IMAGE"
start "$NEW_IMAGE" "$WORKDIR/fresh"
if wait_healthy && check_running_app; then stop; else fail "fresh install"; fi

if [ "$FAILED" -eq 0 ]; then
  log "2/4 Upgrade: $OLD_IMAGE -> $NEW_IMAGE on the same database"
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
  log "3/4 Rollback: $OLD_IMAGE on the database migrated by $NEW_IMAGE"
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

if [ "$FAILED" -eq 0 ]; then
  log "4/4 Slow query: $NEW_IMAGE must survive a query that outlives its timeout"
  start "$NEW_IMAGE" "$WORKDIR/fresh"
  if wait_healthy && check_slow_query_survival; then
    stop
  elif [ "$SLOW_QUERY_CHECK" = "warn" ]; then
    echo "WARNING (not failing the run): ${REASON:-no detail}"
    annotate "Slow query check failed (warning only)" "${REASON:-no detail}
--- last 15 log lines ---
$(docker logs --tail 15 "$NAME" 2>&1 || true)" warning
  else
    fail "slow query"
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  log "SMOKE TEST FAILED"
  exit 1
fi
log "SMOKE TEST PASSED"
