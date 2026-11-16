#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 tyrael9 <https://github.com/tyrael9>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Deploy and roll back PartyBot test images without touching the database.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$PROJECT_DIR/.partybot"
ACTIVE_OVERRIDE="$STATE_DIR/active.override.yaml"
ROLLBACK_OVERRIDE="$STATE_DIR/rollback.override.yaml"
HEALTH_TIMEOUT="${PARTYBOT_HEALTH_TIMEOUT:-600}"
IMAGE_REPOSITORY="ghcr.io/tyrael9/vmangos-server"

log() { printf '[partybot] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
[[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] && (( HEALTH_TIMEOUT > 0 )) || die "PARTYBOT_HEALTH_TIMEOUT must be a positive integer."

usage() {
  cat <<'USAGE'
Usage:
  scripts/partybot-deploy.sh deploy <image-tag>
  scripts/partybot-deploy.sh status
  scripts/partybot-deploy.sh rollback
  scripts/partybot-deploy.sh logs [tail-lines]

Examples:
  scripts/partybot-deploy.sh deploy partybot-daba395
  scripts/partybot-deploy.sh status
  scripts/partybot-deploy.sh rollback
  scripts/partybot-deploy.sh logs 200

Only the mangosd and realmd services are changed. Database services and
volumes are never recreated by this script.
USAGE
}

for command in docker python3; do
  command -v "$command" >/dev/null 2>&1 || die "Required command not found: $command"
done

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

# Resolve the same Compose file set used by Docker Compose. COMPOSE_FILE may
# contain multiple files separated by COMPOSE_PATH_SEPARATOR (':' on Linux).
declare -a BASE_COMPOSE_FILES=()
if [[ -n "${COMPOSE_FILE:-}" ]]; then
  separator="${COMPOSE_PATH_SEPARATOR:-:}"
  IFS="$separator" read -r -a configured_files <<< "$COMPOSE_FILE"
  for file in "${configured_files[@]}"; do
    [[ -n "$file" ]] || continue
    if [[ "$file" = /* ]]; then
      resolved="$file"
    else
      resolved="$PROJECT_DIR/$file"
    fi
    [[ -f "$resolved" ]] || die "Compose file not found: $resolved"
    BASE_COMPOSE_FILES+=("$resolved")
  done
else
  compose_file=""
  compose_override=""
  for candidate in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    if [[ -f "$PROJECT_DIR/$candidate" ]]; then
      compose_file="$PROJECT_DIR/$candidate"
      case "$candidate" in
        compose.yaml) compose_override="$PROJECT_DIR/compose.override.yaml" ;;
        compose.yml) compose_override="$PROJECT_DIR/compose.override.yml" ;;
        docker-compose.yaml) compose_override="$PROJECT_DIR/docker-compose.override.yaml" ;;
        docker-compose.yml) compose_override="$PROJECT_DIR/docker-compose.override.yml" ;;
      esac
      break
    fi
  done
  [[ -n "$compose_file" ]] || die "No Compose file found in $PROJECT_DIR"
  BASE_COMPOSE_FILES+=("$compose_file")
  [[ -f "$compose_override" ]] && BASE_COMPOSE_FILES+=("$compose_override")
fi

compose_with_override() {
  local override="$1"
  shift
  local -a args=(docker compose --project-directory "$PROJECT_DIR")
  local file
  for file in "${BASE_COMPOSE_FILES[@]}"; do
    args+=(-f "$file")
  done
  if [[ -n "$override" ]]; then
    [[ -f "$override" ]] || die "Compose override not found: $override"
    args+=(-f "$override")
  fi
  "${args[@]}" "$@"
}

compose_base() { compose_with_override "" "$@"; }
compose_active() {
  if [[ -f "$ACTIVE_OVERRIDE" ]]; then
    compose_with_override "$ACTIVE_OVERRIDE" "$@"
  else
    compose_base "$@"
  fi
}

require_server_services() {
  local services
  services="$(compose_active config --services)" || die "Could not resolve Compose services."
  local service
  for service in mangosd realmd; do
    grep -Fxq "$service" <<< "$services" || die "Compose service '$service' is missing."
  done
}

# Print only service names and image references; do not expose resolved env vars.
read_server_images() {
  local config_json
  config_json="$(compose_active config --format json)" || die "Could not read effective Compose configuration."
  python3 -c '
import json, sys
config = json.load(sys.stdin)
for name in ("mangosd", "realmd"):
    image = config.get("services", {}).get(name, {}).get("image")
    if not image:
        raise SystemExit(f"Missing image for {name}")
    print(name + "\t" + image)
' <<< "$config_json"
}

valid_image_ref() {
  [[ "$1" =~ ^[A-Za-z0-9._/:@-]+$ ]]
}

write_override() {
  local path="$1" mangos_image="$2" realmd_image="$3"
  valid_image_ref "$mangos_image" || die "Unsafe image reference: $mangos_image"
  valid_image_ref "$realmd_image" || die "Unsafe image reference: $realmd_image"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  local tmp
  tmp="$(mktemp "$STATE_DIR/.override.XXXXXX")"
  cat > "$tmp" <<EOF_OVERRIDE
services:
  mangosd:
    image: $mangos_image
  realmd:
    image: $realmd_image
EOF_OVERRIDE
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

wait_for_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local all_healthy service container status health
  log "Waiting up to ${HEALTH_TIMEOUT}s for mangosd and realmd health checks..."
  while (( SECONDS < deadline )); do
    all_healthy=1
    for service in mangosd realmd; do
      container="$(compose_active ps -q "$service")"
      if [[ -z "$container" ]]; then
        all_healthy=0
        continue
      fi
      status="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || true)"
      health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
      if [[ "$status" == exited || "$status" == dead ]]; then
        log "$service container is $status. Recent logs:"
        compose_active logs --tail=100 "$service" || true
        return 1
      fi
      if [[ "$health" == unhealthy ]]; then
        log "$service health check is unhealthy. Recent logs:"
        compose_active logs --tail=100 "$service" || true
        return 1
      fi
      if [[ "$status" != running || ( "$health" != healthy && "$health" != none ) ]]; then
        all_healthy=0
      fi
    done
    if (( all_healthy )); then
      log "Both server services are healthy."
      return 0
    fi
    sleep 5
  done
  log "Health check timed out. Current status and recent logs:"
  compose_active ps || true
  compose_active logs --tail=100 mangosd realmd || true
  return 1
}

do_deploy() {
  local tag="$1"
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "Invalid image tag: $tag"
  local image="$IMAGE_REPOSITORY:$tag"

  require_server_services

  local current_images
  current_images="$(read_server_images)" || die "Could not determine current server images."
  local mangos_current="" realmd_current=""
  while IFS=$'\t' read -r service current_image; do
    case "$service" in
      mangosd) mangos_current="$current_image" ;;
      realmd) realmd_current="$current_image" ;;
    esac
  done <<< "$current_images"
  [[ -n "$mangos_current" && -n "$realmd_current" ]] || die "Could not determine both current image references."

  log "Current mangosd image: $mangos_current"
  log "Current realmd image: $realmd_current"
  log "Pulling $image ..."
  docker pull "$image"
  local architecture
  architecture="$(docker image inspect --format '{{.Architecture}}' "$image")"
  [[ "$architecture" == arm64 ]] || die "Expected an ARM64 image, got: $architecture"

  # Save the currently effective images first, so rollback remains available
  # even if container recreation or startup fails.
  write_override "$ROLLBACK_OVERRIDE" "$mangos_current" "$realmd_current"
  write_override "$ACTIVE_OVERRIDE" "$image" "$image"
  compose_active config --quiet || die "Generated Compose override is invalid."

  log "Recreating only mangosd and realmd (no dependencies)."
  compose_active up -d --no-deps --pull never mangosd realmd
  wait_for_health || die "Deployment did not become healthy. Run 'rollback' or inspect logs."
  log "Deployed $image successfully."
}

do_rollback() {
  [[ -f "$ACTIVE_OVERRIDE" ]] || die "No active PartyBot override exists; nothing to roll back."
  [[ -f "$ROLLBACK_OVERRIDE" ]] || die "No rollback image is recorded."
  require_server_services

  log "Restoring the previous mangosd and realmd images."
  # Reuse the previously pulled image locally; do not refresh a mutable tag.
  compose_with_override "$ROLLBACK_OVERRIDE" up -d --no-deps --pull missing mangosd realmd
  wait_for_health || die "Rollback did not become healthy. Inspect logs before retrying."

  # Keep the just-replaced version as the next rollback target (toggle).
  local tmp="$STATE_DIR/.active.swap"
  cp "$ACTIVE_OVERRIDE" "$tmp"
  cp "$ROLLBACK_OVERRIDE" "$ACTIVE_OVERRIDE.tmp"
  mv -f "$ACTIVE_OVERRIDE.tmp" "$ACTIVE_OVERRIDE"
  mv -f "$tmp" "$ROLLBACK_OVERRIDE"
  log "Rollback completed. Run 'status' to confirm the active images."
}

do_status() {
  require_server_services
  log "Effective image references:"
  read_server_images | while IFS=$'\t' read -r service image; do
    printf '  %-8s %s\n' "$service" "$image"
  done
  printf '\n'
  compose_active ps
  if [[ -f "$ROLLBACK_OVERRIDE" ]]; then
    log "A rollback image set is recorded in $ROLLBACK_OVERRIDE."
  else
    log "No rollback image set has been recorded yet."
  fi
}

case "${1:-help}" in
  deploy)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    do_deploy "$2"
    ;;
  status)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    do_status
    ;;
  rollback)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    do_rollback
    ;;
  logs)
    [[ $# -le 2 ]] || { usage; exit 2; }
    tail_lines="${2:-100}"
    [[ "$tail_lines" =~ ^[0-9]+$ ]] || die "Tail line count must be an integer."
    compose_active logs --tail="$tail_lines" mangosd realmd
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "Unknown command: $1"
    ;;
esac
