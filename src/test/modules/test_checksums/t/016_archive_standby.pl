# Copyright (c) 2026, PostgreSQL Global Development Group

# Offline checksum divergence enforcement for archive-fed standbys.
# Without a replication connection the sync record travels through the
# archive, and is the only mechanism that stops a diverged standby
# (scenarios 1 and 2).  Once the standby also has a connection, the
# state sampled at connect takes over where the archive leaves off
# (scenario 3).  A promotion drains a sync record still sitting in
# pg_wal warn-only instead of shutting down (scenario 4).
use strict;
use warnings FATAL => 'all';

use File::Copy;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Primary with archiving, checksums off.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(
	has_archiving => 1,
	allows_streaming => 1,
	no_data_checksums => 1);
$primary->append_conf('postgresql.conf', 'autovacuum = off');
$primary->start;
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,1000) AS a;");
$primary->backup('bk');

# Archive-fed standby: restore_command and standby.signal only, no
# primary_conninfo.
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'bk',
	has_restoring => 1,
	standby => 1);
$standby->start;

# Ship everything up to the current insert position through the archive
# and wait until the standby has replayed it.
sub archive_catchup
{
	# Make sure the segment switch below is not a no-op.
	$primary->safe_psql('postgres', "SELECT txid_current();");
	my $lsn = $primary->safe_psql('postgres',
		"SELECT pg_current_wal_insert_lsn()");
	$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
	$standby->poll_query_until('postgres',
		"SELECT pg_last_wal_replay_lsn() >= '$lsn'::pg_lsn")
	  or die "standby did not catch up via archive";
	return;
}

archive_catchup();
test_checksum_state($primary, 'off');
test_checksum_state($standby, 'off');

# Scenario 1: enable offline on the primary only.  Its next startup logs
# the sync record carrying "on"; the standby replays it from the archive
# and shuts down cleanly.
# Dirty a page in WAL the standby has not yet replayed, so that the
# shutdown at the sync record below has replayed-but-unflushed changes
# to write out.
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a = 1;");
$primary->stop;
$primary->checksum_enable_offline;
$primary->start;
$primary->safe_psql('postgres', "INSERT INTO t VALUES (0);");
test_checksum_state($primary, 'on');

my $logstart = -s $standby->logfile;
$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
$standby->wait_for_log(
	qr/does not match the state "on" of the node that wrote the WAL/,
	$logstart);
wait_for_self_shutdown($standby);

# A restart without converging re-restores the same segment and must
# shut down at the same record again.
$logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of the node that wrote the WAL/,
	$logstart);
wait_for_self_shutdown($standby);

# Converge the standby and rejoin through the archive.
command_ok([ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	'pg_checksums converges the archive standby');
$standby->start;
archive_catchup();
test_checksum_state($standby, 'on');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1001', 'archive standby readable after converging');

# Scenario 2: disable offline on the standby only.  On startup the
# standby re-replays older checkpoint records carrying "on" and warns
# once; the fresh CHECKPOINT below carries the same value and must not
# warn again.  The wait_for_log observes that once-per-value warning;
# the point is that the standby keeps running until the next primary
# restart ships a new sync record.
$standby->stop;
$standby->checksum_disable_offline;
$logstart = -s $standby->logfile;
$standby->start;
test_checksum_state($standby, 'off');

$primary->safe_psql('postgres', "CHECKPOINT;");
archive_catchup();
$standby->wait_for_log(
	qr/does not match the state "on" in the replayed WAL/, $logstart);
is($standby->safe_psql('postgres', "SELECT 1"),
	'1', 'diverged archive standby keeps running warn-only');

$logstart = -s $standby->logfile;
$primary->restart;
$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
$standby->wait_for_log(
	qr/does not match the state "on" of the node that wrote the WAL/,
	$logstart);
wait_for_self_shutdown($standby);

command_ok([ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	'pg_checksums converges the archive standby back');
$standby->start;
archive_catchup();
test_checksum_state($standby, 'on');

# Scenario 3: archive catch-up followed by streaming.  A diverged
# standby that first works through a backlog of archived WAL is
# tolerated for as long as the backlog holds no sync record, and is
# only judged once the walreceiver connects.  Move the primary to an
# online-origin "on" first, so that it is the fence rule of the
# connection check, and not the immediate offline-origin shutdown,
# that fires at the seam; the standby follows the online transitions
# through the archive.
disable_data_checksums($primary, wait => 'off');
enable_data_checksums($primary, wait => 'on');
archive_catchup();
test_checksum_state($standby, 'on');

# The primary restart moves the standby's restartpoint horizon past
# the transition records, so that pg_checksums accepts its control
# file, and writes a sync record the standby replays while the states
# still match; its re-replay below the consistency point after the
# standby's own restart below is tolerated (cf. 010_offline_standby.pl
# scenario 5).
$primary->restart;
archive_catchup();

# Disable offline on the standby only, and put WAL in transit that the
# restarted standby fetches from the archive first.  None of it is a
# sync record, so the record layer stays warn-only while the archive
# is drained.  The second update lands after the segment switch and is
# only available over the connection; replaying it carries the standby
# past the fence right away, instead of stalling on background WAL.
$standby->stop;
$standby->checksum_disable_offline;
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a = 1;");
$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a = 2;");

# Adding primary_conninfo makes the standby stream once the archive is
# exhausted.  At connect the walreceiver samples the primary's
# online-origin "on"; the fence sampled with it lies right past the
# WAL the standby just restored, so replay passes it promptly and the
# remaining difference shuts the standby down.
$standby->append_conf('postgresql.conf',
	"primary_conninfo = '" . $primary->connstr . "'");
$logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of its upstream server/, $logstart);
$standby->wait_for_log(
	qr/no WAL remains in transit that could reconcile the states/,
	$logstart);
wait_for_self_shutdown($standby);

# The shutdown came from the connection check after the archive ran
# dry, not from a record.  The walreceiver may not have gotten around
# to logging its streaming start before the shutdown, so anchor the
# ordering on the mismatch message the startup process logs itself.
my $log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
like(
	$log,
	# any restore before the mismatch suffices
	qr/restored log file .* from archive.*does not match the state "on" of its upstream server/s,
	'archive was drained before the divergence was judged');
unlike(
	$log,
	qr/of the node that wrote the WAL/,
	'standby was stopped by the connection check, not a sync record');

# Converge the standby and rejoin, now over both transports.
command_ok([ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	'pg_checksums converges the archive standby at the seam');
$standby->start;
archive_catchup();
test_checksum_state($standby, 'on');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1001', 'standby readable after converging at the seam');
$standby->stop;

# Scenario 4: a promotion triggered while a mismatched sync record is
# present in the standby's pg_wal but not yet replayed.  The drain
# before promoting replays the record with the promotion already
# triggered, so it must warn and promote instead of shutting down.
$primary->backup('bk2');
my $standby2 = PostgreSQL::Test::Cluster->new('standby2');
$standby2->init_from_backup($primary, 'bk2', has_streaming => 1);
$standby2->start;
$primary->wait_for_catchup($standby2);
test_checksum_state($standby2, 'on');

# Pause replay.  The paused startup process neither applies records nor
# restarts the walreceiver once the primary goes away below.
$standby2->safe_psql('postgres', "SELECT pg_wal_replay_pause();");
$standby2->poll_query_until('postgres',
	"SELECT pg_get_wal_replay_pause_state() = 'paused'")
  or die "standby did not pause replay";

# Disable offline on the primary; its restart writes a sync record
# carrying "off".
$primary->stop;
$primary->checksum_disable_offline;
$primary->start;
$primary->safe_psql('postgres', "INSERT INTO t VALUES (-1);");
my $walfile = $primary->safe_psql('postgres',
	"SELECT pg_walfile_name(pg_current_wal_insert_lsn())");
$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
$primary->poll_query_until('postgres',
	"SELECT last_archived_wal >= '$walfile' FROM pg_stat_archiver")
  or die "the sync record segment was not archived";

# Hand the archived segments to the paused standby, so that the sync
# record sits in its pg_wal unreplayed when the promotion is triggered.
# Draining the record from the standby's own pg_wal rather than through
# restore_command is the point of this scenario.  The already-present
# prefix of the current segment is byte-identical, so overwriting the
# streamed partial copy with the archived one is safe.
my $wal_dir = $standby2->data_dir . '/pg_wal';
opendir(my $adir, $primary->archive_dir) or die "opendir: $!";
foreach my $segment (sort grep { /^[0-9A-F]{24}$/ } readdir($adir))
{
	copy($primary->archive_dir . '/' . $segment, "$wal_dir/$segment.tmp")
	  or die "copying $segment failed: $!";
	rename("$wal_dir/$segment.tmp", "$wal_dir/$segment")
	  or die "renaming $segment failed: $!";
}
closedir($adir);

$logstart = -s $standby2->logfile;
$standby2->promote;
$standby2->poll_query_until('postgres', "SELECT NOT pg_is_in_recovery()")
  or die "standby did not promote";

$log = PostgreSQL::Test::Utils::slurp_file($standby2->logfile, $logstart);
like(
	$log,
	qr/WARNING:.*does not match the state "off" of the node that wrote the WAL/,
	'drained sync record warned during promotion');
unlike(
	$log,
	qr/shut down without replaying/,
	'no shutdown enforced during promotion');
test_checksum_state($standby2, 'on');
is( $standby2->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1002', 'promoted standby readable after the drain');

$standby2->stop;
$primary->stop;
done_testing();
