#!/usr/bin/bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../scripts/common.sh
. "${SCRIPT_DIR}/common.sh"

# Parse CLI arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN="yes"; shift;;
    *) log WARN "Unknown argument: $1"; shift;;
  esac
done

if [ "${ENABLE_DISK}" != "yes" ]; then
  log INFO "Disk collector disabled; exiting"
  exit 0
fi

is_excluded_fs() {
  local fstype="$1"
  for t in ${EXCLUDE_FS_TYPES}; do
    if [ "${fstype}" = "${t}" ]; then
      return 0
    fi
  done
  return 1
}

collect_mount() {
  local mount_point="$1"
  local fstype="$2"
  local device="$3"

  local df_line
  df_line=$(df -k "${mount_point}" 2>/dev/null | tail -1)
  if [ -z "${df_line}" ]; then
    log WARN "df returned empty for ${mount_point}; skipping"
    return
  fi

  local kbytes used avail capacity
  kbytes=$(echo "${df_line}" | awk '{print $2}')
  used=$(echo "${df_line}" | awk '{print $3}')
  avail=$(echo "${df_line}" | awk '{print $4}')
  capacity=$(echo "${df_line}" | awk '{print $5}' | tr -d '%')

  if [ -z "${kbytes}" ] || [ "${kbytes}" -eq 0 ]; then
    log WARN "df reports zero size for ${mount_point}; skipping"
    return
  fi

  local total_bytes used_bytes free_bytes util_decimal
  total_bytes=$((kbytes * 1024))
  used_bytes=$((used * 1024))
  free_bytes=$((avail * 1024))
  util_decimal=$(awk -v u="${used}" -v t="${kbytes}" 'BEGIN{printf "%.4f", u/t}')

  local now
  # ISO8601 UTC (Z). Safest for Elasticsearch date parsing
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local payload_file
  payload_file=$(mktemp /var/tmp/disk_payload.XXXXXX)

  {
    bulk_action_line
    printf '{'
    stream_ecs_json
    printf ',"@timestamp":"%s",' "${now}"
    printf '"event":{"dataset":"%s","module":"system","kind":"metric","category":["host"],"type":["info"]},' "${DATA_STREAM_DATASET}"
    printf '"metricset":{"module":"system"},'
    printf '%s,' "$(host_ecs_json)"
    printf '"solaris":{"collector":{"category":"disk"}},'
    printf '"system":{"filesystem":{'
    printf '"device_name":"%s","mount_point":"%s","type":"%s",' "$(json_escape "${device}")" "$(json_escape "${mount_point}")" "${fstype}"
    printf '"total":%s,' "${total_bytes}"
    printf '"free":%s,' "${free_bytes}"
    printf '"used":{"bytes":%s,"pct":%s}' "${used_bytes}" "${util_decimal}"
    printf '}}}\n'   # close filesystem, system, doc and end line
  } > "${payload_file}"

  send_or_buffer "${payload_file}"
  rm -f "${payload_file}"
}

main() {
  while read -r special mountp fstype _; do
    if is_excluded_fs "${fstype}"; then
      log DEBUG "Skipping ${mountp} (fstype ${fstype})"
      continue
    fi
    collect_mount "${mountp}" "${fstype}" "${special}"
  done < /etc/mnttab
}

main "$@"
