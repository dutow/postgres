
# Copyright (c) 2024-2026, PostgreSQL Global Development Group

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use FindBin;
use lib $FindBin::RealBin;

use SSL::Server;

my $SERVERHOSTADDR = '127.0.0.1';
my $SERVERHOSTCIDR = '127.0.0.1/32';

if ($ENV{with_ssl} ne 'openssl')
{
	plan skip_all => 'OpenSSL not supported by this build';
}

if (!$ENV{PG_TEST_EXTRA} || $ENV{PG_TEST_EXTRA} !~ /\bssl\b/)
{
	plan skip_all =>
	  'Potentially unsafe test SSL not enabled in PG_TEST_EXTRA';
}

my $ssl_server = SSL::Server->new();

if ($ssl_server->is_libressl)
{
	plan skip_all => 'SNI not supported when building with LibreSSL';
}

my $node = PostgreSQL::Test::Cluster->new('primary');
$node->init;

$ENV{PGHOST} = $node->host;
$ENV{PGPORT} = $node->port;
$node->start;

$ssl_server->configure_test_server_for_ssl($node, $SERVERHOSTADDR,
	$SERVERHOSTCIDR, 'trust');

$ssl_server->switch_server_cert($node, certfile => 'server-cn-only');

my $connstr =
  "user=ssltestuser dbname=trustdb hostaddr=$SERVERHOSTADDR sslsni=1";

##############################################################################
# pg_hosts.toml - happy path
##############################################################################

ok(unlink($node->data_dir . '/pg_hosts.conf'),
	'remove pg_hosts.conf so dispatch picks pg_hosts.toml');

my $datadir = $node->data_dir;
my $tomlpath = "$datadir/pg_hosts.toml";
open(my $fh, '>', $tomlpath)
  or die "open pg_hosts.toml for writing: $!";
print $fh <<'TOML';
[hosts]
"example.org" = { ssl_certificate = "server-cn-only+server_ca.crt", ssl_key = "server-cn-only.key", ssl_ca = "root_ca.crt" }
"*" = { ssl_certificate = "server-cn-only.crt", ssl_key = "server-cn-only.key" }
TOML
close($fh);

$node->append_conf('pg_hba.conf', "local all all trust");
$node->append_conf('postgresql.conf',
	"hosts_file = '$tomlpath'\n" . "ssl_sni = on\n");
$node->restart;

$node->connect_ok(
	"$connstr host=example.org sslrootcert=ssl/root_ca.crt sslmode=verify-ca",
	'pg_hosts.toml: connect to example.org and verify per-host CA');

$node->connect_ok(
	"$connstr sslrootcert=ssl/root+server_ca.crt sslmode=require",
	'pg_hosts.toml: connect to default host with sslmode=require');

##############################################################################
# pg_hosts.toml - broken file logs the TOML parse error on reload
##############################################################################

open($fh, '>', $tomlpath)
  or die "open pg_hosts.toml for rewriting: $!";
print $fh "[hosts\n";    # unterminated table header
close($fh);

my $log_offset = -s $node->logfile;
$node->reload;
$node->wait_for_log(qr/could not load "pg_hosts\.conf"/, $log_offset);
my $log = PostgreSQL::Test::Utils::slurp_file($node->logfile, $log_offset);
like(
	$log,
	qr/TOML parse error/,
	"pg_hosts.toml: malformed file produces 'TOML parse error' log entry");

$node->connect_ok(
	"$connstr host=example.org sslrootcert=ssl/root_ca.crt sslmode=verify-ca",
	'pg_hosts.toml: connection still works after malformed reload');

done_testing();
