# Deterministic test of the walreceiver's connect path against a graceful close
# that lands in the middle of a server message.
#
# The standby's primary_conninfo points at cutproxy.pl instead of at the
# primary.  The proxy forwards the startup exchange and then, after a fixed
# number of server bytes, does shutdown(SD_SEND) + closesocket on the
# walreceiver's socket.  The walreceiver is therefore guaranteed to be holding
# an incomplete message and to go back into
#
#     libpqsrv_connect_params() -> WaitLatchOrSocket(..., io_flag, fd, 0, ...)
#
# which has no timeout, after its one-shot FD_CLOSE was consumed by the wakeup
# that delivered those bytes.  Without a8458f508a7 there is nothing left to
# wake it; with a8458f508a7 the pre-sleep MSG_PEEK sees the EOF.
#
# Signal: a walreceiver pid that stays alive far longer than one failed
# connection attempt should take.
#
# The hazard is per connection attempt (about 1.6% without the fix), so the
# test is budgeted in attempts rather than in time: it passes once
# WALRCV_ATTEMPTS attempts have completed without a stuck walreceiver.  The
# default of 300 attempts detects the unfixed code with about 99%
# probability.  WALRCV_SECS is only a safety ceiling; reaching it before the
# attempt budget means the test did not exercise the hazard, and is a failure.
#
# Environment knobs:
#   WALRCV_ATTEMPTS  attempt budget (default 300)
#   WALRCV_SECS      time ceiling in seconds (default 600)
#   WALRCV_STUCK     seconds a walreceiver pid must persist to count as stuck
#                    (default 20)
#   WALRCV_CUTOFF    server bytes forwarded before the proxy cuts (default 24)
use strict;
use warnings FATAL => 'all';
use File::Basename qw(dirname);
use File::Spec;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use IPC::Run ();

if (!$windows_os)
{
	plan skip_all =>
	  'the lost-FD_CLOSE hazard this test covers is Windows-only';
}

my $ATTEMPTS = $ENV{WALRCV_ATTEMPTS} // 300;
my $SECS = $ENV{WALRCV_SECS} // 600;
my $STUCK = $ENV{WALRCV_STUCK} // 20;
my $CUTOFF = $ENV{WALRCV_CUTOFF} // 24;

# cutproxy.pl lives one level up, outside t/, so that prove's t/*.pl glob does
# not try to run it as a test.
my $proxy_pl = File::Spec->catfile(dirname(__FILE__), File::Spec->updir(),
								   'cutproxy.pl');

my $primary = PostgreSQL::Test::Cluster->new('p');
$primary->init(allows_streaming => 1);
$primary->append_conf('postgresql.conf',
	"max_wal_senders = 10\nwal_sender_timeout = 0\nfsync = off\n");
$primary->start;
$primary->backup('bkp');

# pick a free port for the proxy
my $pport = $primary->port + 3000;

my $standby = PostgreSQL::Test::Cluster->new('s');
$standby->init_from_backup($primary, 'bkp', has_streaming => 1);
$standby->append_conf('postgresql.conf',
	"wal_receiver_timeout = 0\nwal_receiver_status_interval = 0\nfsync = off\n"
  . "wal_retrieve_retry_interval = 100ms\n"
  . "primary_conninfo = 'host=127.0.0.1 port=$pport'\n");

my $proxylog = $ENV{TESTLOGDIR} . "/cutproxy.log";
my $proxy = IPC::Run::start(
	[ $^X, $proxy_pl, $pport, $primary->port, $CUTOFF, $proxylog ]);

$standby->start;

my $start = time();
my $deadline = $start + $SECS;
my $prev = '';
my $prev_since = time();
my $incarnations = 0;
my $stuck_pid;

# Stop on a stuck walreceiver, on reaching the attempt budget, or on hitting
# the time ceiling.
while ($incarnations < $ATTEMPTS && time() < $deadline)
{
	my $cur = $standby->safe_psql('postgres',
		q{SELECT coalesce(string_agg(pid::text, ','), '')
		  FROM pg_stat_activity WHERE backend_type = 'walreceiver'});

	if ($cur ne $prev)
	{
		$incarnations++ if $cur ne '';
		$prev = $cur;
		$prev_since = time();
	}
	elsif ($cur ne '' && time() - $prev_since >= $STUCK)
	{
		$stuck_pid = $cur;
		last;
	}
	select(undef, undef, undef, 0.05);
}

my $elapsed = time() - $start;

if (defined $stuck_pid)
{
	diag("=== walreceiver pid(s) $stuck_pid alive >= ${STUCK}s ===");
	diag("wait_event: '"
		  . $standby->safe_psql('postgres',
			  q{SELECT coalesce(string_agg(pid::text||' '||coalesce(wait_event_type,'-')||'/'||coalesce(wait_event,'-'), ', '), '(none)')
			    FROM pg_stat_activity WHERE backend_type = 'walreceiver'}) . "'");
}

my $cuts = 0;
if (open(my $fh, '<', $proxylog)) { $cuts++ while <$fh>; close $fh; }
diag("proxy log lines: $cuts; walreceiver attempts: $incarnations of budget $ATTEMPTS in ${elapsed}s");

# Running out of time before running out of attempts proves nothing.
if (!defined $stuck_pid && $incarnations < $ATTEMPTS)
{
	eval { IPC::Run::kill_kill($proxy) };
	$standby->stop('immediate');
	$primary->stop('immediate');
	die "time ceiling of ${SECS}s reached after only $incarnations of $ATTEMPTS"
	  . " connection attempts; the test did not exercise the hazard";
}

ok(!defined $stuck_pid, "no walreceiver stuck after a mid-message graceful close");

eval { IPC::Run::kill_kill($proxy) };
$standby->stop('immediate');
$primary->stop('immediate');
done_testing();
