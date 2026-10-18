#!/bin/sh
# Safe update / rollback for Pinchflat on a Synology (or any Docker host using compose).
#
# Put this file in the same folder as your docker-compose.yml (eg: /volume1/docker/pinchflat)
# and run it over SSH as root (sudo -i):
#
#   sh pinchflat-update.sh update     # back up DB, pull new image, restart, auto-revert if unhealthy
#   sh pinchflat-update.sh rollback   # go back to the previous image and the DB from before the update
#   sh pinchflat-update.sh rollback-keep-db  # previous image, keep today's DB (keeps videos indexed since)
#   sh pinchflat-update.sh status     # show running image, health and available backups
#
# What "update" does:
#   1. Remembers the image you're running now (tagged locally as pinchflat-rollback:previous)
#   2. Pulls the image your docker-compose.yml points at (eg: ghcr.io/<you>/pinchflat:stable)
#   3. Stops Pinchflat and copies its database to <config>/db-backups/
#   4. Starts the new image and waits for Docker's healthcheck to say "healthy"
#   5. If it never gets healthy: restores the DB copy and starts the previous image again
#
# Can be scheduled weekly in DSM: Control Panel > Task Scheduler > Create > Scheduled Task >
# User-defined script, user root, command: sh /volume1/docker/pinchflat/pinchflat-update.sh update

set -eu

SERVICE="${SERVICE:-pinchflat}"            # service name in docker-compose.yml
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"    # seconds to wait for "healthy"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"
ROLLBACK_TAG="pinchflat-rollback:previous"
COMPOSE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$COMPOSE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# DSM ships either the compose plugin or the standalone binary depending on version
if docker compose version >/dev/null 2>&1; then
  compose() { docker compose "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  compose() { docker-compose "$@"; }
else
  die "docker compose not found"
fi

[ -f docker-compose.yml ] || [ -f compose.yaml ] || [ -f docker-compose.yaml ] ||
  die "no compose file in $COMPOSE_DIR - put this script next to your docker-compose.yml"

container_id() { compose ps -a -q "$SERVICE" 2>/dev/null | head -n1; }

configured_image() {
  # The image reference written in docker-compose.yml for this service,
  # falling back to whatever the existing container was created from
  img="$(compose config 2>/dev/null | awk -v svc="  $SERVICE:" '
    $0 == svc { in_svc = 1; next }
    in_svc && /^  [^ ]/ { in_svc = 0 }
    in_svc && $1 == "image:" { gsub(/["\047]/, "", $2); print $2; exit }')"
  if [ -z "$img" ] && [ -n "$(container_id)" ]; then
    img="$(docker inspect -f '{{.Config.Image}}' "$(container_id)")"
  fi
  echo "$img"
}

config_dir() {
  # Host folder mounted at /config, read from the container itself
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$1"
}

health() {
  docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo missing
}

wait_healthy() {
  waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    cid="$(container_id)"
    status="$(health "$cid")"
    case "$status" in
      running/healthy) log "Healthy after ${waited}s"; return 0 ;;
      exited/* | dead/* | missing) log "Container stopped ($status)"; return 1 ;;
    esac
    sleep 10
    waited=$((waited + 10))
  done
  log "Not healthy after ${HEALTH_TIMEOUT}s (last: $status)"
  return 1
}

backup_db() {
  cfg="$1"
  mkdir -p "$cfg/db-backups"
  file="$cfg/db-backups/pinchflat-db-$(date '+%Y%m%d-%H%M%S').tar.gz"
  # Container is stopped, so the db + WAL files are consistent
  tar -czf "$file" -C "$cfg" db
  log "Database backed up to $file ($(du -h "$file" | cut -f1))"
  # Prune old backups
  ls -1t "$cfg"/db-backups/pinchflat-db-*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))" | while read -r old; do
    rm -f "$old"
  done
  echo "$file" > "$cfg/db-backups/LAST_BACKUP"
}

restore_db() {
  cfg="$1"
  file="$(cat "$cfg/db-backups/LAST_BACKUP" 2>/dev/null || true)"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    die "no backup recorded in $cfg/db-backups/LAST_BACKUP"
  fi
  log "Restoring database from $file"
  # Keep the broken DB around in case it's needed for debugging
  [ -d "$cfg/db" ] && mv "$cfg/db" "$cfg/db.failed-$(date '+%Y%m%d-%H%M%S')"
  tar -xzf "$file" -C "$cfg"
}

start_previous_image() {
  image="$(configured_image)"
  docker image inspect "$ROLLBACK_TAG" >/dev/null 2>&1 || die "no previous image saved ($ROLLBACK_TAG)"
  log "Starting previous image as $image"
  # Point the compose image name at the old image locally, so compose starts it without pulling
  docker tag "$ROLLBACK_TAG" "$image"
  compose up -d --pull never "$SERVICE" 2>/dev/null || compose up -d "$SERVICE"
}

do_rollback() {
  keep_db="${1:-no}"
  cid="$(container_id)"
  [ -n "$cid" ] || die "no $SERVICE container found"
  cfg="$(config_dir "$cid")"
  [ -n "$cfg" ] || die "couldn't find the /config folder of the container"
  compose stop "$SERVICE"
  if [ "$keep_db" = "keep-db" ]; then
    log "Keeping the current database (CI checks that the previous image can read it)"
  else
    restore_db "$cfg"
  fi
  start_previous_image
  if wait_healthy; then
    log "Rollback complete. Note: the next 'docker compose pull' will fetch the newer image again."
  else
    die "previous image isn't healthy either - check: docker logs $cid"
  fi
}

do_update() {
  image="$(configured_image)"
  [ -n "$image" ] || die "couldn't read the image for service '$SERVICE' from the compose file"
  cid="$(container_id)"
  [ -n "$cid" ] || die "no $SERVICE container found - start it once with: docker compose up -d"
  cfg="$(config_dir "$cid")"
  [ -n "$cfg" ] || die "couldn't find the /config folder of the container"

  old_id="$(docker inspect -f '{{.Image}}' "$cid")"
  log "Running image: $(docker inspect -f '{{.Config.Image}}' "$cid") ($old_id)"

  log "Pulling $image"
  compose pull "$SERVICE"
  new_id="$(docker image inspect -f '{{.Id}}' "$image")"
  if [ "$new_id" = "$old_id" ]; then
    log "Already up to date"
    exit 0
  fi

  docker tag "$old_id" "$ROLLBACK_TAG"
  log "Saved current image as $ROLLBACK_TAG"

  compose stop "$SERVICE"
  backup_db "$cfg"

  log "Starting new image"
  compose up -d "$SERVICE"
  if wait_healthy; then
    log "Update complete. Roll back any time with: sh $0 rollback"
  else
    log "New image is unhealthy - last log lines:"
    docker logs --tail 40 "$(container_id)" 2>&1 || true
    log "Rolling back automatically"
    compose stop "$SERVICE"
    restore_db "$cfg"
    start_previous_image
    wait_healthy || die "rollback also failed - check docker logs"
    die "update failed and was rolled back (exit code 1 so Task Scheduler reports it)"
  fi
}

do_status() {
  cid="$(container_id)"
  [ -n "$cid" ] || die "no $SERVICE container found"
  cfg="$(config_dir "$cid")"
  echo "Compose image : $(configured_image)"
  echo "Running image : $(docker inspect -f '{{.Config.Image}} ({{.Image}})' "$cid")"
  echo "Health        : $(health "$cid")"
  echo "yt-dlp        : $(docker exec "$cid" yt-dlp --version 2>/dev/null || echo '?')"
  echo "Rollback image: $(docker image inspect -f '{{.Id}}' "$ROLLBACK_TAG" 2>/dev/null || echo none)"
  echo "Config folder : $cfg"
  echo "Backups:"
  ls -1t "$cfg"/db-backups/pinchflat-db-*.tar.gz 2>/dev/null | sed 's/^/  /' || echo "  none"
}

case "${1:-}" in
  update) do_update ;;
  rollback) do_rollback ;;
  rollback-keep-db) do_rollback keep-db ;;
  status) do_status ;;
  *) echo "Usage: sh $0 {update|rollback|rollback-keep-db|status}"; exit 2 ;;
esac
