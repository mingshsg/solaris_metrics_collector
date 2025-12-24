# Solaris Host Metrics Collectors

Bash collectors for Solaris 11 that ship host metrics to Elastic in ECS-compatible NDJSON over HTTPS. CPU, memory, and disk collectors are independent and can be enabled separately.

## Files
- config/metrics.conf — file-only configuration (defaults populated).
- scripts/common.sh — shared helpers (logging, buffering, HTTP send).
- scripts/collect_cpu.sh — CPU load/cores/utilization.
- scripts/collect_memory.sh — memory usage/utilization.
- scripts/collect_disk.sh — filesystem utilization per mount.

## Prerequisites
- Solaris 11 with /usr/bin/bash, curl, kstat, psrinfo, prtconf, df, uptime.
- Network reachability to Elastic endpoint.
- Set config file permissions (e.g., `chmod 600 config/metrics.conf`) to protect the API key.

## Configuration
All settings live in config/metrics.conf (no env/CLI overrides). Key defaults:
- Endpoint: https://your-elastic-cloud-endpoint
- API key: your-api-key (set config file permissions to `chmod 600` to protect it)
- TLS validation: no (set to yes to enforce)
- Data stream: metrics-solaris.host-vibe (type=metrics, dataset=solaris.host, namespace=vibe)
- Interval hint: 30s (coordinate with cron or wrapper)
- Enable flags: ENABLE_CPU/ENABLE_MEMORY/ENABLE_DISK (default yes)
- HTTP: timeout 10s, retries 5, exponential backoff capped at 60s
- Logging: ERROR|WARN|INFO|DEBUG (default INFO)
- Offline buffer: enabled, /var/tmp/metrics_cache.ndjson, max 50 MB (NDJSON)
- Dry-run: DRY_RUN=yes to print payload instead of sending
- Disk exclusion: EXCLUDE_FS_TYPES excludes nfs/smb/loop/pseudo defaults

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
- Buffer format: bulk NDJSON (action+document lines).

## Units & schema
- Percent values have 2 decimals; sizes reported in MiB.
- ECS-aligned fields: data_stream.*, @timestamp, event.*, host.*, system.cpu.*, system.memory.*, system.filesystem.*.

## Test mode
Set DRY_RUN="yes" in config to print ECS payloads without network calls.

## Permissions
Scripts run as any user; some metrics may be limited when not root. CPU counters file: /var/tmp/metrics_cpu_prev.tsv.

## Option 13 choice (sampling)
Configured for “point-in-time counters only”: uses kstat deltas between runs (no in-run sleep); CPU utilization unavailable on the very first run.
