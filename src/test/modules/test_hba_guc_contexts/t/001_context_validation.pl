# Test that only PGC_HBA variables can be set from pg_hba.conf

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

# Test 1: PGC_POSTMASTER variable should NOT be settable from pg_hba.conf
test_hba_rejected('postmaster_rejected', 'postmaster_var',
	'Connection rejected when trying to set PGC_POSTMASTER from pg_hba.conf');

# Test 2: PGC_SIGHUP variable should NOT be settable from pg_hba.conf
test_hba_rejected('sighup_rejected', 'sighup_var',
	'Connection rejected when trying to set PGC_SIGHUP from pg_hba.conf');

# Test 3: PGC_BACKEND variable should NOT be settable from pg_hba.conf
test_hba_rejected('backend_rejected', 'backend_var',
	'Connection rejected when trying to set PGC_BACKEND from pg_hba.conf');

# Test 4: PGC_SUSET variable should NOT be settable from pg_hba.conf
test_hba_rejected('suset_rejected', 'suset_var',
	'Connection rejected when trying to set PGC_SUSET from pg_hba.conf');

# Test 5: PGC_USERSET variable should NOT be settable from pg_hba.conf
test_hba_rejected('userset_rejected', 'userset_var',
	'Connection rejected when trying to set PGC_USERSET from pg_hba.conf');

done_testing();
