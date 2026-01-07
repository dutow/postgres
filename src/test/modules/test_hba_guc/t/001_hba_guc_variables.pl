# Test PGC_HBA GUC variables in pg_hba.conf

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;

$node->append_conf('postgresql.conf',
	"session_preload_libraries = 'test_hba_guc'");

my $hba_conf = $node->data_dir . '/pg_hba.conf';
open my $hba_fh, '>', $hba_conf or die "Could not open $hba_conf: $!";
print $hba_fh "# Test HBA configuration with GUC variables\n";
print $hba_fh "local all all trust test_hba_guc.string_var=from_hba test_hba_guc.int_var=999\n";
close $hba_fh;

$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION test_hba_guc;');
my $result = $node->safe_psql('postgres',
	"SELECT current_setting('test_hba_guc.string_var'), current_setting('test_hba_guc.int_var');"
);
is($result, 'from_hba|999',
	'GUC variables set from pg_hba.conf are accessible');

$result = $node->safe_psql('postgres',
	"SELECT source FROM pg_settings WHERE name = 'test_hba_guc.string_var';"
);
is($result, 'pg_hba.conf',
	'GUC variable source shows pg_hba.conf');

my $node_no_ext = PostgreSQL::Test::Cluster->new('no_extension');
$node_no_ext->init;

my $hba_conf_no_ext = $node_no_ext->data_dir . '/pg_hba.conf';
open my $hba_no_ext_fh, '>', $hba_conf_no_ext or die "Could not open $hba_conf_no_ext: $!";
print $hba_no_ext_fh "# Test HBA configuration with undefined GUC variables\n";
print $hba_no_ext_fh "local all all trust test_hba_guc.undefined_var=value\n";
close $hba_no_ext_fh;

$node_no_ext->start;

my ($ret, $stdout, $stderr) = $node_no_ext->psql('postgres', 'SELECT 1;');
isnt($ret, 0, 'Connection rejected when HBA GUC variable is undefined');
like($stderr, qr/authentication configuration error/,
	'Error message indicates authentication configuration problem');
like($stderr, qr/undefined GUC variable/,
	'Error message mentions undefined GUC variable');

$node_no_ext->stop;
$node->stop;

done_testing();
