# elastic-heap-monitor

A lightweight Elasticsearch monitoring daemon that checks cluster health and per-node JVM heap usage, sending alerts to Slack when thresholds are exceeded.

## Features

- Monitors cluster health status (green/yellow/red)
- Tracks per-node JVM heap usage with configurable warning and critical thresholds
- Sends Slack alerts with cooldown to prevent spam
- Recovery notifications when issues resolve
- Automatic cluster discovery from a flat list of server URLs
- Endpoint failover — multiple URLs per cluster, first reachable one wins
- Runs as a foreground process or daemonized
- Fully configurable via CLI flags or environment variables
- Docker-ready

## Requirements

- Perl 5.20+
- `HTTP::Tiny` (core)
- `JSON` (`perl-json` on Alpine)
- `IO::Socket::SSL` (for HTTPS webhooks)

## Quick Start

```bash
# One-shot check with verbose output
./elastic-heap-monitor \
  --servers 'http://escluster701:9200,http://escluster702:9200,http://escluster2701:9200' \
  --webhook 'https://hooks.slack.com/services/...' \
  --verbose --once

# Run continuously via environment variables
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
export EHM_MONITOR_SERVERS='http://escluster701:9200,http://escluster702:9200'
export EHM_MONITOR_INTERVAL=30
./elastic-heap-monitor
```

## Cluster Configuration

There are three ways to configure clusters, applied in priority order: `--clusters` > `--servers` > `/etc/hosts` auto-discovery.

### Auto-Discovery (`--servers` / `EHM_MONITOR_SERVERS`)

Provide a comma-separated list of Elasticsearch server URLs. The monitor queries each server's root API endpoint (`GET /`) to read its `cluster_name`, then automatically groups servers into clusters.

```bash
# These servers will be grouped by their cluster_name
export EHM_MONITOR_SERVERS='http://escluster701:9200,http://escluster702:9200,http://escluster2701:9200,http://escluster2702:9200,http://escluster601a:9200'
```

### Explicit Clusters (`--clusters` / `EHM_MONITOR_CLUSTERS`)

Define clusters manually with semicolon-separated entries of `name=url1,url2`:

```bash
export EHM_MONITOR_CLUSTERS='cluster1-es7=http://escluster701:9200,http://escluster702:9200;cluster2-es7=http://escluster2701:9200'
```

Multiple URLs per cluster provide failover — the first reachable endpoint is used each cycle.

### Hosts File Fallback (automatic)

If neither `--clusters` nor `--servers` is set, the monitor scans `/etc/hosts` for hostnames starting with `escluster`. Matching hosts are queried on port 9200 for auto-discovery, the same as `--servers`.

```
# /etc/hosts
10.0.1.10  escluster701
10.0.1.11  escluster702
10.0.2.10  escluster2701
10.0.2.11  escluster2702
```

With the above hosts file and no other config, the monitor will query `http://escluster701:9200`, `http://escluster702:9200`, etc., read each node's `cluster_name`, and group them automatically.

## Configuration Reference

All settings can be set via CLI flag or environment variable. CLI flags take precedence.

| CLI Flag | Env Var | Default | Description |
|---|---|---|---|
| `--webhook URL` | `SLACK_WEBHOOK_URL` | *(none)* | Slack incoming webhook URL |
| `--servers STR` | `EHM_MONITOR_SERVERS` | *(none)* | Comma-separated server URLs for auto-discovery |
| `--clusters STR` | `EHM_MONITOR_CLUSTERS` | *(none)* | Explicit cluster definitions (see above) |
| `--interval SECS` | `EHM_MONITOR_INTERVAL` | `60` | Seconds between check cycles |
| `--warn PCT` | `EHM_MONITOR_WARN` | `75` | Heap warning threshold (%) |
| `--crit PCT` | `EHM_MONITOR_CRIT` | `85` | Heap critical threshold (%) |
| `--cooldown SECS` | `EHM_MONITOR_COOLDOWN` | `1800` | Min seconds between repeat alerts |
| `--timeout SECS` | `EHM_MONITOR_TIMEOUT` | `10` | HTTP request timeout |
| `--log FILE` | `EHM_MONITOR_LOG` | `/var/log/elastic-heap-monitor.log` | Log file path (when daemonized) |
| `--pid FILE` | `EHM_MONITOR_PID` | `/var/run/elastic-heap-monitor.pid` | PID file path |
| `-d, --daemonize` | `EHM_MONITOR_DAEMONIZE=1` | off | Fork to background |
| `--once` | `EHM_MONITOR_ONCE=1` | off | Run one check cycle then exit |
| `-v, --verbose` | `EHM_MONITOR_VERBOSE=1` | off | Log OK status for every node |
| `--test-alert` | | | Send a test message to Slack and exit |

## Docker

```bash
docker build -t elastic-heap-monitor .

docker run -e SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' \
           -e EHM_MONITOR_SERVERS='http://escluster701:9200,http://escluster702:9200' \
           elastic-heap-monitor
```

The container logs to stderr by default so `docker logs` works out of the box.

## Alerts

The monitor sends Slack alerts for:

- **Cluster unreachable** — all endpoints for a cluster failed to respond
- **Cluster health RED/YELLOW** — Elasticsearch reports degraded cluster status
- **Heap warning** — a node's JVM heap exceeds the warning threshold
- **Heap critical** — a node's JVM heap exceeds the critical threshold
- **Recovery** — any of the above conditions resolves

Repeat alerts are suppressed for the duration of the cooldown period (default 30 minutes). Critical alerts will fire immediately if escalating from a warning.

## Monitored APIs

| Endpoint | Purpose |
|---|---|
| `GET /` | Root endpoint — returns `cluster_name` (used for auto-discovery) |
| `GET /_cluster/health` | Cluster status, node count, shard info |
| `GET /_nodes/stats/jvm` | Per-node JVM heap usage, memory, and GC stats |
