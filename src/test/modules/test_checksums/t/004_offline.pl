
# Copyright (c) 2026, PostgreSQL Global Development Group

# Test suite for testing enabling data checksums offline from various states
# of checksum processing
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Check the data checksum origin recorded in pg_control
sub test_checksum_origin
{
	my ($node, $expected, $test_name) = @_;
	my ($stdout, $stderr) = run_command([ 'pg_controldata', $node->data_dir ]);
	like(
		$stdout,
		qr/^Data checksum origin:\s+\Q$expected\E$/m,
		$test_name);
}

# Initialize node with checksums disabled.
my $node = PostgreSQL::Test::Cluster->new('offline_node');
$node->init(no_data_checksums => 1);
$node->start;

# Create some content to have un-checksummed data in the cluster
$node->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,10000) AS a;");

# Ensure that checksums are disabled, with an initdb (online) origin
test_checksum_state($node, 'off');
$node->stop;
test_checksum_origin($node, 'online', 'origin is online after initdb');

# Enable checksums offline using pg_checksums
$node->checksum_enable_offline;
test_checksum_origin($node, 'offline-enable',
	'origin is offline-enable after offline enable');
$node->start;

# Ensure that checksums are enabled
test_checksum_state($node, 'on');

# Run a dummy query just to make sure we can read back some data
my $result =
  $node->safe_psql('postgres', "SELECT count(*) FROM t WHERE a > 1");
is($result, '9999', 'ensure checksummed pages can be read back');

# Disable checksums offline again using pg_checksums
$node->stop;
$node->checksum_disable_offline;
test_checksum_origin($node, 'offline-disable',
	'origin is offline-disable after offline disable');
$node->start;

# Ensure that checksums are disabled
test_checksum_state($node, 'off');

# Create a barrier for checksum enablement to block on, in this case a pre-
# existing temporary table which is kept open while processing is started. We
# can accomplish this by setting up an interactive psql process which keeps the
# temporary table created as we enable checksums in another psql process.

my $bsession = $node->background_psql('postgres');
$bsession->query_safe('CREATE TEMPORARY TABLE tt (a integer);');

# In another session, make sure we can see the blocking temp table but start
# processing anyways and check that we are blocked with a proper wait event.
$result = $node->safe_psql('postgres',
	"SELECT relpersistence FROM pg_catalog.pg_class WHERE relname = 'tt';");
is($result, 't', 'ensure we can see the temporary table');

# Enable, but stop waiting at inprogress-on since it will sit there until the
# above temporary table is removed.
enable_data_checksums($node, wait => 'inprogress-on');

# Turn the cluster off and enable checksums offline, then start back up.
# Stop the cluster before exiting the background session since otherwise
# checksums might have time to get enabled before shutting down the cluster.
$node->stop('fast');
$bsession->quit;
$node->checksum_enable_offline;
test_checksum_origin($node, 'offline-enable',
	'origin is offline-enable after offline enable during inprogress-on');
$node->start;

# Ensure that checksums are now enabled even though processing wasn't
# restarted
test_checksum_state($node, 'on');

# Run a dummy query just to make sure we can read back some data
$result = $node->safe_psql('postgres', "SELECT count(*) FROM t WHERE a > 1");
is($result, '9999', 'ensure checksummed pages can be read back');

# The last state change was made offline, so the origin still reflects that.
# A completed online transition must reset it to online.
disable_data_checksums($node, wait => 'off');
test_checksum_state($node, 'off');

$node->stop;
test_checksum_origin($node, 'online',
	'origin is online after online transition');
done_testing();
