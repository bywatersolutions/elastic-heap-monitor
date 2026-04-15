#!/usr/bin/perl

use Modern::Perl;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;

BEGIN {
    $ENV{EHM_TEST_MODE}        = 1;
    $ENV{EHM_MONITOR_CLUSTERS} = 'stub=http://localhost:9200';
    $ENV{EHM_MONITOR_CONFIG}   = '/nonexistent/elastic-heap-monitor.conf';
}

@ARGV = ();

my $script = "$FindBin::Bin/../elastic-heap-monitor.pl";
my $rv     = do $script;
die "Failed to load $script: $@" if $@;
die "Failed to load $script (do returned false)" unless $rv;

sub write_conf {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( SUFFIX => '.conf', UNLINK => 1 );
    print $fh $content;
    close $fh;
    return $path;
}

subtest 'nonexistent file returns empty results' => sub {
    my ( $opts, $clusters ) =
      main::read_config_file('/definitely/not/a/file.conf');
    is_deeply( $opts,     {}, 'empty opts' );
    is_deeply( $clusters, {}, 'empty clusters' );
};

subtest 'top-level scalars are read into opts' => sub {
    my $path = write_conf(<<'EOF');
webhook = https://hooks.slack.com/services/XXX/YYY/ZZZ
interval = 30
warn = 75
crit = 92
EOF
    my ( $opts, $clusters ) = main::read_config_file($path);
    is( $opts->{webhook},
        'https://hooks.slack.com/services/XXX/YYY/ZZZ',
        'webhook' );
    is( $opts->{interval},  '30', 'interval' );
    is( $opts->{warn},      '75', 'warn' );
    is( $opts->{crit},      '92', 'crit' );
    is_deeply( $clusters, {}, 'no clusters' );
};

subtest 'single <cluster NAME> block with multiple urls' => sub {
    my $path = write_conf(<<'EOF');
<cluster cluster1>
    url http://es1:9200
    url http://es2:9200
    url http://es3:9200
</cluster>
EOF
    my ( $opts, $clusters ) = main::read_config_file($path);
    is_deeply(
        $clusters,
        {
            cluster1 => [
                'http://es1:9200',
                'http://es2:9200',
                'http://es3:9200',
            ]
        },
        'three urls collected in order'
    );
};

subtest 'single <cluster NAME> block with one url' => sub {
    my $path = write_conf(<<'EOF');
<cluster test-cluster>
    url http://es-test:9200
</cluster>
EOF
    my ( $opts, $clusters ) = main::read_config_file($path);
    is_deeply(
        $clusters,
        { 'test-cluster' => ['http://es-test:9200'] },
        'single url normalized to arrayref'
    );
};

subtest 'multiple <cluster> blocks' => sub {
    my $path = write_conf(<<'EOF');
webhook = https://hooks.slack.com/foo

<cluster cluster1>
    url http://es1:9200
    url http://es2:9200
</cluster>

<cluster cluster2>
    url http://es3:9200
    url http://es4:9200
    url http://es5:9200
</cluster>

<cluster test-cluster>
    url http://es-test:9200
</cluster>
EOF
    my ( $opts, $clusters ) = main::read_config_file($path);
    is( $opts->{webhook}, 'https://hooks.slack.com/foo', 'webhook still read' );
    is( scalar keys %$clusters, 3, 'three clusters' );
    is( scalar @{ $clusters->{cluster1} },       2, 'cluster1 has 2' );
    is( scalar @{ $clusters->{cluster2} },       3, 'cluster2 has 3' );
    is( scalar @{ $clusters->{'test-cluster'} }, 1, 'test-cluster has 1' );
};

subtest 'empty <cluster> block is omitted' => sub {
    my $path = write_conf(<<'EOF');
<cluster empty>
</cluster>
<cluster real>
    url http://r:9200
</cluster>
EOF
    my ( $opts, $clusters ) = main::read_config_file($path);
    is_deeply( [ sort keys %$clusters ], ['real'], 'empty cluster dropped' );
};

subtest 'malformed config emits warning and returns empty' => sub {
    my $path = write_conf(<<'EOF');
<cluster unclosed>
    url http://x:9200
EOF
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my ( $opts, $clusters ) = main::read_config_file($path);
    ok( scalar @warnings >= 1, 'a warning was emitted' );
    like(
        $warnings[0],
        qr/Cannot parse config file/,
        'warning mentions parse failure'
    );
};

done_testing;
