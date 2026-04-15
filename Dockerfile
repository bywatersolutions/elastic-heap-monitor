FROM alpine:3.20

RUN apk add --no-cache \
        perl \
        perl-json \
        perl-io-socket-ssl \
    && mkdir -p /var/log /var/run

COPY elastic-heap-monitor /usr/local/bin/elastic-heap-monitor
RUN chmod +x /usr/local/bin/elastic-heap-monitor

# Sensible defaults for container — no daemonize (container IS the process),
# log to stderr so docker logs works.
ENV EHM_MONITOR_LOG=/dev/stderr

ENTRYPOINT ["elastic-heap-monitor"]
