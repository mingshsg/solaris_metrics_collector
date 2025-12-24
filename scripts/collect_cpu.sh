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

if [ "${ENABLE_CPU}" != "yes" ]; then
  log INFO "CPU collector disabled; exiting"
  exit 0
fi

compute_utilization_pct() {
  # Use mpstat to get CPU utilization (5 second sample for better accuracy)
  # Output format: CPU minf mjf xcal  intr ithr  csw icsw migr smtx  srw syscl  usr sys  wt idl
  # Last field is idle percentage
  local idle_pct
  idle_pct=$(mpstat 5 1 2>/dev/null | tail -1 | awk '{print $NF}')
  
  if [ -z "${idle_pct}" ] || [ "${idle_pct}" = "idl" ]; then
    log ERROR "Unable to read CPU idle percentage via mpstat"
    echo "null"
    return
  fi
  
  log DEBUG "mpstat idle=${idle_pct}%"
  
  # Calculate utilization as (100 - idle) / 100 for 0-1 scale with 6 decimals
  awk -v idl="${idle_pct}" 'BEGIN{printf "%.6f", (100.0 - idl) / 100.0}'
}

load_averages() {
  # Outputs three comma-separated load averages
  /usr/bin/uptime | awk -F'load average: ' '{print $2}' | tr -d ' ' \
    | awk -F',' '{printf "%s %s %s\n", $1, $2, $3}'
}

logical_cores() {
  /usr/sbin/psrinfo | /usr/bin/wc -l | awk '{print $1}'
}

main() {
  local now
  # ISO8601 UTC (Z). Safest for Elasticsearch date parsing
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local load1 load5 load15
  read -r load1 load5 load15 <<EOF
$(load_averages)
EOF
  local cores
  cores=$(logical_cores)
  local util_pct
  util_pct=$(compute_utilization_pct)

  local payload_file
  payload_file=$(mktemp /var/tmp/cpu_payload.XXXXXX)

  {
    bulk_action_line
    printf '{'
    stream_ecs_json
    printf ',"@timestamp":"%s",' "${now}"
    printf '"event":{"dataset":"%s","module":"system","kind":"metric","category":["host"],"type":["info"]},' "${DATA_STREAM_DATASET}"
    printf '"metricset":{"module":"system"},'
    printf '%s,' "$(host_ecs_json)"
    printf '"solaris":{"collector":{"category":"cpu"}},'
    printf '"system":{'
    printf '"cpu":{'
    printf '"cores":%s,' "${cores}"
    if [ "${util_pct}" = "null" ]; then
      printf '"total":{"norm":{"pct":null}}'
    else
      printf '"total":{"norm":{"pct":%s}}' "${util_pct}"
    fi
    printf '},'
    printf '"load":{"1":%s,"5":%s,"15":%s,"cores":%s}' "${load1}" "${load5}" "${load15}" "${cores}"
    printf '}}\n'   # close system and doc, end line
  } > "${payload_file}"

  send_or_buffer "${payload_file}"
  rm -f "${payload_file}"
}

main "$@"
