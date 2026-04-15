# elastic-heap-monitor

A lightweight Elasticsearch monitoring daemon that checks cluster health and per-node JVM heap usage, sending alerts to Slack when thresholds are exceeded.

## Features

- Monitors cluster health status (green/yellow/red), with per-node heap usage included in the alert
- Tracks per-node JVM heap usage with configurable warning and critical thresholds
- Sends Slack alerts with cooldown to prevent spam
- Recovery notifications when issues resolve
- Automatic cluster discovery from a flat list of server URLs
- Endpoint failover — multiple URLs per cluster, first reachable one wins
- Runs as a foreground process or daemonized systemd service
- Fully configurable via config file, environment variables, or CLI flags
- Ships as a Debian package and a Docker image

## Requirements

- Perl 5.20+
- `Modern::Perl`
- `Config::General`
- `HTTP::Tiny` (core)
- `JSON`
- `IO::Socket::SSL` (for HTTPS webhooks)

On Debian/Ubuntu these are `libmodern-perl-perl`, `libconfig-general-perl`, `libjson-perl`, and `libio-socket-ssl-perl`.

## Installation

### Debian package

```bash
sudo dpkg -i elastic-heap-monitor_*.deb
sudo apt-get install -f    # pull any missing deps
```

The package installs a systemd unit (`elastic-heap-monitor.service`), creates a dedicated `elastic-heap-monitor` system user, and drops a sample config at `/etc/elastic-heap-monitor/elastic-heap-monitor.conf`. Logs go to journald — view them with `sudo journalctl -u elastic-heap-monitor -f`.

### From source

```bash
cpanm --installdeps .
./elastic-heap-monitor --help
```

## Quick Start

```bash
# One-shot check with verbose output
./elastic-heap-monitor \
  --servers 'http://es1:9200,http://es2:9200,http://es3:9200' \
  --webhook 'https://hooks.slack.com/services/...' \
  --verbose --once

# Run continuously via environment variables
export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...'
export EHM_MONITOR_SERVERS='http://es1:9200,http://es2:9200'
export EHM_MONITOR_INTERVAL=30
./elastic-heap-monitor
```

## Configuration File

Settings are read from `/etc/elastic-heap-monitor/elastic-heap-monitor.conf` (override with `EHM_MONITOR_CONFIG`). The file uses Apache-style [`Config::General`](https://metacpan.org/pod/Config::General) syntax: top-level `key = value` options, comments starting with `#`, and nested `<cluster NAME>` blocks with one `url` line per node.

```apache
# Slack incoming webhook URL
webhook = https://hooks.slack.com/services/XXX/YYY/ZZZ

# Clusters — one block per cluster, one URL per node
<cluster cluster1>
    url http://es1:9200
    url http://es2:9200
    url http://es3:9200
</cluster>

<cluster cluster2>
    url http://es4:9200
    url http://es5:9200
</cluster>

<cluster test-cluster>
    url http://es-test:9200
</cluster>

# Check interval
interval = 60

# Heap thresholds (%)
warn = 80
crit = 90

# Minimum seconds between repeat alerts for the same condition
cooldown = 1800

# HTTP request timeout
timeout = 10
```

**Precedence:** CLI flag > environment variable > config file > built-in default.

The legacy single-line form `clusters = c1=url1,url2;c2=url3` is still accepted for backward compatibility.

## Cluster Configuration

There are three ways to tell the monitor which clusters to watch, applied in priority order: **explicit clusters > auto-discovery by server list > `/etc/hosts` scan.**

### Explicit clusters (config file, `--clusters`, or `EHM_MONITOR_CLUSTERS`)

The preferred form is a `<cluster NAME>` block in the config file (see above). For one-off invocations, the single-line form accepts semicolon-separated entries of `name=url1,url2`:

```bash
export EHM_MONITOR_CLUSTERS='cluster1=http://es1:9200,http://es2:9200;cluster2=http://es3:9200'
```

Multiple URLs per cluster provide failover — the first reachable endpoint is used each cycle.

### Auto-discovery (`--servers` / `EHM_MONITOR_SERVERS`)

Provide a comma-separated list of Elasticsearch server URLs. The monitor queries each server's root API endpoint (`GET /`) to read its `cluster_name`, then automatically groups servers into clusters.

```bash
export EHM_MONITOR_SERVERS='http://es1:9200,http://es2:9200,http://es3:9200,http://es4:9200'
```

### `/etc/hosts` fallback

If neither of the above is set, the monitor scans `/etc/hosts` for hostnames starting with `escluster` and auto-discovers clusters from them.

## Configuration Reference

All settings can be set via CLI flag, environment variable, or config-file key. Precedence is CLI > env > config file > default.

| CLI Flag | Env Var | Config key | Default | Description |
|---|---|---|---|---|
| `--webhook URL` | `SLACK_WEBHOOK_URL` | `webhook` | *(none)* | Slack incoming webhook URL |
| `--servers STR` | `EHM_MONITOR_SERVERS` | `servers` | *(none)* | Comma-separated server URLs for auto-discovery |
| `--clusters STR` | `EHM_MONITOR_CLUSTERS` | `clusters` / `<cluster>` blocks | *(none)* | Explicit cluster definitions |
| `--config FILE` | `EHM_MONITOR_CONFIG` | — | `/etc/elastic-heap-monitor/elastic-heap-monitor.conf` | Path to config file |
| `--interval SECS` | `EHM_MONITOR_INTERVAL` | `interval` | `60` | Seconds between check cycles |
| `--warn PCT` | `EHM_MONITOR_WARN` | `warn` | `80` | Heap warning threshold (%) |
| `--crit PCT` | `EHM_MONITOR_CRIT` | `crit` | `90` | Heap critical threshold (%) |
| `--cooldown SECS` | `EHM_MONITOR_COOLDOWN` | `cooldown` | `1800` | Min seconds between repeat alerts |
| `--timeout SECS` | `EHM_MONITOR_TIMEOUT` | `timeout` | `10` | HTTP request timeout |
| `--log FILE` | `EHM_MONITOR_LOG` | `log` | `/var/log/elastic-heap-monitor.log` | Log file path (when daemonized) |
| `--pid FILE` | `EHM_MONITOR_PID` | `pid` | `/var/run/elastic-heap-monitor.pid` | PID file path |
| `-d, --daemonize` | `EHM_MONITOR_DAEMONIZE=1` | `daemonize` | off | Fork to background |
| `--once` | `EHM_MONITOR_ONCE=1` | `once` | off | Run one check cycle then exit |
| `-v, --verbose` | `EHM_MONITOR_VERBOSE=1` | `verbose` | off | Log OK status for every node |
| `--test-alert` | | | | Send a test message to Slack and exit |

## Docker

```bash
docker build -t elastic-heap-monitor .

docker run -e SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' \
           -e EHM_MONITOR_SERVERS='http://es1:9200,http://es2:9200' \
           elastic-heap-monitor
```

The container logs to stderr by default so `docker logs` works out of the box.

## Alerts

The monitor sends Slack alerts for:

- **Cluster unreachable** — all endpoints for a cluster failed to respond
- **Cluster health RED/YELLOW** — Elasticsearch reports degraded cluster status; the message includes per-node heap usage sorted by highest heap first
- **Heap warning** — a node's JVM heap exceeds the warning threshold
- **Heap critical** — a node's JVM heap exceeds the critical threshold
- **Recovery** — any of the above conditions resolves

Repeat alerts are suppressed for the duration of the cooldown period (default 30 minutes). Critical alerts fire immediately if escalating from a warning.

## Monitored APIs

| Endpoint | Purpose |
|---|---|
| `GET /` | Root endpoint — returns `cluster_name` (used for auto-discovery) |
| `GET /_cluster/health` | Cluster status, node count, shard info |
| `GET /_nodes/stats/jvm` | Per-node JVM heap usage, memory, and GC stats |

## Development

Run the test suite with:

```bash
prove -v t/
```

Tests cover cluster-health alerting logic and config-file parsing. The GitHub Actions workflow runs `prove` on every push and PR; building the Debian package only runs on tags starting with `v` and requires the tests to pass first.
