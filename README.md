# Solaris Host Metrics Collectors

Bash collectors for Solaris 11 that ship host metrics to Elasticsearch or Logstash in ECS-compatible NDJSON format. CPU, memory, and disk collectors are independent and can be enabled separately.

## Files
- config/metrics.conf — file-only configuration (defaults populated).
- scripts/common.sh — shared helpers (logging, buffering, HTTP send).
- scripts/collect_cpu.sh — CPU load/cores/utilization.
- scripts/collect_memory.sh — memory usage/utilization.
- scripts/collect_disk.sh — filesystem utilization per mount.

## Prerequisites
- Solaris 11 with /usr/bin/bash, curl, kstat, psrinfo, prtconf, df, uptime.
- Network reachability to your target (Elasticsearch Cloud or Logstash HTTP input).
- Set config file permissions (e.g., `chmod 600 config/metrics.conf`) to protect the API key.

## Configuration
All settings live in config/metrics.conf (no env/CLI overrides).

### Target Selection
- **TARGET**: Choose `elastic` or `logstash` (default: `logstash`)

### Elasticsearch Configuration (when TARGET="elastic")
- Endpoint: https://your-elastic-cloud-endpoint
- API key: your-api-key (base64 encoded, set config file permissions to `chmod 600` to protect it)
- TLS validation: ELASTIC_VALIDATE_CERT (default: no)

### Logstash Configuration (when TARGET="logstash")
- Host: 13.212.9.65
- Port: 5055
- Protocol: http (http or https)
- TLS validation: LOGSTASH_VALIDATE_CERT (default: no)

### Common Settings
- Data stream: metrics-solaris.host-vibe (type=metrics, dataset=solaris.host, namespace=vibe)
- Interval hint: 30s (coordinate with cron or wrapper)
- Enable flags: ENABLE_CPU/ENABLE_MEMORY/ENABLE_DISK (default yes)
- HTTP: timeout 10s, retries 5, exponential backoff capped at 60s
- Logging: ERROR|WARN|INFO|DEBUG (default INFO)
- Offline buffer: enabled, /var/tmp/metrics_cache.ndjson, max 50 MB (NDJSON)
- Dry-run: DRY_RUN=yes to print payload instead of sending
- Disk exclusion: EXCLUDE_FS_TYPES excludes nfs/smb/loop/pseudo defaults

## Logstash Setup Example

If using Logstash as the target, configure your Logstash pipeline to accept metrics from the HTTP input and forward to Elasticsearch:

```
input {
  http {
    port => 5055
  }
}

filter {
  json {
    source => "message"
    # No target specified, so parsed fields go to the root
  }
}

output {
  elasticsearch {
    hosts => ["https://your-es-endpoint:443"]
    api_key => "your-api-key"
    data_stream => "true"
    # the below data streams are configured for fallback purpose
    data_stream_type => "metrics"
    data_stream_dataset => "solaris.host"
    data_stream_namespace => "forward"
  }
  stdout { codec => rubydebug }
}
```

Adjust the Elasticsearch endpoint, API key, and data stream namespace according to your environment.

## Running
Each collector is standalone; run only the ones you need:
```
/usr/bin/bash scripts/collect_cpu.sh
/usr/bin/bash scripts/collect_memory.sh
/usr/bin/bash scripts/collect_disk.sh
```
- CPU utilization uses point-in-time kstat counters delta between runs; first run sets a baseline and reports utilization as null.
- Disk collector skips fstype matches in EXCLUDE_FS_TYPES.
- Uses short hostname for host identifier.

## Scheduling
- For ~30s cadence, use cron with two entries (0s and +30s) per script, e.g.:
  - `* * * * * /usr/bin/bash /path/scripts/collect_cpu.sh`
  - `* * * * * (sleep 30; /usr/bin/bash /path/scripts/collect_cpu.sh)`
- Adjust or disable per-category via ENABLE_* in the config file.

## Offline buffering
- Before sending new data, buffered NDJSON (if any) is retried.
- On send failure, payloads are appended to BUFFER_PATH (trimmed to BUFFER_MAX_MB via tail -c window).
- Buffer format: NDJSON (action+document lines for Elasticsearch, document-only lines for Logstash).

## Data Format
- **Elasticsearch**: Sends bulk action format with `{"create":{"_index":"metrics-solaris.host-vibe"}}` followed by document.
- **Logstash**: Sends document-only NDJSON for processing by your configured pipeline.
- Percent values have 2 decimals; sizes reported in MiB.
- ECS-aligned fields: data_stream.*, @timestamp, event.*, host.*, system.cpu.*, system.memory.*, system.filesystem.*.

## Test mode
Set DRY_RUN="yes" in config to print ECS payloads without network calls.

## Permissions
Scripts run as any user; some metrics may be limited when not root. CPU counters file: /var/tmp/metrics_cpu_prev.tsv.

## Option 13 choice (sampling)
Configured for “point-in-time counters only”: uses kstat deltas between runs (no in-run sleep); CPU utilization unavailable on the very first run.
