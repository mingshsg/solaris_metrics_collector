#!/usr/bin/bash
# Shared helpers for Solaris host metrics collectors
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
CONFIG_FILE="${ROOT_DIR}/config/metrics.conf"

# Load configuration
if [ ! -f "${CONFIG_FILE}" ]; then
  echo "[FATAL] config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${CONFIG_FILE}"

DATA_STREAM_NAME="${DATA_STREAM_TYPE}-${DATA_STREAM_DATASET}-${DATA_STREAM_NAMESPACE}"

# Set up endpoint and validation based on target
CURL_VERIFY_FLAG=""
if [ "${TARGET}" = "elastic" ]; then
  if [ "${ELASTIC_VALIDATE_CERT}" = "no" ]; then
    CURL_VERIFY_FLAG="-k"
  fi
elif [ "${TARGET}" = "logstash" ]; then
  if [ "${LOGSTASH_VALIDATE_CERT}" = "no" ]; then
    CURL_VERIFY_FLAG="-k"
  fi
fi

# Logging helpers
log_level_to_int() {
  case "$1" in
    ERROR) echo 0;;
    WARN) echo 1;;
    INFO) echo 2;;
    DEBUG) echo 3;;
    *) echo 2;;
  esac
}
CURRENT_LOG_LEVEL_INT=$(log_level_to_int "${LOG_LEVEL}")

log() {
  local level="$1"; shift
  local level_int
  level_int=$(log_level_to_int "${level}")
  if [ "${level_int}" -le "${CURRENT_LOG_LEVEL_INT}" ]; then
    printf '%s [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${level}" "$*" >&2
  fi
}

json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

hostname_short() {
  /usr/bin/hostname | /usr/bin/cut -d'.' -f1
}

# Solaris host metadata helpers
host_architecture() {
  if command -v isainfo >/dev/null 2>&1; then
    isainfo -n 2>/dev/null || uname -p 2>/dev/null
  else
    uname -p 2>/dev/null
  fi
}

host_cpu_family() {
  # Prefer kstat cpu_info brand; fallback to isainfo verbose or uname -p
  local brand
  if command -v kstat >/dev/null 2>&1; then
    brand=$(kstat -m cpu_info 2>/dev/null | awk -F'\t' '/brand/ {print $2; exit}' | sed 's/^brand //; s/^brand=//')
  fi
  if [ -n "${brand}" ]; then
    echo "${brand}"
  elif command -v isainfo >/dev/null 2>&1; then
    isainfo -v 2>/dev/null | /usr/bin/head -1
  else
    uname -p 2>/dev/null
  fi
}

default_route_iface() {
  # Get interface for default IPv4 route
  netstat -rn -f inet 2>/dev/null | awk '/^default/ {print $NF; exit}'
}

iface_ipv4() {
  local ifc="$1"
  ifconfig -a 2>/dev/null | awk -v ifc="$ifc" '
    $1 ~ "^"ifc":" { active=1 }
    active && /inet / {print $2; exit}
  '
}

iface_mac() {
  local ifc="$1"
  ifconfig -a 2>/dev/null | awk -v ifc="$ifc" '
    $1 ~ "^"ifc":" { active=1 }
    active && /ether / {print $2; exit}
  '
}

host_os_full() {
  local rel ver
  rel=$(uname -r 2>/dev/null)
  ver=$(uname -v 2>/dev/null)
  printf 'Solaris %s %s' "${rel}" "${ver}"
}

host_os_name() {
  uname -s 2>/dev/null
}

host_os_version() {
  uname -r 2>/dev/null
}

# Prepare offline buffer path
ensure_buffer_dir() {
  if [ "${BUFFER_ENABLED}" != "yes" ]; then
    return
  fi
  local dir
  dir=$(dirname "${BUFFER_PATH}")
  if [ ! -d "${dir}" ]; then
    mkdir -p "${dir}"
  fi
}

ndjson_append_with_limit() {
  local payload_file="$1"
  ensure_buffer_dir
  cat "${payload_file}" >> "${BUFFER_PATH}"
  local max_bytes
  max_bytes=$((BUFFER_MAX_MB * 1024 * 1024))
  local current_size
  current_size=$(wc -c < "${BUFFER_PATH}" 2>/dev/null || echo 0)
  if [ "${current_size}" -le "${max_bytes}" ]; then
    return
  fi
  log WARN "Buffer ${BUFFER_PATH} exceeded ${BUFFER_MAX_MB}MB; trimming newest window"
  # Keep the last max_bytes bytes
  if command -v tail >/dev/null 2>&1; then
    tail -c "${max_bytes}" "${BUFFER_PATH}" > "${BUFFER_PATH}.tmp" && mv "${BUFFER_PATH}.tmp" "${BUFFER_PATH}"
  fi
}

# Send NDJSON file to target (Elasticsearch or Logstash) with retries; respects DRY_RUN
send_ndjson_file() {
  local ndjson_file="$1"

  if [ "${DRY_RUN}" = "yes" ]; then
    log INFO "Dry-run: printing payload instead of sending"
    cat "${ndjson_file}"
    return 0
  fi

  local attempt=1
  local backoff=1
  local resp_body resp_code curl_output curl_status
  local endpoint auth_header target_name
  
  # Determine endpoint and auth header based on target
  if [ "${TARGET}" = "elastic" ]; then
    endpoint="${ELASTIC_ENDPOINT}/_bulk"
    auth_header="-H \"Authorization: ApiKey ${ELASTIC_API_KEY}\""
    target_name="Elasticsearch"
  elif [ "${TARGET}" = "logstash" ]; then
    endpoint="${LOGSTASH_PROTOCOL}://${LOGSTASH_HOST}:${LOGSTASH_PORT}"
    auth_header=""
    target_name="Logstash"
  else
    log ERROR "Unknown TARGET: ${TARGET}. Must be 'elastic' or 'logstash'"
    return 1
  fi

  while [ "${attempt}" -le "${HTTP_RETRIES}" ]; do
    resp_body="$(mktemp /var/tmp/target_resp.XXXXXX)"
    
    # Build curl command with conditional auth header
    local curl_cmd
    if [ -n "${auth_header}" ]; then
      curl_cmd="curl -sS ${CURL_VERIFY_FLAG} -X POST \"${endpoint}\" ${auth_header} -H \"Content-Type: application/x-ndjson\" --max-time \"${HTTP_TIMEOUT_SECONDS}\" --data-binary \"@${ndjson_file}\" -o \"${resp_body}\" -w \"%{http_code}\""
    else
      curl_cmd="curl -sS ${CURL_VERIFY_FLAG} -X POST \"${endpoint}\" -H \"Content-Type: application/x-ndjson\" --max-time \"${HTTP_TIMEOUT_SECONDS}\" --data-binary \"@${ndjson_file}\" -o \"${resp_body}\" -w \"%{http_code}\""
    fi
    
    curl_output=$(eval "${curl_cmd}")
    curl_status=$?
    resp_code="${curl_output}"

    # Handle response based on target
    if [ "${curl_status}" -eq 0 ]; then
      case "${resp_code}" in
        2*)
          if [ "${TARGET}" = "elastic" ]; then
            # For Elasticsearch, verify no errors in response
            if /usr/bin/egrep '"errors":false' "${resp_body}" >/dev/null 2>&1; then
              log INFO "Sent ${ndjson_file} to ${target_name} (attempt ${attempt}, HTTP ${resp_code})"
              rm -f "${resp_body}"
              return 0
            else
              log WARN "${target_name} bulk response contains errors (attempt ${attempt}, HTTP ${resp_code})"
              log DEBUG "Response body: $(cat "${resp_body}")"
            fi
          else
            # For Logstash, 2xx response is success
            log INFO "Sent ${ndjson_file} to ${target_name} (attempt ${attempt}, HTTP ${resp_code})"
            rm -f "${resp_body}"
            return 0
          fi
          ;;
        *)
          log WARN "HTTP send to ${target_name} failed (attempt ${attempt}, status ${curl_status}, code ${resp_code})"
          if [ -s "${resp_body}" ]; then
            log DEBUG "Response body: $(cat "${resp_body}")"
          fi
          ;;
      esac
    else
      log WARN "curl error to ${target_name} (attempt ${attempt}, status ${curl_status}, code ${resp_code})"
      if [ -s "${resp_body}" ]; then
        log DEBUG "Response body: $(cat "${resp_body}")"
      fi
    fi
    rm -f "${resp_body}"
    attempt=$((attempt + 1))
    backoff=$((backoff * 2))
    if [ "${backoff}" -gt "${HTTP_MAX_BACKOFF_SECONDS}" ]; then
      backoff="${HTTP_MAX_BACKOFF_SECONDS}"
    fi
    sleep "${backoff}"
  done

  log ERROR "Failed to send payload to ${target_name} after ${HTTP_RETRIES} attempts"
  return 1
}

# Flush buffered events if any
flush_buffer_if_any() {
  if [ "${BUFFER_ENABLED}" != "yes" ]; then
    return
  fi
  if [ ! -s "${BUFFER_PATH}" ]; then
    return
  fi
  log INFO "Flushing buffered NDJSON from ${BUFFER_PATH}"
  local tmp_payload
  tmp_payload=$(mktemp /var/tmp/buffer_flush.XXXXXX)
  mv "${BUFFER_PATH}" "${tmp_payload}"
  if ! send_ndjson_file "${tmp_payload}"; then
    log WARN "Re-queueing buffered data after failed flush"
    cat "${tmp_payload}" >> "${BUFFER_PATH}"
  fi
  rm -f "${tmp_payload}"
}

# Main send wrapper that also buffers on failure
send_or_buffer() {
  local payload_file="$1"
  flush_buffer_if_any
  if send_ndjson_file "${payload_file}"; then
    return 0
  fi
  if [ "${BUFFER_ENABLED}" = "yes" ]; then
    log WARN "Caching payload to ${BUFFER_PATH}"
    ndjson_append_with_limit "${payload_file}"
    return 0
  fi
  return 1
}

# Build the bulk action line for the configured data stream
# Only output the action line for Elasticsearch; Logstash doesn't need it
bulk_action_line() {
  if [ "${TARGET}" = "elastic" ]; then
    printf '{"create":{"_index":"%s"}}\n' "${DATA_STREAM_NAME}"
  fi
}

# Common ECS envelope for host fields
host_ecs_json() {
  local hname
  hname=$(hostname_short)
  local arch cpu_family ifc ip mac os_full os_name os_version
  arch=$(host_architecture)
  cpu_family=$(host_cpu_family)
  ifc=$(default_route_iface)
  ip=$(iface_ipv4 "${ifc}")
  mac=$(iface_mac "${ifc}")
  os_full=$(host_os_full)
  os_name=$(host_os_name)
  os_version=$(host_os_version)
  printf '"host":{"hostname":"%s","name":"%s","architecture":"%s","ip":"%s","mac":"%s","os":{"full":"%s","name":"%s","version":"%s"},"cpu":{"family":"%s"}}' \
    "${hname}" "${hname}" "$(json_escape "${arch}")" "${ip}" "${mac}" "$(json_escape "${os_full}")" "$(json_escape "${os_name}")" "$(json_escape "${os_version}")" "$(json_escape "${cpu_family}")"
}

# ECS data_stream fields
stream_ecs_json() {
  printf '"data_stream":{"type":"%s","dataset":"%s","namespace":"%s"}' \
    "${DATA_STREAM_TYPE}" "${DATA_STREAM_DATASET}" "${DATA_STREAM_NAMESPACE}"
}
