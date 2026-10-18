#!/usr/bin/env bash
# Discover labeled database containers and write gzipped SQL dumps.
# Usage:
#   ./scripts/backup-databases.sh
#   BACKUP_DIR=/path/to/backups BACKUP_POLICY=daily ./scripts/backup-databases.sh
set -euo pipefail

# Override dump root here (leave empty to use BACKUP_DIR env, repo .env, or ~/backups).
BACKUP_DIR_OVERRIDE="./backups"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

strip_quotes() {
  local value="${1:-}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "${value}"
}

resolve_backup_dir() {
  if [[ -n "${BACKUP_DIR_OVERRIDE}" ]]; then
    printf '%s' "${BACKUP_DIR_OVERRIDE}"
    return
  fi
  if [[ -n "${BACKUP_DIR:-}" ]]; then
    printf '%s' "${BACKUP_DIR}"
    return
  fi
  if [[ -f "${REPO_ROOT}/.env" ]]; then
    local from_env
    from_env="$(grep -E '^[[:space:]]*BACKUP_DIR=' "${REPO_ROOT}/.env" | tail -n1 | cut -d= -f2- || true)"
    from_env="$(strip_quotes "${from_env}")"
    if [[ -n "${from_env}" ]]; then
      printf '%s' "${from_env}"
      return
    fi
  fi
  printf '%s' "${HOME}/backups"
}

label_value() {
  local container="$1"
  local key="$2"
  local raw
  raw="$(docker inspect --format "{{index .Config.Labels \"${key}\"}}" "${container}")"
  strip_quotes "${raw}"
}

env_value() {
  local container="$1"
  local key="$2"
  docker exec "${container}" printenv "${key}" 2>/dev/null || true
}

BACKUP_DIR="$(resolve_backup_dir)"
OUT_DIR="${BACKUP_DIR}/databases"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
POLICY_FILTER="$(strip_quotes "${BACKUP_POLICY:-}")"

mkdir -p "${OUT_DIR}"

mapfile -t CONTAINERS < <(docker ps --filter 'label=io.cothrom.role="database"' --format '{{.Names}}' | sort)

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  echo "No running containers with io.cothrom.role=database found."
  exit 0
fi

failed=0
backed_up=0
skipped=0

for container in "${CONTAINERS[@]}"; do
  [[ -z "${container}" ]] && continue

  stack="$(label_value "${container}" "io.cothrom.stack")"
  engine="$(label_value "${container}" "io.cothrom.db.engine")"
  cmd="$(label_value "${container}" "io.cothrom.db.backup.command")"
  policy="$(label_value "${container}" "io.cothrom.backup.policy")"
  dbname="$(env_value "${container}" "POSTGRES_DB")"

  if [[ -z "${stack}" ]]; then
    stack="unknown"
  fi
  if [[ -z "${dbname}" ]]; then
    dbname="${container}"
  fi

  if [[ -n "${POLICY_FILTER}" && "${policy}" != "${POLICY_FILTER}" ]]; then
    echo "SKIP  ${container} (policy=${policy:-none}, want=${POLICY_FILTER})"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -z "${cmd}" ]]; then
    echo "FAIL  ${container}: missing io.cothrom.db.backup.command"
    failed=$((failed + 1))
    continue
  fi

  if [[ "${engine}" != "postgres" ]]; then
    echo "FAIL  ${container}: unsupported engine '${engine:-unset}' (only postgres)"
    failed=$((failed + 1))
    continue
  fi

  outfile="${OUT_DIR}/${TIMESTAMP}-${stack}-${dbname}.sql.gz"
  echo "DUMP  ${container} -> ${outfile}"

  if docker exec "${container}" bash -lc "set -euo pipefail; ${cmd}" | gzip >"${outfile}"; then
    if [[ ! -s "${outfile}" ]]; then
      echo "FAIL  ${container}: empty dump written"
      rm -f "${outfile}"
      failed=$((failed + 1))
      continue
    fi
    size="$(du -h "${outfile}" | cut -f1)"
    echo "OK    ${container} (${size})"
    backed_up=$((backed_up + 1))
  else
    echo "FAIL  ${container}: dump command failed"
    rm -f "${outfile}"
    failed=$((failed + 1))
  fi
done

echo "Done: ${backed_up} backed up, ${skipped} skipped, ${failed} failed -> ${OUT_DIR}"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
