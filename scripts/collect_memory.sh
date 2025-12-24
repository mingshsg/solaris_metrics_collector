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

if [ "${ENABLE_MEMORY}" != "yes" ]; then
  log INFO "Memory collector disabled; exiting"
  exit 0
fi

memory_tot_bytes() {
  /usr/sbin/prtconf 2>/dev/null | awk '/Memory size:/ {printf "%.0f", $3*1024*1024}'
}

memory_free_bytes() {
  local pagesize free_pages
  pagesize=$(pagesize)
  free_pages=$(kstat -p unix:0:system_pages:freemem 2>/dev/null | awk '{print $2}')
  if [ -z "${free_pages}" ]; then
    echo "0"
  else
    echo $((free_pages * pagesize))
  fi
}

format_mib() {
  awk -v bytes="$1" 'BEGIN{printf "%.2f", bytes/1024/1024}'
}

main() {
  local now
  # ISO8601 UTC (Z). Safest for Elasticsearch date parsing
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local total_bytes free_bytes used_bytes util_pct
  total_bytes=$(memory_tot_bytes)
  free_bytes=$(memory_free_bytes)
  if [ -z "${total_bytes}" ] || [ "${total_bytes}" -eq 0 ]; then
    log ERROR "Unable to read total memory via prtconf"
    exit 1
  fi
  used_bytes=$((total_bytes - free_bytes))
  local util_decimal
  util_decimal=$(awk -v u="${used_bytes}" -v t="${total_bytes}" 'BEGIN{printf "%.4f", u/t}')

  local payload_file
  payload_file=$(mktemp /var/tmp/memory_payload.XXXXXX)

  {
    bulk_action_line
    printf '{'
    stream_ecs_json
    printf ',"@timestamp":"%s",' "${now}"
    printf '"event":{"dataset":"%s","module":"system","kind":"metric","category":["host"],"type":["info"]},' "${DATA_STREAM_DATASET}"
    printf '"metricset":{"module":"system"},'
    printf '%s,' "$(host_ecs_json)"
    printf '"solaris":{"collector":{"category":"memory"}},'
    printf '"system":{"memory":{'
    printf '"total":%s,' "${total_bytes}"
    printf '"free":%s,' "${free_bytes}"
    printf '"used":{"bytes":%s,"pct":%s},' "${used_bytes}" "${util_decimal}"
    printf '"actual":{"used":{"pct":%s}}' "${util_decimal}"
    printf '}}}\n'   # close memory, system, doc and end line
  } > "${payload_file}"

  send_or_buffer "${payload_file}"
  rm -f "${payload_file}"
}

main "$@"
