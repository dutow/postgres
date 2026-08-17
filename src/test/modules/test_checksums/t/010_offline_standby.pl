# Copyright (c) 2026, PostgreSQL Global Development Group

# Offline checksum changes with pg_checksums are local to one node.  A
# standby must neither adopt the state of the primary from replayed
# checkpoint records, nor lose its own offline change to them, and a
# diverged standby must shut down instead of running with a mix of
# states.  Two layers enforce the shutdown: replaying a mismatched
# XLOG2_CHECKSUMS_SYNC record, which is the only mechanism for
# archive-fed standbys and is tested in 016_archive_standby.pl, and the
# upstream state the walreceiver samples at every connect, which fires
# without waiting for a record.  Over a live connection the sampled
# state is judged first, so this file tests the connection-based layer:
# the immediate shutdown on an offline-origin difference (scenarios 1
# and 2), silence while the states match or a transition is in progress
# (scenarios 3 and 4), and the fence rule for online-origin differences
# (scenario 5).
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

# Primary and standby, checksums off.
my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf('postgresql.conf', 'autovacuum = off');
$primary->start;
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,10000) AS a;");

$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($primary, 'off');
test_checksum_state($standby, 'off');

# Scenario 1: enable offline on the primary only.  At reconnect the
# walreceiver samples the primary's new state; it differs, and its
# offline origin means no WAL could ever reconcile it, so the standby
# shuts down cleanly at once instead of continuing with an unsupported
# mix of states.
$standby->stop;
$primary->stop;
$primary->checksum_enable_offline;
$primary->start;
$primary->safe_psql('postgres', "INSERT INTO t VALUES (0);");

test_checksum_state($primary, 'on');

my $logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of its upstream server/, $logstart);
wait_for_self_shutdown($standby);

# A plain restart without converging must shut down again.  The first
# shutdown may have streamed the primary's sync record into local pg_wal
# without replaying it, so either layer can fire first here: the record
# during the replay of local WAL, or the sample at reconnect.
$logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of (its upstream server|the node that wrote the WAL)/,
	$logstart);
wait_for_self_shutdown($standby);

# The shutdown is clean, so pg_checksums can converge the standby; no
# rebuild is needed.
command_checks_all(
	[ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	0,
	[qr/appears to be a standby/],
	[],
	'standby-role notice on offline enable');
$standby->start;
test_checksum_state($standby, 'on');
$primary->wait_for_catchup($standby);
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable after converging');

my $log;

# Scenario 2: disable offline on the standby only.  The upstream's "on"
# has an offline origin (scenario 1's pg_checksums run on the primary),
# so the difference is judged immediately at the standby's own
# reconnect, with the message naming the upstream's offline change.
# Without a connection the same divergence only warns until the next
# sync record arrives; that behavior is tested in 016_archive_standby.pl.
$standby->stop;
$standby->checksum_disable_offline;
$logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of its upstream server/, $logstart);
$standby->wait_for_log(
	qr/of the upstream server was set with pg_checksums/, $logstart);
wait_for_self_shutdown($standby);

# Converge the standby back and rejoin.
command_ok([ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	'pg_checksums converges the shut-down standby');
$standby->start;
test_checksum_state($standby, 'on');
$primary->wait_for_catchup($standby);
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable after converging back');

# Scenario 3: crash-restart right after an online transition, before the
# next restartpoint.  Replay then resumes from an older restartpoint whose
# checkpoint records still carry the pre-transition state.  Those must
# still match the state seeded from the control file, and the transition
# itself must be re-established by re-replaying the XLOG2_CHECKSUMS record,
# without a spurious mismatch warning along the way.  The transition also
# moves the standby away from the state sampled at its last connect; the
# connection check must recognize the sample as stale and stay silent
# instead of shutting the standby down.

# Scenario 2 left both nodes converged at "on".
test_checksum_state($standby, 'on');
test_checksum_state($primary, 'on');

# Online-disable on the primary and let it propagate to the standby.
disable_data_checksums($primary, wait => 'off');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'off');

# Crash-restart the standby immediately, before any restartpoint has had a
# chance to persist the new state to its control file.
$logstart = -s $standby->logfile;
$standby->stop('immediate');
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($standby, 'off');
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001',
	'standby readable after crash-restart across an online transition');

$log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/does not match the state/,
	'no spurious mismatch warning after crash-restart across an online transition'
);

# Scenario 4: a standby stopped while replaying an interrupted online
# transition keeps the interrupted state in its own control file, and
# pg_checksums must refuse to touch it.  The primary can never be
# caught this way: its checksums launcher process resolves inprogress-on
# back to off from its own exit cleanup whenever it exits, which happens
# on any graceful stop.  A standby has no launcher; it only carries
# forward whatever state the last replayed record left it in, and a
# restartpoint persists it once it has replayed a checkpoint whose redo
# point is past the transition record.

# Block an online enable on the primary at inprogress-on with a
# blocking temp table, same trick as in 004_offline.pl.
my $bsession = $primary->background_psql('postgres');
$bsession->query_safe('CREATE TEMPORARY TABLE tt (a integer);');
enable_data_checksums($primary, wait => 'inprogress-on');

# The standby replays the XLOG2_CHECKSUMS record and picks up the
# in-progress state itself.
wait_for_checksum_state($standby, 'inprogress-on');

# Write a checkpoint on the primary so that its redo point is past the
# transition record, let the standby replay it, and stop the standby
# cleanly; the shutdown restartpoint persists inprogress-on to its own
# control file, since nothing on a standby resolves it away.
$primary->safe_psql('postgres', 'CHECKPOINT;');
$primary->wait_for_catchup($standby);
$standby->stop;

command_fails_like(
	[ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --enable refuses a standby stopped mid-transition');
command_fails_like(
	[ 'pg_checksums', '--check', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --check refuses a standby stopped mid-transition');
command_fails_like(
	[ 'pg_checksums', '--disable', '-D', $standby->data_dir ],
	qr/online data checksum state transition was interrupted/,
	'pg_checksums --disable refuses a standby stopped mid-transition');

# Bring the standby back while the upstream still reports inprogress-on.
# The reconnect must be tolerated: in-progress states resolve through
# replay and are never judged by the connection check.
$logstart = -s $standby->logfile;
$standby->start;
$primary->wait_for_catchup($standby);
$log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/of its upstream server/,
	'reconnect tolerated during a blocked transition');

# Let the primary's transition complete.
$bsession->quit;
wait_for_checksum_state($primary, 'on');
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10001', 'standby readable once the transition completes');

# Scenario 5: the fence rule.  The primary's "on" now has an online
# origin (scenario 4's completed transition), so a WAL-logged transition
# could in principle still be in transit when a diverged standby
# reconnects; the sample is only judged once the standby has replayed up
# to the fence position the upstream reported with it.
#
# The primary restart moves the standby's restartpoint horizon past the
# transition records, so that pg_checksums accepts its control file, and
# writes a sync record the standby replays while the states still match.
# The restarted standby re-replays that record below its consistency
# point, where it is tolerated just like old checkpoint records are.
$primary->restart;
$primary->wait_for_catchup($standby);

$standby->stop;
$standby->checksum_disable_offline;

# WAL written while the standby is down lies before the fence its
# reconnect will report, and must be replayed before the divergence is
# judged.
$primary->safe_psql('postgres',
	"INSERT INTO t SELECT generate_series(10002, 10101);");
my $intransit_lsn =
  $primary->safe_psql('postgres', "SELECT pg_current_wal_insert_lsn();");

$logstart = -s $standby->logfile;
start_maybe_self_shutdown($standby);
$standby->wait_for_log(
	qr/does not match the state "on" of its upstream server/, $logstart);
$standby->wait_for_log(
	qr/no WAL remains in transit that could reconcile the states/,
	$logstart);
wait_for_self_shutdown($standby);

# The clean shutdown persisted the replay position; it must lie past the
# WAL that was in transit at reconnect, proving the standby was tolerated
# until it had replayed up to the fence.
my ($stdout, $stderr) =
  PostgreSQL::Test::Utils::run_command(
	[ 'pg_controldata', $standby->data_dir ]);
$stdout =~ qr/Minimum recovery ending location:\s+([0-9A-F]+\/[0-9A-F]+)/
  or die "minimum recovery ending location not found in pg_controldata";
my $minrecovery_lsn = $1;
is( $primary->safe_psql('postgres',
		"SELECT '$minrecovery_lsn'::pg_lsn >= '$intransit_lsn'::pg_lsn;"),
	't',
	'in-transit WAL replayed before the fence shutdown');

# Converge the standby back and rejoin.
command_ok([ 'pg_checksums', '--enable', '-D', $standby->data_dir ],
	'pg_checksums converges the fence-stopped standby');
$standby->start;
test_checksum_state($standby, 'on');
$primary->wait_for_catchup($standby);
is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'10101', 'standby readable after converging back again');

$standby->stop;
$primary->stop;
done_testing();
