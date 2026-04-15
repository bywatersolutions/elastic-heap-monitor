#!/usr/bin/perl

use Modern::Perl;
use Test::More;
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

our @sent;
{
    no warnings qw(redefine once);
    *main::send_slack_alert = sub { push @sent, {@_} };
    *main::log_msg          = sub { };
}
sub reset_capture { @sent = () }

subtest 'RED status fires danger alert with shard counts' => sub {
    reset_capture();
    main::check_cluster_health(
        'ct_red',
        {
            status            => 'red',
            number_of_nodes   => 3,
            active_shards     => 100,
            unassigned_shards => 5,
        },
    );
    is( scalar @sent, 1, 'one alert sent' );
    is( $sent[0]{color},   'danger', 'danger color' );
    is( $sent[0]{cluster}, 'ct_red', 'cluster name passed through' );
    like( $sent[0]{title}, qr/RED/, 'title says RED' );
    like(
        $sent[0]{text},
        qr/Nodes: 3\s+Active shards: 100\s+Unassigned: 5/,
        'shard info in text'
    );
};

subtest 'YELLOW status fires warning alert' => sub {
    reset_capture();
    main::check_cluster_health(
        'ct_yellow',
        {
            status            => 'yellow',
            number_of_nodes   => 2,
            active_shards     => 50,
            unassigned_shards => 2,
        },
    );
    is( scalar @sent,    1,         'one alert sent' );
    is( $sent[0]{color}, 'warning', 'warning color' );
    like( $sent[0]{title}, qr/YELLOW/, 'title says YELLOW' );
    like(
        $sent[0]{text},
        qr/Nodes: 2\s+Active shards: 50\s+Unassigned: 2/,
        'shard info in text'
    );
};

subtest 'GREEN with no prior state sends nothing' => sub {
    reset_capture();
    main::check_cluster_health(
        'ct_green_fresh',
        {
            status            => 'green',
            number_of_nodes   => 1,
            active_shards     => 1,
            unassigned_shards => 0,
        },
    );
    is( scalar @sent, 0, 'no alert when first-seen GREEN' );
};

subtest 'GREEN after prior YELLOW fires recovery' => sub {
    reset_capture();
    main::check_cluster_health(
        'ct_recover',
        {
            status            => 'yellow',
            number_of_nodes   => 1,
            active_shards     => 1,
            unassigned_shards => 1,
        },
    );
    main::check_cluster_health(
        'ct_recover',
        {
            status            => 'green',
            number_of_nodes   => 1,
            active_shards     => 1,
            unassigned_shards => 0,
        },
    );
    is( scalar @sent,    2,      'yellow then recovery sent' );
    is( $sent[1]{color}, 'good', 'recovery color is good' );
    like( $sent[1]{title}, qr/GREEN/, 'recovery title says GREEN' );
};

subtest 'heap_info is included and sorted by heap pct desc' => sub {
    reset_capture();
    my $heap_info = [
        {
            name => 'low_node',
            pct  => 30,
            used => 3_000_000_000,
            max  => 10_000_000_000
        },
        {
            name => 'high_node',
            pct  => 90,
            used => 9_000_000_000,
            max  => 10_000_000_000
        },
        {
            name => 'mid_node',
            pct  => 60,
            used => 6_000_000_000,
            max  => 10_000_000_000
        },
    ];
    main::check_cluster_health(
        'ct_heap',
        {
            status            => 'yellow',
            number_of_nodes   => 3,
            active_shards     => 30,
            unassigned_shards => 1,
        },
        $heap_info,
    );
    is( scalar @sent, 1, 'one alert sent' );
    my $text = $sent[0]{text};
    like( $text, qr/Heap usage:/, 'heap usage section present' );
    like( $text, qr/high_node: 90%/, 'high_node pct shown' );
    like( $text, qr/mid_node: 60%/,  'mid_node pct shown' );
    like( $text, qr/low_node: 30%/,  'low_node pct shown' );

    my $high_pos = index( $text, 'high_node' );
    my $mid_pos  = index( $text, 'mid_node' );
    my $low_pos  = index( $text, 'low_node' );
    cmp_ok( $high_pos, '>',  -1,        'high_node listed' );
    cmp_ok( $mid_pos,  '>',  $high_pos, 'mid_node after high_node' );
    cmp_ok( $low_pos,  '>',  $mid_pos,  'low_node after mid_node' );
};

subtest 'no heap_info renders alert without heap section' => sub {
    reset_capture();
    main::check_cluster_health(
        'ct_noheap',
        {
            status            => 'yellow',
            number_of_nodes   => 1,
            active_shards     => 1,
            unassigned_shards => 1,
        },
    );
    is( scalar @sent, 1, 'one alert sent' );
    unlike( $sent[0]{text}, qr/Heap usage:/, 'no heap section' );
};

subtest 'empty heap_info arrayref renders alert without heap section' =>
  sub {
    reset_capture();
    main::check_cluster_health(
        'ct_emptyheap',
        {
            status            => 'red',
            number_of_nodes   => 1,
            active_shards     => 1,
            unassigned_shards => 1,
        },
        [],
    );
    is( scalar @sent, 1, 'one alert sent' );
    unlike( $sent[0]{text}, qr/Heap usage:/, 'no heap section' );
  };

done_testing;
