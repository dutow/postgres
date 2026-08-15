# Copyright (c) 2026, PostgreSQL Global Development Group

# A standby's control file must not persist a data checksum state that is
# newer than the redo pointer its next crash recovery resumes from.  Force
# both records of an online transition between a checkpoint's REDO record
# and the checkpoint record, persist a restartpoint from that checkpoint,
# and crash-restart the standby: replay walks back through the
# pre-transition REDO record, which must agree with the state seeded from
# the control file.
use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use DataChecksums::Utils;

if ($ENV{enable_injection_points} ne 'yes')
{
	plan skip_all => 'Injection points not supported by this build';
}

my $primary = PostgreSQL::Test::Cluster->new('primary');
$primary->init(allows_streaming => 1, no_data_checksums => 1);
$primary->append_conf('postgresql.conf', 'autovacuum = off');
$primary->start;
$primary->safe_psql('postgres', 'CREATE EXTENSION injection_points;');
$primary->safe_psql('postgres',
	"CREATE TABLE t AS SELECT generate_series(1,1000) AS a;");

$primary->backup('backup');
my $standby = PostgreSQL::Test::Cluster->new('standby');
$standby->init_from_backup($primary, 'backup', has_streaming => 1);
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($primary, 'off');
test_checksum_state($standby, 'off');

# Remember where the standby's control file points before the scenario,
# to verify later that its restartpoint really moved it.
my $initial_redo = $standby->safe_psql('postgres',
	'SELECT redo_lsn FROM pg_control_checkpoint();');

# Pause a checkpoint right after its REDO record, outside the critical
# section so the waiting checkpointer still absorbs the transition's
# procsignal barriers.
$primary->safe_psql('postgres',
	q{SELECT injection_points_attach('create-checkpoint-before-guts', 'wait')}
);

my $checkpoint = $primary->background_psql('postgres');
$checkpoint->query_until(
	qr/starting_checkpoint/,
	q(\echo starting_checkpoint
checkpoint;
));
$primary->wait_for_event('checkpointer', 'create-checkpoint-before-guts');

# Run a full online enable inside the window.  Both XLOG2_CHECKSUMS
# records now precede the paused checkpoint's record while its redo
# pointer precedes them.  Do not wait for the enable machinery to wind
# down here: on its way out it requests one more checkpoint, which
# cannot complete while the injection point holds checkpoints.
enable_data_checksums($primary);
wait_for_checksum_state($primary, 'on');

# Release the in-window checkpoint, but keep the injection point
# attached: the trailing checkpoint requested by the enable machinery
# then pauses at it as well, keeping its record out of the WAL until the
# standby has taken a restartpoint from the in-window checkpoint.
$primary->safe_psql('postgres',
	q{SELECT injection_points_wakeup('create-checkpoint-before-guts')});
$checkpoint->quit;

# Let the standby replay the whole window and persist a restartpoint
# from the released checkpoint.
$primary->wait_for_catchup($standby);
wait_for_checksum_state($standby, 'on');
$standby->safe_psql('postgres', 'CHECKPOINT;');

# Guard against the restartpoint silently doing nothing, which would
# make the assertions below pass vacuously.
is( $standby->safe_psql(
		'postgres',
		"SELECT pg_wal_lsn_diff(redo_lsn, '$initial_redo') > 0 "
		  . 'FROM pg_control_checkpoint();'),
	't',
	'restartpoint installed the in-window checkpoint');

# Crash-restart: replay resumes from the pre-transition redo pointer.
my $logstart = -s $standby->logfile;
$standby->stop('immediate');
$standby->start;
$primary->wait_for_catchup($standby);

test_checksum_state($standby, 'on');
my $log = PostgreSQL::Test::Utils::slurp_file($standby->logfile, $logstart);
unlike(
	$log,
	qr/does not match the state/,
	'no spurious mismatch after crash-restart across an in-window transition'
);

is( $standby->safe_psql('postgres', "SELECT count(*) FROM t;"),
	'1000', 'standby readable after crash-restart');

# Release the trailing checkpoint and let the enable machinery finish.
$primary->wait_for_event('checkpointer', 'create-checkpoint-before-guts');
$primary->safe_psql('postgres',
	q{SELECT injection_points_wakeup('create-checkpoint-before-guts')});
$primary->safe_psql('postgres',
	q{SELECT injection_points_detach('create-checkpoint-before-guts')});

$standby->stop;
$primary->stop;
done_testing();
