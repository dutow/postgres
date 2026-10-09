# A TCP proxy that closes the client connection GRACEFULLY in the middle of a
# server message.
#
# This isolates the one thing that matters for a8458f508a7: the client is left
# holding an incomplete protocol message, needs more bytes, and goes back to
# WaitLatchOrSocket() -- having already had its one-shot FD_CLOSE consumed by
# the wakeup that delivered those bytes.
#
# Usage: cutproxy.pl <listen_port> <target_port> <cutoff_bytes> [logfile]
#
# Forwards client->server in full.  Forwards at most <cutoff_bytes> of
# server->client, then does shutdown(SD_SEND) + close on the client socket.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

my ($lport, $tport, $cutoff, $logfile) = @ARGV;
$cutoff = 24 unless defined $cutoff;

open(my $log, '>>', $logfile) if defined $logfile;
sub logmsg { return unless $log; print $log "@_\n"; $log->flush; }

my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => $lport,
	Proto => 'tcp', Listen => 16, ReuseAddr => 1)
  or die "listen on $lport failed: $!";

logmsg("cutproxy listening on $lport -> $tport, cutoff=$cutoff");

my $n = 0;
while (my $client = $listen->accept())
{
	$n++;
	my $server = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1', PeerPort => $tport, Proto => 'tcp');
	if (!$server) { close $client; next; }

	$client->blocking(0);
	$server->blocking(0);
	my $sel = IO::Select->new($client, $server);
	my $from_server = 0;
	my $done = 0;

	while (!$done)
	{
		my @ready = $sel->can_read(5);
		last unless @ready;
		for my $fh (@ready)
		{
			my $buf;
			my $r = sysread($fh, $buf, 16384);
			if (!defined $r || $r == 0) { $done = 1; last; }

			if ($fh == $client)
			{
				syswrite($server, $buf);
			}
			else
			{
				my $room = $cutoff - $from_server;
				if ($room <= 0)
				{
					$done = 1;
					last;
				}
				my $send = length($buf) > $room ? substr($buf, 0, $room) : $buf;
				syswrite($client, $send);
				$from_server += length($send);
				if ($from_server >= $cutoff)
				{
					# graceful close, mid-message
					shutdown($client, 1);
					close($client);
					$client = undef;
					$done = 1;
					logmsg("conn $n: cut after $from_server bytes from server");
					last;
				}
			}
		}
	}

	close($client) if defined $client;
	close($server);
}
