# Test that PGC_HBA variables can only be set from appropriate sources
#
# PGC_HBA variables should be settable from:
# - postgresql.conf
# - postgresql.auto.conf (ALTER SYSTEM)
# - pg_hba.conf
#
# But NOT from:
# - ALTER USER SET
# - ALTER DATABASE SET
# - Connection parameters (PGOPTIONS)

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Test 1: PGC_HBA variable CAN be set in postgresql.conf
{
	my $node = PostgreSQL::Test::Cluster->new('conf_allowed');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	$node->append_conf('postgresql.conf',
		"test_hba_guc.string_var = 'from_postgresql_conf'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	my $result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'from_postgresql_conf',
		'PGC_HBA variable can be set in postgresql.conf');

	$result = $node->safe_psql('postgres',
		"SELECT source FROM pg_settings WHERE name = 'test_hba_guc.string_var';");
	is($result, 'configuration file',
		'Source shows configuration file for postgresql.conf setting');

	$node->stop;
}

# Test 2: PGC_HBA variable CAN be set via ALTER SYSTEM (postgresql.auto.conf)
{
	my $node = PostgreSQL::Test::Cluster->new('alter_system_allowed');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	$node->safe_psql('postgres',
		"ALTER SYSTEM SET test_hba_guc.string_var = 'from_alter_system';");

	$node->reload;

	my $result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'from_alter_system',
		'PGC_HBA variable can be set via ALTER SYSTEM');

	$result = $node->safe_psql('postgres',
		"SELECT source FROM pg_settings WHERE name = 'test_hba_guc.string_var';");
	is($result, 'configuration file',
		'Source shows configuration file for ALTER SYSTEM setting');

	$node->stop;
}

# Test 3: PGC_HBA variable CANNOT be set via ALTER USER SET
{
	my $node = PostgreSQL::Test::Cluster->new('alter_user_rejected');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	$node->safe_psql('postgres', "CREATE USER testuser;");

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"ALTER USER testuser SET test_hba_guc.string_var = 'from_alter_user';");
	isnt($ret, 0, 'ALTER USER SET rejected for PGC_HBA variable');
	like($stderr, qr/cannot be set by ALTER USER or ALTER DATABASE/,
		'Error message indicates ALTER USER is not allowed for PGC_HBA');

	$node->stop;
}

# Test 4: PGC_HBA variable CANNOT be set via ALTER DATABASE SET
{
	my $node = PostgreSQL::Test::Cluster->new('alter_database_rejected');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"ALTER DATABASE postgres SET test_hba_guc.string_var = 'from_alter_database';");
	isnt($ret, 0, 'ALTER DATABASE SET rejected for PGC_HBA variable');
	like($stderr, qr/cannot be set by ALTER USER or ALTER DATABASE/,
		'Error message indicates ALTER DATABASE is not allowed for PGC_HBA');

	$node->stop;
}

# Test 5: PGC_HBA variable CANNOT be set via connection parameter (PGOPTIONS)
{
	my $node = PostgreSQL::Test::Cluster->new('pgoptions_rejected');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	# Connection succeeds but parameter is not set (gets default value)
	local $ENV{PGOPTIONS} = '-c test_hba_guc.string_var=from_pgoptions';
	my $result = $node->safe_psql('postgres',
		"SELECT current_setting('test_hba_guc.string_var');");
	is($result, 'default_value',
		'PGC_HBA variable from PGOPTIONS is not set, uses default value');

	my $logfile = $node->logfile;
	my $log_content = slurp_file($logfile);
	like($log_content, qr/parameter "test_hba_guc\.string_var" cannot be changed now/,
		'Warning logged when trying to set PGC_HBA via PGOPTIONS');

	$node->stop;
}

# Test 6: PGC_HBA variable CANNOT be set via SET command
{
	my $node = PostgreSQL::Test::Cluster->new('set_rejected');
	$node->init;

	$node->append_conf('postgresql.conf',
		"session_preload_libraries = 'test_hba_guc'");

	my $hba_conf = $node->data_dir . '/pg_hba.conf';
	open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
	print $hba_fh "local all all trust\n";
	close $hba_fh;

	$node->start;

	my ($ret, $stdout, $stderr) = $node->psql('postgres',
		"SET test_hba_guc.string_var = 'from_set';");
	isnt($ret, 0, 'SET command rejected for PGC_HBA variable');
	like($stderr, qr/cannot be changed|cannot be set/,
		'Error message indicates SET is not allowed for PGC_HBA');

	$node->stop;
}

done_testing();
