# Copyright (c) 2026, PostgreSQL Global Development Group

# Offline checksum divergence in a cascading chain.  WAL records always
# carry the state of the node that wrote them, and a cascading standby
# never leaves recovery, so its own offline change appears in no record
# at all: only the connection-based check can express it.  A cascading
# walsender answers the state request of its walreceivers with its own
# local state, so each standby is judged against its direct upstream,
# and both directions of a mid-tier divergence are enforced pairwise:
# the leaf against the intermediate, and the intermediate against the
# primary.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Primary with checksums enabled online, so that its state keeps the
# online origin and the diverged intermediate below is judged by the
# fence rule rather than shut down at once.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf('postgresql.conf', 'autovacuum = off');
$primary->start;
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,1000) AS a;");
enable_data_checksums($primary, wait => 'on');

# Intermediate standby.  The backup checkpoint lies past the online
# transition records, so the intermediate never re-replays them and
# pg_checksums accepts its control file after a clean stop.
$primary->backup('bk');
my $mid = PostgreSQL::Test::Cluster->new('mid');
$mid->init_from_backup($primary, 'bk', has_streaming => 1);
$mid->start;
$primary->wait_for_catchup($mid);

# Leaf standby cascading from the intermediate.
$mid->backup('bkmid');
my $leaf = PostgreSQL::Test::Cluster->new('leaf');
$leaf->init_from_backup($mid, 'bkmid', has_streaming => 1);
$leaf->start;
$mid->wait_for_catchup($leaf);

test_checksum_state($primary, 'on');
test_checksum_state($mid, 'on');
test_checksum_state($leaf, 'on');

# Disable checksums offline on the intermediate only.  Cut its upstream
# link before restarting it: without a connection there is no sample to
# judge, so the diverged intermediate keeps running and can serve the
# leaf, letting the two directions of the divergence be tested in
# isolation.  The primary keeps running throughout, so no sync record
# is written anywhere while the chain is diverged; a primary restart
# here would put one in transit, and the record-based shutdown would
# fire on the intermediate before its replay could reach the fence.
$leaf->stop;
$mid->stop;
$mid->checksum_disable_offline;
$mid->append_conf('postgresql.conf', "primary_conninfo = ''");
$mid->start;
test_checksum_state($mid, 'off');

# Leaf against the intermediate.  The sampled state is the
# intermediate's own "off", not the primary's "on", and its offline
# origin means no WAL could ever reconcile it, so the leaf shuts down
# cleanly at once.
my $logstart = -s $leaf->logfile;
start_maybe_self_shutdown($leaf);
$leaf->wait_for_log(
	qr/does not match the state "off" of its upstream server/, $logstart);
$leaf->wait_for_log(
	qr/of the upstream server was set with pg_checksums/, $logstart);
wait_for_self_shutdown($leaf);

# The enforcement is pairwise: the leaf is gone, but the intermediate
# has no upstream connection and keeps running.
is( $mid->safe_psql('postgres', "SELECT 1"),
	'1', 'diverged intermediate keeps running without an upstream link');

# Intermediate against the primary.  Restore the upstream link; the
# startup process picks up the reload and starts streaming on its next
# retry.  The primary's "on" has an online origin, so the intermediate
# is only judged once it has replayed up to the fence sampled at
# connect.  The row inserted here lies below that fence and gives the
# reconnect WAL to work through; the shutdown does not depend on it,
# since a fully caught-up standby is already at its fence.
$primary->safe_psql('postgres', "INSERT INTO t VALUES (0);");
$logstart = -s $mid->logfile;
$mid->append_conf('postgresql.conf',
	"primary_conninfo = '" . $primary->connstr . "'");
$mid->reload;
$mid->wait_for_log(
	qr/does not match the state "on" of its upstream server/, $logstart);
$mid->wait_for_log(
	qr/no WAL remains in transit that could reconcile the states/,
	$logstart);
wait_for_self_shutdown($mid);

# No node restarted during the divergence, so no sync record can have
# been involved; the connection check alone stopped the intermediate.
my $log = PostgreSQL::Test::Utils::slurp_file($mid->logfile, $logstart);
unlike(
	$log,
	qr/of the node that wrote the WAL/,
	'intermediate was stopped by the connection check, not a sync record');

# Both shutdowns are clean.  Only the intermediate ever changed its
# state; converge it back with pg_checksums and restart the chain top
# down.  The leaf never diverged and just restarts once its upstream
# is back in the matching state.
command_ok([ 'pg_checksums', '--enable', '-D', $mid->data_dir ],
	'pg_checksums converges the intermediate');
$mid->start;
$primary->wait_for_catchup($mid);
$leaf->start;
$mid->wait_for_catchup($leaf);

test_checksum_state($mid, 'on');
test_checksum_state($leaf, 'on');
is( $leaf->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1001', 'leaf readable after converging the chain');

$leaf->stop;
$mid->stop;
$primary->stop;
done_testing();
