# Verify on-disk WAL contains no plaintext under the insert-time
# page-level CTR prototype.

use strict;
use warnings;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $canary = 'THE_CANARY_STRING_WAL_PAGELEVEL_INSERT_SHOULD_NEVER_APPEAR';

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
for my $f (@wal) {
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
