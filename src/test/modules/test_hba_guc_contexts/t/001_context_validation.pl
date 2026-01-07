# Test that only variables with context PGC_HBA or below can be set from pg_hba.conf

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

sub test_hba_rejected
{
	my ($node_name, $var_name, $test_desc) = @_;

	my $node = PostgreSQL::Test::Cluster->new($node_name);
	$node->init;

	$node->append_conf('postgresql.conf',
		"shared_preload_libraries = 'test_hba_guc_contexts'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust test_hba_guc_contexts.$var_name=from_hba\n";
	close $hba_fh;

	$node->start;

	my ($ret, $stdout, $stderr) = $node->psql('postgres', 'SELECT 1;');
	isnt($ret, 0, $test_desc);
	like($stderr, qr/cannot be changed|cannot be set/,
		'Error message indicates variable cannot be set from pg_hba.conf');

	$node->stop;
	return;
}

sub test_hba_accepted
{
	my ($node_name, $var_name, $test_desc) = @_;

	my $node = PostgreSQL::Test::Cluster->new($node_name);
	$node->init;

	$node->append_conf('postgresql.conf',
		"shared_preload_libraries = 'test_hba_guc_contexts'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust test_hba_guc_contexts.$var_name=from_hba\n";
	close $hba_fh;

	$node->start;

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"SHOW test_hba_guc_contexts.$var_name;");
	is($ret, 0, $test_desc);
	like($stdout, qr/from_hba/, 'Variable was set to value from pg_hba.conf');

	$node->stop;
	return;
}

# Test 1: PGC_POSTMASTER variable should NOT be settable from pg_hba.conf
test_hba_rejected('postmaster_rejected', 'postmaster_var',
	'Connection rejected when trying to set PGC_POSTMASTER from pg_hba.conf');

# Test 2: PGC_SIGHUP variable should NOT be settable from pg_hba.conf
test_hba_rejected('sighup_rejected', 'sighup_var',
	'Connection rejected when trying to set PGC_SIGHUP from pg_hba.conf');

# Test 3: PGC_SU_BACKEND variable SHOULD be settable from pg_hba.conf
test_hba_accepted('su_backend_accepted', 'su_backend_var',
	'Connection accepted when setting PGC_SU_BACKEND from pg_hba.conf');

# Test 4: PGC_BACKEND variable SHOULD be settable from pg_hba.conf
test_hba_accepted('backend_accepted', 'backend_var',
	'Connection accepted when setting PGC_BACKEND from pg_hba.conf');

# Test 5: PGC_SUSET variable SHOULD be settable from pg_hba.conf
test_hba_accepted('suset_accepted', 'suset_var',
	'Connection accepted when setting PGC_SUSET from pg_hba.conf');

# Test 6: PGC_USERSET variable SHOULD be settable from pg_hba.conf
test_hba_accepted('userset_accepted', 'userset_var',
	'Connection accepted when setting PGC_USERSET from pg_hba.conf');

done_testing();
