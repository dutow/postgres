# Verify on-disk WAL contains no plaintext for the WAL GCM perf
# prototype.  Inserts a 50-byte ASCII canary, flushes + switches
# WAL, stops the server, greps every pg_wal/* segment for the
# canary (must find zero occurrences), then restarts and confirms
# the row reads back (i.e. the decrypt path round-trips through
# crash recovery).

use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $canary = 'THE_CANARY_STRING_THAT_SHOULD_NEVER_APPEAR_PLAINTEXT';

my $node = PostgreSQL::Test::Cluster->new('canary');
$node->init;
$node->start;

$node->safe_psql('postgres',
    "CREATE TABLE t (c text); INSERT INTO t VALUES ('$canary');");
$node->safe_psql('postgres', 'CHECKPOINT');
$node->safe_psql('postgres', 'SELECT pg_switch_wal()');

$node->stop;

my $pg_wal = $node->data_dir . '/pg_wal';
my @wal = glob "$pg_wal/*";
my $found = 0;
for my $f (@wal)
{
    next unless -f $f;
    open(my $fh, '<:raw', $f) or die "open $f: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    $found++ while $bytes =~ /\Q$canary\E/g;
}
is($found, 0, 'canary never appears in any pg_wal segment');

$node->start;
my $count = $node->safe_psql('postgres',
    "SELECT count(*) FROM t WHERE c = '$canary'");
is($count, '1',
    'row containing canary reads back after restart (decrypt round-trip)');

$node->stop;

done_testing();
