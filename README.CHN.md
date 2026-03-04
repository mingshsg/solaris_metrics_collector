# Solaris 主机指标采集器

适用于 Solaris 11 的 Bash 采集脚本，按 ECS 兼容的 NDJSON 格式向 Elasticsearch 或 Logstash 发送主机指标。CPU、内存、磁盘采集器互相独立，可按需启用。

## 文件
- config/metrics.conf — 仅文件配置（默认已填好）。
- scripts/common.sh — 公共函数（日志、缓存、HTTP 发送）。
- scripts/collect_cpu.sh — CPU 负载/核心数/利用率。
- scripts/collect_memory.sh — 内存使用与利用率。
- scripts/collect_disk.sh — 每个挂载点的文件系统利用率。

## 前置条件
- Solaris 11，需有 /usr/bin/bash、curl、kstat、psrinfo、prtconf、df、uptime。
- 能访问目标服务（Elasticsearch Cloud 或 Logstash HTTP 输入）。
- 保护配置文件权限（如 `chmod 600 config/metrics.conf`），避免 API Key 外泄。

## 配置
所有设置都在 config/metrics.conf（无环境变量或命令行覆盖）。

### 目标选择
- **TARGET**：选择 `elastic` 或 `logstash`（默认：`logstash`）

### Elasticsearch 云配置（当 TARGET="elastic" 时）
- Endpoint: https://your-elastic-cloud-endpoint
- API key: your-api-key（base64 编码，设置配置文件权限 `chmod 600` 以保护）
- TLS 校验：ELASTIC_VALIDATE_CERT（默认：no）

### Logstash 配置（当 TARGET="logstash" 时）
- Host: 13.212.9.65
- Port: 5055
- Protocol: http（http 或 https）
- TLS 校验：LOGSTASH_VALIDATE_CERT（默认：no）

### 公共设置
- Data stream: metrics-solaris.host-vibe（type=metrics, dataset=solaris.host, namespace=vibe）
- 采集周期提示：30s（需配合 cron 或外部循环）
- 启用开关：ENABLE_CPU/ENABLE_MEMORY/ENABLE_DISK（默认 yes）
- HTTP：超时 10s，重试 5 次，指数回退上限 60s
- 日志级别：ERROR|WARN|INFO|DEBUG（默认 INFO）
- 离线缓存：开启，/var/tmp/metrics_cache.ndjson，最大 50 MB（NDJSON）
- Dry-run：DRY_RUN=yes 只打印负载，不发网络请求
- 磁盘排除：EXCLUDE_FS_TYPES 默认排除 nfs/smb/loop/pseudo 等类型

## Logstash 配置示例

若以 Logstash 为目标，可配置 Logstash pipeline 从 HTTP 输入接收指标并转发到 Elasticsearch：

```
input {
  http {
    port => 5055
  }
}

filter {
  json {
    source => "message"
    # 不指定 target，解析后的字段直接放在根级别
  }
}

output {
  elasticsearch {
    hosts => ["https://your-es-endpoint:443"]
    api_key => "your-api-key"
    data_stream => "true"
    # 下列 data stream 参数为备用配置
    data_stream_type => "metrics"
    data_stream_dataset => "solaris.host"
    data_stream_namespace => "forward"
  }
  stdout { codec => rubydebug }
}
```

根据实际环境调整 Elasticsearch 端点、API Key 和 data stream namespace。

## 运行
每个采集器独立运行，按需调用：
```
/usr/bin/bash scripts/collect_cpu.sh
/usr/bin/bash scripts/collect_memory.sh
/usr/bin/bash scripts/collect_disk.sh
```
- CPU 利用率使用运行间的 kstat 计数差值（point-in-time），首轮仅建立基线，会返回 null。
- 磁盘采集器跳过 EXCLUDE_FS_TYPES 中的文件系统类型。
- 主机标识使用短主机名。

## 调度
- 若需约 30 秒频率，可为每个脚本在 cron 添加两条（0 秒和 +30 秒）：
  - `* * * * * /usr/bin/bash /path/scripts/collect_cpu.sh`
  - `* * * * * (sleep 30; /usr/bin/bash /path/scripts/collect_cpu.sh)`
- 可通过配置文件中的 ENABLE_* 开关调整或禁用某一类。

## 离线缓存
- 发送前会先冲刷已缓存的 NDJSON。
- 发送失败会把负载追加到 BUFFER_PATH（通过 tail -c 窗口裁剪到 BUFFER_MAX_MB 以内）。
- 缓存格式：NDJSON（Elasticsearch 为 action 行 + 文档行，Logstash 为仅文档行）。

## 数据格式
- **Elasticsearch**：发送 Bulk API 格式，包含 `{"create":{"_index":"metrics-solaris.host-vibe"}}` 后跟文档。
- **Logstash**：发送仅文档的 NDJSON，由配置的 pipeline 处理。
- 百分比保留 2 位小数；容量用 MiB 表示。
- ECS 字段：data_stream.*、@timestamp、event.*、host.*、system.cpu.*、system.memory.*、system.filesystem.*。

## 测试模式
在配置中设 DRY_RUN="yes"，只打印 ECS 负载，不发出网络请求。

## 权限
可用普通用户运行；非 root 可能拿不到全部磁盘信息。CPU 计数缓存文件：/var/tmp/metrics_cpu_prev.tsv。

## 采样选项 13
已选择“point-in-time counters only”：运行间使用 kstat 计数差值，无额外等待；首次运行无法给出 CPU 利用率。
