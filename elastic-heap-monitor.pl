#!/usr/bin/perl

use Modern::Perl;

use Config::Tiny;
use Fcntl qw(:flock);
use Getopt::Long;
use HTTP::Tiny;
use IO::Handle;
use JSON;
use Pod::Usage;
use POSIX qw(setsid strftime);

my $VERSION = '1.0.0';

my $config_file = $ENV{EHM_MONITOR_CONFIG} // '/etc/elastic-heap-monitor/elastic-heap-monitor.conf';

my $file_config = {};
if ( -f $config_file ) {
    my $conf = Config::Tiny->read($config_file);
    if ($conf) {
        $file_config = $conf->{_} // {};
    }
    else {
        warn "WARNING: Cannot read config file $config_file: "
          . Config::Tiny->errstr . "\n";
    }
}

my $slack_webhook  = $ENV{SLACK_WEBHOOK_URL}    // $file_config->{webhook}   // '';
my $clusters_env   = $ENV{EHM_MONITOR_CLUSTERS} // $file_config->{clusters}  // '';
my $servers_env    = $ENV{EHM_MONITOR_SERVERS}   // $file_config->{servers}   // '';
my $check_interval = $ENV{EHM_MONITOR_INTERVAL} // $file_config->{interval}  // 60;
my $heap_warn      = $ENV{EHM_MONITOR_WARN}     // $file_config->{warn}      // 80;
my $heap_crit      = $ENV{EHM_MONITOR_CRIT}     // $file_config->{crit}      // 90;
my $cooldown       = $ENV{EHM_MONITOR_COOLDOWN} // $file_config->{cooldown}  // 1800;
my $http_timeout   = $ENV{EHM_MONITOR_TIMEOUT}  // $file_config->{timeout}   // 10;
my $log_file   = $ENV{EHM_MONITOR_LOG}       // $file_config->{log}       // '/var/log/elastic-heap-monitor.log';
my $pid_file   = $ENV{EHM_MONITOR_PID}       // $file_config->{pid}       // '/var/run/elastic-heap-monitor.pid';
my $daemonize  = $ENV{EHM_MONITOR_DAEMONIZE} // $file_config->{daemonize} // 0;
my $once       = $ENV{EHM_MONITOR_ONCE}      // $file_config->{once}      // 0;
my $verbose    = $ENV{EHM_MONITOR_VERBOSE}   // $file_config->{verbose}   // 0;
my $test_alert = 0;

GetOptions(
    'webhook=s'   => \$slack_webhook,
    'clusters=s'  => \$clusters_env,
    'servers=s'   => \$servers_env,
    'interval=i'  => \$check_interval,
    'warn=i'      => \$heap_warn,
    'crit=i'      => \$heap_crit,
    'cooldown=i'  => \$cooldown,
    'timeout=i'   => \$http_timeout,
    'log=s'       => \$log_file,
    'pid=s'       => \$pid_file,
    'daemonize|d' => \$daemonize,
    'once'        => \$once,
    'verbose|v'   => \$verbose,
    'test-alert'  => \$test_alert,
    'help|h'      => sub { pod2usage( -exitval => 0, -verbose => 2 ) },
    'version|V'   => sub { print "elastic-heap-monitor v$VERSION\n"; exit 0 },
) or die "Try --help for usage\n";

my $CLUSTERS;

if ($clusters_env) {
    $CLUSTERS = parse_clusters_env($clusters_env);
}
elsif ($servers_env) {
    $CLUSTERS = discover_clusters($servers_env);
}
else {
    my $hosts_servers = servers_from_hosts();
    if ($hosts_servers) {
        log_msg("No --clusters or --servers set, discovered servers from /etc/hosts: $hosts_servers") if $verbose;
        $CLUSTERS = discover_clusters($hosts_servers);
    }
}

my %alert_state;
my $pid_fh;

my $http = HTTP::Tiny->new(
    timeout => $http_timeout,
    agent   => "elastic-heap-monitor/$VERSION",
);

if ( !$CLUSTERS || !%$CLUSTERS ) {
    die "ERROR: No clusters configured. Use --clusters, --servers, or add escluster* entries to /etc/hosts.\n";
}

if ( !$slack_webhook ) {
    warn
"WARNING: No Slack webhook configured. Use --webhook or SLACK_WEBHOOK_URL env var.\n";
    warn "         Alerts will be logged only.\n\n";
}

if ($test_alert) {
    log_msg("Sending test alert to Slack");
    send_slack_alert(
        color   => 'warning',
        title   => ":test_tube: Test alert from elastic-heap-monitor",
        text    => "If you see this, your webhook is working.",
        cluster => 'test',
    );
    log_msg("Test alert sent (check Slack)");
    exit 0;
}

if ($daemonize) {
    daemonize_process();
}

my $running = 1;
$SIG{TERM} = sub { $running = 0; log_msg("Received SIGTERM, shutting down"); };
$SIG{INT}  = sub { $running = 0; log_msg("Received SIGINT, shutting down"); };
$SIG{HUP}  = sub { log_msg("Received SIGHUP"); };

log_msg("Starting elastic-heap-monitor v$VERSION (pid $$)");
log_msg("Monitoring "
      . scalar( keys %$CLUSTERS )
      . " clusters every ${check_interval}s" );
log_msg(
"Heap thresholds: warn=${heap_warn}%  crit=${heap_crit}%  cooldown=${cooldown}s"
);

while ($running) {
    for my $cluster_name ( sort keys %$CLUSTERS ) {
        eval { check_cluster( $cluster_name, $CLUSTERS->{$cluster_name} ) };
        if ($@) {
            log_msg("ERROR checking $cluster_name: $@");
        }
    }

    last if $once;
    sleep $check_interval;
}

log_msg("Shutting down (pid $$)");
cleanup_pid();
exit 0;

sub check_cluster {
    my ( $cluster_name, $endpoints ) = @_;

    my ( $endpoint, $health_data );
    for my $ep (@$endpoints) {
        my $resp = $http->get("$ep/_cluster/health");
        if ( $resp->{success} ) {
            $endpoint    = $ep;
            $health_data = eval { decode_json( $resp->{content} ) };
            last;
        }
    }

    if ( !$endpoint ) {
        my $key = "unreachable:$cluster_name";
        if ( should_alert($key) ) {
            log_msg(
"CRITICAL: Cluster $cluster_name UNREACHABLE (all endpoints failed)"
            );
            send_slack_alert(
                color => 'danger',
                title => ":no_entry: Cluster $cluster_name UNREACHABLE",
                text  => "All endpoints failed:\n"
                  . join( "\n", map { "  - $_" } @$endpoints ),
                cluster => $cluster_name,
            );
            record_alert( $key, 'crit' );
        }
        return;
    }

    # Clear unreachable state if it was previously set
    if ( $alert_state{"unreachable:$cluster_name"} ) {
        log_msg(
            "RECOVERED: Cluster $cluster_name is reachable again via $endpoint"
        );
        send_slack_alert(
            color => 'good',
            title => ":white_check_mark: Cluster $cluster_name reachable again",
            text  => "Endpoint: $endpoint",
            cluster => $cluster_name,
        );
        delete $alert_state{"unreachable:$cluster_name"};
    }

    check_cluster_health( $cluster_name, $health_data ) if $health_data;

    my $stats_resp = $http->get("$endpoint/_nodes/stats/jvm");
    if ( !$stats_resp->{success} ) {
        log_msg(
"WARNING: Failed to get _nodes/stats/jvm from $endpoint: $stats_resp->{status}"
        );
        return;
    }

    my $stats = eval { decode_json( $stats_resp->{content} ) };
    if ( !$stats || !$stats->{nodes} ) {
        log_msg("WARNING: Malformed _nodes/stats/jvm response from $endpoint");
        return;
    }

    for my $node_id ( keys %{ $stats->{nodes} } ) {
        check_node_heap( $cluster_name, $stats->{nodes}{$node_id} );
    }
}

sub check_node_heap {
    my ( $cluster_name, $node ) = @_;

    my $node_name = $node->{name} // 'unknown';
    my $jvm_mem   = $node->{jvm}{mem};
    return unless $jvm_mem;

    my $heap_pct  = $jvm_mem->{heap_used_percent}  // return;
    my $heap_used = $jvm_mem->{heap_used_in_bytes} // 0;
    my $heap_max  = $jvm_mem->{heap_max_in_bytes}  // 0;

    my $key = "heap:$cluster_name:$node_name";
    my $heap_str =
        format_bytes($heap_used) . " / "
      . format_bytes($heap_max)
      . " (${heap_pct}%)";

    if ( $heap_pct >= $heap_crit ) {

      # Fire if: new alert, or escalating from warn -> crit, or cooldown expired
        my $prev = $alert_state{$key};
        if ( !$prev || $prev->{level} ne 'crit' || should_alert($key) ) {
            log_msg("CRITICAL: $node_name heap at ${heap_pct}% ($heap_str)");
            send_slack_alert(
                color => 'danger',
                title =>
                  ":rotating_light: CRITICAL: $node_name heap at ${heap_pct}%",
                text => "Heap is above the ${heap_crit}% critical threshold.",
                cluster => $cluster_name,
                fields  => [
                    {
                        title => 'Node',
                        value => $node_name,
                        short => JSON::true
                    },
                    {
                        title => 'Cluster',
                        value => $cluster_name,
                        short => JSON::true
                    },
                    {
                        title => 'Heap Used',
                        value => format_bytes($heap_used),
                        short => JSON::true
                    },
                    {
                        title => 'Heap Max',
                        value => format_bytes($heap_max),
                        short => JSON::true
                    },
                ],
            );
            record_alert( $key, 'crit' );
        }
    }
    elsif ( $heap_pct >= $heap_warn ) {
        if ( should_alert($key) ) {
            log_msg("WARNING: $node_name heap at ${heap_pct}% ($heap_str)");
            send_slack_alert(
                color   => 'warning',
                title   => ":warning: WARNING: $node_name heap at ${heap_pct}%",
                text    => "Heap is above the ${heap_warn}% warning threshold.",
                cluster => $cluster_name,
                fields  => [
                    {
                        title => 'Node',
                        value => $node_name,
                        short => JSON::true
                    },
                    {
                        title => 'Cluster',
                        value => $cluster_name,
                        short => JSON::true
                    },
                    {
                        title => 'Heap Used',
                        value => format_bytes($heap_used),
                        short => JSON::true
                    },
                    {
                        title => 'Heap Max',
                        value => format_bytes($heap_max),
                        short => JSON::true
                    },
                ],
            );
            record_alert( $key, 'warn' );
        }
    }
    else {
        # Heap OK — send recovery notification if we were alerting
        if ( $alert_state{$key} ) {
            log_msg("RECOVERED: $node_name heap at ${heap_pct}% ($heap_str)");
            send_slack_alert(
                color => 'good',
                title =>
":white_check_mark: RECOVERED: $node_name heap at ${heap_pct}%",
                text    => "Heap is back below the ${heap_warn}% threshold.",
                cluster => $cluster_name,
                fields  => [
                    {
                        title => 'Node',
                        value => $node_name,
                        short => JSON::true
                    },
                    {
                        title => 'Cluster',
                        value => $cluster_name,
                        short => JSON::true
                    },
                ],
            );
            delete $alert_state{$key};
        }
        log_msg("OK: $node_name heap ${heap_pct}% ($heap_str)") if $verbose;
    }
}

sub check_cluster_health {
    my ( $cluster_name, $health ) = @_;

    my $status = $health->{status} // 'unknown';
    my $key    = "health:$cluster_name";
    my $info   = sprintf(
        "Nodes: %d  Active shards: %d  Unassigned: %d",
        $health->{number_of_nodes}   // 0,
        $health->{active_shards}     // 0,
        $health->{unassigned_shards} // 0,
    );

    if ( $status eq 'red' ) {
        my $prev = $alert_state{$key};
        if ( !$prev || $prev->{level} ne 'crit' || should_alert($key) ) {
            log_msg("CRITICAL: Cluster $cluster_name health is RED — $info");
            send_slack_alert(
                color   => 'danger',
                title   => ":red_circle: Cluster $cluster_name is RED",
                text    => $info,
                cluster => $cluster_name,
            );
            record_alert( $key, 'crit' );
        }
    }
    elsif ( $status eq 'yellow' ) {
        if ( should_alert($key) ) {
            log_msg("WARNING: Cluster $cluster_name health is YELLOW — $info");
            send_slack_alert(
                color => 'warning',
                title =>
                  ":large_yellow_circle: Cluster $cluster_name is YELLOW",
                text    => $info,
                cluster => $cluster_name,
            );
            record_alert( $key, 'warn' );
        }
    }
    else {
        if ( $alert_state{$key} ) {
            log_msg("RECOVERED: Cluster $cluster_name health is GREEN — $info");
            send_slack_alert(
                color => 'good',
                title => ":large_green_circle: Cluster $cluster_name is GREEN",
                text  => $info,
                cluster => $cluster_name,
            );
            delete $alert_state{$key};
        }
        log_msg("OK: Cluster $cluster_name health GREEN — $info") if $verbose;
    }
}

sub should_alert {
    my ($key) = @_;
    my $state = $alert_state{$key};
    return 1 if !$state;
    return ( time() - $state->{time} ) >= $cooldown;
}

sub record_alert {
    my ( $key, $level ) = @_;
    $alert_state{$key} = { level => $level, time => time() };
}

sub send_slack_alert {
    my (%args) = @_;

    return unless $slack_webhook;

    my $payload = {
        attachments => [
            {
                color  => $args{color} // '#cccccc',
                title  => $args{title} // 'Elasticsearch Alert',
                text   => $args{text}  // '',
                footer => "elastic-heap-monitor | cluster: "
                  . ( $args{cluster} // 'unknown' ),
                ts => time(),
                ( $args{fields} ? ( fields => $args{fields} ) : () ),
            }
        ],
    };

    my $resp = $http->post(
        $slack_webhook,
        {
            content => encode_json($payload),
            headers => { 'Content-Type' => 'application/json' },
        }
    );

    if ( !$resp->{success} ) {
        log_msg("ERROR: Slack POST failed: $resp->{status} $resp->{reason}");
    }
}

sub log_msg {
    my ($msg) = @_;
    my $ts    = strftime( "%Y-%m-%d %H:%M:%S", localtime );
    my $line  = "[$ts] $msg\n";

    if ( $daemonize && $log_file ) {
        if ( open( my $fh, '>>', $log_file ) ) {
            $fh->autoflush(1);
            print $fh $line;
            close $fh;
        }
    }
    else {
        print STDERR $line;
    }
}

sub daemonize_process {

    # First fork
    defined( my $pid = fork() ) or die "Cannot fork: $!\n";
    exit 0 if $pid;

    # Session leader
    setsid() or die "Cannot setsid: $!\n";

    # Second fork — prevent reacquiring a controlling terminal
    defined( $pid = fork() ) or die "Cannot fork: $!\n";
    exit 0 if $pid;

    # Write and lock PID file
    open( $pid_fh, '>', $pid_file )
      or die "Cannot open PID file $pid_file: $!\n";
    flock( $pid_fh, LOCK_EX | LOCK_NB )
      or die "Another instance is already running (PID file locked)\n";
    $pid_fh->autoflush(1);
    print $pid_fh "$$\n";

    # Keep $pid_fh open to hold the lock for the lifetime of the process

    # Redirect standard file descriptors
    open( STDIN,  '<',  '/dev/null' ) or die "Cannot redirect STDIN: $!\n";
    open( STDOUT, '>>', $log_file )
      or die "Cannot redirect STDOUT to $log_file: $!\n";
    open( STDERR, '>>', $log_file )
      or die "Cannot redirect STDERR to $log_file: $!\n";
}

sub cleanup_pid {
    if ( $pid_file && -f $pid_file ) {
        unlink $pid_file;
    }
}

sub servers_from_hosts {
    my $hosts_file = '/etc/hosts';
    open( my $fh, '<', $hosts_file ) or do {
        warn "WARNING: Cannot read $hosts_file: $!\n";
        return;
    };

    my %seen;
    while ( my $line = <$fh> ) {
        $line =~ s/#.*//;          # strip comments
        $line =~ s/^\s+|\s+$//g;
        next unless $line;

        my ( $ip, @names ) = split /\s+/, $line;
        next unless $ip;

        for my $name (@names) {
            if ( $name =~ /^escluster/i && !$seen{$name} ) {
                $seen{$name} = 1;
            }
        }
    }
    close $fh;

    return unless %seen;
    return join( ',', map { "http://$_:9200" } sort keys %seen );
}

sub discover_clusters {
    my ($servers_str) = @_;
    my %clusters;

    my $disc_http = HTTP::Tiny->new(
        timeout => $http_timeout,
        agent   => "elastic-heap-monitor/$VERSION",
    );

    my @servers = grep { $_ } map { s/^\s+|\s+$//gr } split /,/, $servers_str;
    unless (@servers) {
        warn "WARNING: No servers provided for discovery\n";
        return;
    }

    for my $server_url (@servers) {
        my $resp = $disc_http->get($server_url);
        if ( !$resp->{success} ) {
            warn
"WARNING: Could not reach $server_url for discovery: $resp->{status}\n";
            next;
        }

        my $data = eval { decode_json( $resp->{content} ) };
        if ( !$data || !$data->{cluster_name} ) {
            warn
"WARNING: No cluster_name in response from $server_url, skipping\n";
            next;
        }

        my $cluster_name = $data->{cluster_name};
        push @{ $clusters{$cluster_name} }, $server_url;
    }

    if (%clusters) {
        for my $name ( sort keys %clusters ) {
            my $count = scalar @{ $clusters{$name} };
            log_msg( "Discovered cluster '$name' with $count node(s): "
                  . join( ', ', @{ $clusters{$name} } ) );
        }
    }
    else {
        warn "WARNING: Discovery found no reachable clusters\n";
    }

    return \%clusters;
}

sub format_bytes {
    my ($bytes) = @_;
    return '0 B' unless $bytes;

    my @units = qw( B KB MB GB TB );
    my $i = 0;
    while ( $bytes >= 1024 && $i < $#units ) {
        $bytes /= 1024;
        $i++;
    }
    return sprintf( "%.1f %s", $bytes, $units[$i] );
}

sub parse_clusters_env {
    my ($str) = @_;
    my %out;

    for my $entry ( split /;/, $str ) {
        $entry =~ s/^\s+|\s+$//g;
        next unless $entry;

        my ( $name, $urls ) = split /=/, $entry, 2;
        unless ( $name && $urls ) {
            warn "WARNING: Ignoring malformed cluster entry: '$entry'\n";
            next;
        }
        $name =~ s/^\s+|\s+$//g;
        my @endpoints = grep { $_ } map { s/^\s+|\s+$//gr } split /,/, $urls;
        unless (@endpoints) {
            warn "WARNING: No endpoints for cluster '$name', skipping\n";
            next;
        }
        $out{$name} = \@endpoints;
    }
    return \%out;
}

__END__

=head1 NAME

elastic-heap-monitor - Elasticsearch JVM heap monitor with Slack alerts

=head1 SYNOPSIS

    elastic-heap-monitor.pl [OPTIONS]

=head1 DESCRIPTION

Monitors Elasticsearch cluster health and per-node JVM heap usage, sending
alerts to Slack when configurable thresholds are exceeded. Supports recovery
notifications when values return to normal, and a cooldown period to prevent
alert floods.

Each setting uses the following precedence (highest to lowest):

    CLI flag > environment variable > config file > hardcoded default

=head1 OPTIONS

=over 4

=item B<--config> FILE

Path to configuration file. Default: F</etc/elastic-heap-monitor/elastic-heap-monitor.conf>.
[EHM_MONITOR_CONFIG]

=item B<--webhook> URL

Slack incoming webhook URL. [SLACK_WEBHOOK_URL]

=item B<--clusters> STR

Cluster definitions (see L</CLUSTER FORMAT>). [EHM_MONITOR_CLUSTERS]

=item B<--servers> STR

Comma-separated server URLs for auto-discovery (queries each server's API to
determine cluster grouping). [EHM_MONITOR_SERVERS]

=item B<--interval> SECS

Seconds between check cycles. Default: 60. [EHM_MONITOR_INTERVAL]

=item B<--warn> PCT

Heap warning threshold percent. Default: 80. [EHM_MONITOR_WARN]

=item B<--crit> PCT

Heap critical threshold percent. Default: 90. [EHM_MONITOR_CRIT]

=item B<--cooldown> SECS

Minimum seconds between repeat alerts. Default: 1800. [EHM_MONITOR_COOLDOWN]

=item B<--timeout> SECS

HTTP request timeout. Default: 10. [EHM_MONITOR_TIMEOUT]

=item B<--log> FILE

Log file path when daemonized. Default: F</var/log/elastic-heap-monitor.log>.
[EHM_MONITOR_LOG]

=item B<--pid> FILE

PID file path. Default: F</var/run/elastic-heap-monitor.pid>. [EHM_MONITOR_PID]

=item B<-d>, B<--daemonize>

Fork to background. [EHM_MONITOR_DAEMONIZE=1]

=item B<--once>

Run one check cycle then exit. [EHM_MONITOR_ONCE=1]

=item B<--test-alert>

Send a test message to Slack and exit.

=item B<-v>, B<--verbose>

Log OK status for every node. [EHM_MONITOR_VERBOSE=1]

=item B<-h>, B<--help>

Print this help text.

=item B<-V>, B<--version>

Print version.

=back

=head1 CONFIG FILE

The config file uses a simple C<key = value> format, one setting per line.
Lines starting with C<#> are comments. Keys correspond to the long CLI flag
names (without the leading C<-->).

Example F</etc/elastic-heap-monitor/elastic-heap-monitor.conf>:

    # Slack
    webhook = https://hooks.slack.com/services/XXX/YYY/ZZZ

    # Clusters
    clusters = c1=http://es1:9200;c2=http://es2:9200

    # Thresholds
    interval  = 30
    warn      = 80
    crit      = 90
    cooldown  = 1800
    timeout   = 10

    # Paths
    log = /var/log/elastic-heap-monitor.log
    pid = /var/run/elastic-heap-monitor.pid

    # Flags
    verbose   = 1

=head1 CLUSTER CONFIGURATION

Cluster endpoints are resolved with the following priority:

    --clusters > --servers > /etc/hosts auto-discovery

=head2 Cluster format

B<--clusters> / B<EHM_MONITOR_CLUSTERS>: semicolon-separated entries of
C<name=url1,url2>:

    cluster1-es7=http://escluster701:9200,http://escluster702:9200;cluster2-es7=http://escluster2701:9200

Multiple URLs per cluster provide failover -- the first reachable endpoint is
used each cycle.

=head2 Server discovery

B<--servers> / B<EHM_MONITOR_SERVERS>: comma-separated server URLs. Each
server's root API endpoint is queried to get its C<cluster_name>, and servers
are automatically grouped into clusters:

    http://escluster701:9200,http://escluster702:9200,http://escluster2701:9200

=head2 Hosts file discovery

If neither B<--clusters> nor B<--servers> is set, F</etc/hosts> is scanned for
hostnames starting with C<escluster>. Matching hosts are queried on port 9200
for auto-discovery, the same as B<--servers>.

=head1 MONITORED APIS

=over 4

=item B<_cluster/health>

Cluster status (green/yellow/red), node count, shard counts.

=item B<_nodes/stats/jvm>

Per-node JVM heap usage (used bytes, max bytes, percent) and GC stats.

=back

=head1 EXAMPLES

    # Foreground with verbose output (for testing)
    elastic-heap-monitor --webhook https://hooks.slack.com/... -v --once

    # All config via environment (ideal for Docker)
    export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
    export EHM_MONITOR_CLUSTERS='c1=http://es1:9200;c2=http://es2:9200'
    export EHM_MONITOR_INTERVAL=30
    elastic-heap-monitor

    # Daemonize in production
    elastic-heap-monitor --webhook https://hooks.slack.com/... -d

    # Verify Slack webhook
    elastic-heap-monitor --webhook https://hooks.slack.com/... --test-alert

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

=cut
