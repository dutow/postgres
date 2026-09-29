# Check that a canceled or terminated waiter does not leave a stale slot
# behind in the waiter array. A leaked slot would make later wakeups of
# the same injection point bump the leaked slot's counter instead of the
# real waiter's, leaving the real waiter stuck.

setup
{
	CREATE EXTENSION injection_points;
}
teardown
{
	DROP EXTENSION injection_points;
}

# The first waiter, that gets canceled or terminated.  This does not
# use injection_points_set_local() on purpose: the injection point
# must survive s1's termination so that s3 can still detach it.
session s1
setup	{
	SELECT injection_points_attach('injection-points-wait', 'wait');
}
step wait1	{ SELECT injection_points_run('injection-points-wait'); }

# The second waiter, that receives a wakeup.
session s2
step wait2	{ SELECT injection_points_run('injection-points-wait'); }
step noop2	{ }

# Control session.  The blocker annotations on cancel3/terminate3,
# together with noop3, make the tester wait until wait1 has fully
# completed before starting wait2.  Otherwise, wait2 could register a
# new waiter slot while s1 still owns the previous one.
session s3
step cancel3	{
	SELECT pg_cancel_backend(pid) FROM pg_stat_activity
	  WHERE wait_event = 'injection-points-wait';
}
# The pg_sleep() keeps isolationtester busy on s3's socket while s1's
# backend reports its FATAL and exits.  A backend does not close its
# socket; process exit does, and on Windows that is an abortive close
# whose RST makes the client's network stack discard anything it has
# received but not yet read.  Leaving s1's socket unread until the
# backend is gone therefore costs us the FATAL, and the step completes
# with a connection error instead -- see wait_cleanup_1.out.
#
# Without the sleep, which outcome we get depends on whether the tester
# happens to be looking at s1 at the right moment, so the alternative
# output is almost never exercised.  A sleep that turns out to be too
# short on some machine is harmless: the FATAL arrives in time and the
# normal output applies.
step terminate3	{
	SELECT pg_terminate_backend(pid) FROM pg_stat_activity
	  WHERE wait_event = 'injection-points-wait';
	SELECT pg_sleep(0.1);
}
step wakeup3	{ SELECT injection_points_wakeup('injection-points-wait'); }
step detach3	{ SELECT injection_points_detach('injection-points-wait'); }
step noop3	{ }

permutation wait1 cancel3(wait1) noop3 wait2 wakeup3 noop2 detach3

# The terminate permutation has to stay last: s1's connection is dead
# afterwards, and the tester never reconnects a session.
permutation wait1 terminate3(wait1) noop3 wait2 wakeup3 noop2 detach3
