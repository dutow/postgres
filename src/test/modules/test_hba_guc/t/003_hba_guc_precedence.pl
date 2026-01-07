# Test that PGC_HBA variables from pg_hba.conf respect line precedence
#
# pg_hba.conf is evaluated top-to-bottom, and the first matching line wins.
# This test verifies that GUC values are taken from the correct matching line.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Test 1: First matching line wins (same user, same database, same auth methods)
{
	my $node = PostgreSQL::Test::Cluster->new('first_match_wins');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust test_hba_guc.string_var=first_line\n";
	print $hba_fh "local all all trust test_hba_guc.string_var=second_line\n";
	print $hba_fh "local all all trust test_hba_guc.string_var=third_line\n";
	close $hba_fh;

	$node->start;

	my $result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'first_line',
		'First matching HBA line wins when multiple lines match');

	$node->stop;
}

# Test 2: Database-specific GUC values
{
	my $node = PostgreSQL::Test::Cluster->new('database_specific');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	# Create test databases
	$node->start;
	$node->safe_psql('postgres', 'CREATE DATABASE testdb1;');
	$node->safe_psql('postgres', 'CREATE DATABASE testdb2;');
	$node->stop;

	# Create pg_hba.conf with database-specific values
	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local testdb1 all trust test_hba_guc.string_var=from_testdb1\n";
	print $hba_fh "local testdb2 all trust test_hba_guc.string_var=from_testdb2\n";
	print $hba_fh "local all all trust test_hba_guc.string_var=from_wildcard\n";
	close $hba_fh;

	$node->start;

	my $result = $node->safe_psql('testdb1',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'from_testdb1',
		'Database-specific GUC value applied for testdb1');

	$result = $node->safe_psql('testdb2',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'from_testdb2',
		'Database-specific GUC value applied for testdb2');

	$result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'from_wildcard',
		'Wildcard GUC value applied for postgres database');

	$node->stop;
}

# Test 3: Empty/no GUC options on first match, GUC options on later line
# The first matching line wins even if it has no GUC options
{
	my $node = PostgreSQL::Test::Cluster->new('no_gucs_first');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	print $hba_fh "local all all trust test_hba_guc.string_var=not_used\n";
	close $hba_fh;

	$node->start;

	# Should get default value since first matching line has no GUC options
	my $result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'default_value',
		'Default GUC value when first matching line has no GUC options');

	$node->stop;
}

done_testing();
