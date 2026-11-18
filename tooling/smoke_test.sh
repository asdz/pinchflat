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
#   4. Slow queries:  database queries that run past their timeout are cancelled and only
#                     fail themselves. They must not take the whole app down
#
# Needs: docker, curl, sqlite3. Uses throwaway folders; never touches real data.
#
# Set SLOW_QUERY_COMPARE=1 to also run check 4 against the previous image. That's for
# comparison only: the result is reported and never fails the run.

set -euo pipefail

NEW_IMAGE="${1:?Usage: $0 <new-image> [<previous-image>]}"
OLD_IMAGE="${2:-ghcr.io/kieraneglin/pinchflat:latest}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"
SLOW_QUERY_ROUNDS="${SLOW_QUERY_ROUNDS:-20}"
SLOW_QUERY_COMPARE="${SLOW_QUERY_COMPARE:-}"
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
# then closes that connection while the query is still running on it. With older driver
# versions (exqlite < 0.37) the query carried on regardless, and when it finished there was a
# chance of it touching the closed connection and crashing the whole Erlang VM. Nothing was
# logged; the container just restarted. Newer versions cancel the query first.
#
# So: run queries that need seconds but are only allowed 300ms, alternating between one that
# returns a single row at the very end and one that returns rows throughout. Then make sure
# every one of them was cancelled, and that the app and its database are still there.
#
# Sets SLOW_QUERY_RESULT (what happened) and, on failure, REASON.
check_slow_query_survival() {
  local out status abandoned
  SLOW_QUERY_RESULT=""
  out="$(timeout 600 docker exec "$NAME" /app/bin/pinchflat rpc '
    numbers = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10000000)"
    one_row_at_the_end = numbers <> " SELECT count(*) FROM c"
    rows_throughout = numbers <> " SELECT x FROM c WHERE x % 50000 = 0"
    started = System.monotonic_time(:millisecond)

    outcomes =
      for round <- 1..'"$SLOW_QUERY_ROUNDS"' do
        sql = if rem(round, 2) == 0, do: one_row_at_the_end, else: rows_throughout

        outcome =
          try do
            case Ecto.Adapters.SQL.query(Pinchflat.Repo, sql, [], timeout: 300, log: false) do
              {:ok, _} -> :completed
              {:error, _} -> :cancelled
            end
          rescue
            _ -> :cancelled
          catch
            _, _ -> :cancelled
          end

        # Gives the pool a moment to replace the connection that was just closed
        Process.sleep(250)
        outcome
      end

    cancelled = Enum.count(outcomes, &(&1 == :cancelled))
    elapsed = System.monotonic_time(:millisecond) - started
    IO.puts("slow queries: #{cancelled} of #{length(outcomes)} cancelled at their timeout, in #{elapsed}ms")
  ' 2>&1)" || true
  echo "$out"
  SLOW_QUERY_RESULT="$(grep '^slow queries: ' <<<"$out" | tail -1 || true)"

  # A crash can land slightly after the last query returns. Give it a moment, then look.
  sleep 10
  status="$(docker inspect --format '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"
  if [ "$status" != "running" ]; then
    REASON="the app died while running queries that outlive their timeout (container $status)"
    SLOW_QUERY_RESULT="$REASON"
    return 1
  fi
  [ -n "$SLOW_QUERY_RESULT" ] ||
    { REASON="couldn't run the slow queries inside the container: $(tail -3 <<<"$out")"; return 1; }
  docker exec "$NAME" curl -fsS "http://localhost:8945/healthcheck" >/dev/null ||
    { REASON="$SLOW_QUERY_RESULT, then the healthcheck stopped answering"; return 1; }
  out="$(timeout 60 docker exec "$NAME" /app/bin/pinchflat rpc \
    'IO.puts("db ok: #{inspect(Pinchflat.Repo.query!("SELECT 1").rows)}")' 2>&1)" || true
  grep -q '^db ok: ' <<<"$out" ||
    { REASON="$SLOW_QUERY_RESULT, then the database stopped answering: $(tail -3 <<<"$out")"; return 1; }
  SLOW_QUERY_RESULT="$SLOW_QUERY_RESULT; app and database fine afterwards"
  abandoned="$(sed -E 's/^slow queries: ([0-9]+) of ([0-9]+) .*/\1 \2/' <<<"$SLOW_QUERY_RESULT")"
  [ "${abandoned% *}" = "${abandoned#* }" ] ||
    { REASON="$SLOW_QUERY_RESULT, but queries that outlive their timeout should all be cancelled"; return 1; }
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
  log "4/4 Slow queries: $NEW_IMAGE must cancel and survive queries that outlive their timeout"
  start "$NEW_IMAGE" "$WORKDIR/fresh"
  if wait_healthy && check_slow_query_survival; then
    echo "$SLOW_QUERY_RESULT"
    annotate "Slow query check passed" "$SLOW_QUERY_RESULT ($CURRENT_IMAGE)" notice
    stop
  else
    fail "slow queries"
  fi
fi

if [ "$FAILED" -eq 0 ] && [ -n "$SLOW_QUERY_COMPARE" ]; then
  log "For comparison only: the same slow queries against $OLD_IMAGE"
  start "$OLD_IMAGE" "$WORKDIR/compare"
  if wait_healthy; then
    check_slow_query_survival || true
    echo "previous image: ${SLOW_QUERY_RESULT:-$REASON}"
    annotate "Slow queries on the previous image (comparison only)" "${SLOW_QUERY_RESULT:-$REASON} ($CURRENT_IMAGE)
--- last 12 log lines ---
$(docker logs --tail 12 "$NAME" 2>&1 || true)" notice
  else
    echo "previous image didn't start; nothing to compare"
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

if [ "$FAILED" -ne 0 ]; then
  log "SMOKE TEST FAILED"
  exit 1
fi
log "SMOKE TEST PASSED"
