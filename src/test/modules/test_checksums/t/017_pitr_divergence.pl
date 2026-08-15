# Copyright (c) 2026, PostgreSQL Global Development Group

# A targeted PITR that replays a mismatched sync record must warn and
# promote instead of shutting down, and replication from the promoted
# node must work afterwards.
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

# Backup from before the checksum change, still off.
$primary->backup('bk');

# Enable checksums offline, then take a converged backup and write the
# WAL the PITR below recovers across: the startup sync record carrying
# "on", and a bit of data past it.
$primary->safe_psql('postgres', "UPDATE t SET a = a WHERE a = 1;");
$primary->stop;
$primary->checksum_enable_offline;
$primary->start;
$primary->backup('bk_on');
$primary->safe_psql('postgres', "INSERT INTO t VALUES (0);");
my $lsn_post = $primary->safe_psql('postgres',
	"SELECT pg_current_wal_insert_lsn()");
$primary->safe_psql('postgres', "SELECT pg_switch_wal()");
$primary->stop;

# PITR from the pre-change backup to a target past the sync record.
# Not a standby, so the mismatch must warn and recovery must reach the
# target and promote.
my $pitr = PostgreSQL::Test::Cluster->new('pitr');
$pitr->init_from_backup($primary, 'bk',
	has_restoring => 1,
	standby => 0);
$pitr->append_conf(
	'postgresql.conf', qq{
recovery_target_lsn = '$lsn_post'
recovery_target_action = 'promote'
# Retain timeline-2 WAL for the slot-less standbys attached later.
wal_keep_size = '128MB'
});
my $logstart = -s $pitr->logfile;
$pitr->start;
$pitr->poll_query_until('postgres', "SELECT NOT pg_is_in_recovery()")
  or die "PITR node did not promote";

my $log = PostgreSQL::Test::Utils::slurp_file($pitr->logfile, $logstart);
like(
	$log,
	qr/WARNING:.*does not match the state "on" of the node that wrote the WAL/,
	'PITR warned about the mismatched sync record');
unlike(
	$log,
	qr/shut down without replaying/,
	'no shutdown enforced during PITR');
test_checksum_state($pitr, 'off');
is( $pitr->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1001', 'PITR node readable after promotion');

# The promoted node inherited the archive_command of the primary, so its
# timeline history file ends up in the shared archive; make sure it is
# there before starting standbys off old-timeline backups, so that their
# timeline discovery targets the new timeline from the start.
my $tlifile = '00000002.history';
if (!-e $primary->archive_dir . '/' . $tlifile)
{
	my $tlipath = $primary->archive_dir . '/' . $tlifile;
	copy($pitr->data_dir . '/pg_wal/' . $tlifile, "$tlipath.tmp")
	  or die "copying $tlifile failed: $!";
	rename("$tlipath.tmp", $tlipath)
	  or die "renaming $tlifile failed: $!";
}

# Clear the recovery target before taking backups from the promoted
# node, or the target would be copied into them and reject any recovery
# starting past it.
$pitr->append_conf('postgresql.conf', "recovery_target_lsn = ''");

# Scenario (a): a fresh basebackup standby of the promoted node streams
# and stays in sync.
$pitr->backup('bk2');
my $fresh = PostgreSQL::Test::Cluster->new('fresh');
$fresh->init_from_backup($pitr, 'bk2', has_streaming => 1);
$fresh->start;
$pitr->safe_psql('postgres', "INSERT INTO t VALUES (-1);");
$pitr->wait_for_catchup($fresh);
test_checksum_state($fresh, 'off');
is( $fresh->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1002', 'fresh standby follows the promoted node');
$fresh->stop;

# Scenario (b): a standby restored from the pre-change backup crosses
# the timeline switch.  The old primary's sync record is on a timeline
# older than the recovery target, so it only warns; the standby ends up
# following the promoted node.
my $cross = PostgreSQL::Test::Cluster->new('cross');
$cross->init_from_backup($primary, 'bk',
	has_restoring => 1,
	standby => 1);
$cross->append_conf('postgresql.conf',
	"primary_conninfo = '" . $pitr->connstr . "'");
$logstart = -s $cross->logfile;
$cross->start;
$pitr->wait_for_catchup($cross);
$log = PostgreSQL::Test::Utils::slurp_file($cross->logfile, $logstart);
like(
	$log,
	qr/WARNING:.*does not match the state "on" of the node that wrote the WAL/,
	'old-timeline sync record warned, not enforced');
is( $cross->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1002', 'cross-timeline standby follows the promoted node');
test_checksum_state($cross, 'off');
$cross->stop;

# Scenario (c): a converged-"on" standby of the old primary re-pointed
# at the promoted node.  The promoted node wrote its own sync record
# carrying "off" at promotion; replaying it on the target timeline shuts
# the standby down.  One pg_checksums run converges it and it rejoins.
my $old = PostgreSQL::Test::Cluster->new('old');
$old->init_from_backup($primary, 'bk_on',
	has_restoring => 1,
	standby => 1);
$old->append_conf('postgresql.conf',
	"primary_conninfo = '" . $pitr->connstr . "'");
$logstart = -s $old->logfile;
start_maybe_self_shutdown($old);
$old->wait_for_log(
	qr/does not match the state "off" of the node that wrote the WAL/,
	$logstart);
wait_for_self_shutdown($old);

command_ok([ 'pg_checksums', '--disable', '-D', $old->data_dir ],
	'pg_checksums converges the re-pointed standby');
$old->start;
$pitr->wait_for_catchup($old);
test_checksum_state($old, 'off');
is( $old->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1002', 're-pointed standby follows the promoted node');
$old->stop;

$pitr->stop;
done_testing();
