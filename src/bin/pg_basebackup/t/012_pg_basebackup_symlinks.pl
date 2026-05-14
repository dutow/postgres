# Copyright (c) 2021-2025, PostgreSQL Global Development Group

# Verify that pg_basebackup refuses to back up a cluster whose pg_tblspc/
# directory contains symbolic links that are not real tablespaces.
#
# The server's sendDir() emits a tar symlink record for *every* symlink
# directly under ./pg_tblspc, regardless of the entry's name. The
# OID-name filter in do_pg_backup_start() is unrelated; it only governs
# which entries are advertised in the BASE_BACKUP header and which get
# their own tablespace archive. So an attacker who can plant files
# under pg_tblspc -- e.g. with a name that isn't a tablespace OID --
# can place an arbitrary symlink there and have pg_basebackup faithfully
# reproduce it on the backup machine, pointing wherever the attacker
# chose. Subsequent writes through that symlink would land outside the
# new data directory.
#
# Each case checks two outcomes that are NOT true without the
# receiver-side allow-list check: pg_basebackup must exit non-zero, and
# the partial backup it cleans up must not contain a reproduced copy of
# the attacker's symlink.

use strict;
use warnings FATAL => 'all';
use File::Path qw(rmtree);
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $sys_tempdir = PostgreSQL::Test::Utils::tempdir_short;

my @pg_basebackup_defs =
  ('pg_basebackup', '--no-sync', '--checkpoint' => 'fast');

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init(allows_streaming => 1);
$node->start;

my $pgdata = $node->data_dir;

# Plant a $linkname symlink inside the live node's pg_tblspc that points
# at $target, run pg_basebackup -F p against it, and verify the backup
# fails. Removes the planted link before returning so the next case
# starts from a clean cluster. pg_basebackup walks pg_tblspc live at
# backup-start time, so no server restart is needed for the planted
# link to be visible.
sub expect_backup_failure
{
	my ($linkname, $target, $desc) = @_;

	my $link = "$pgdata/pg_tblspc/$linkname";
	symlink($target, $link)
	  or die "symlink($target, $link): $!";

	my $bdir = "$sys_tempdir/bk_$linkname";
	$node->command_fails(
		[ @pg_basebackup_defs, '--pgdata' => $bdir ],
		$desc);

	ok(!-e "$bdir/pg_tblspc/$linkname",
		"$desc: planted symlink not reproduced in backup target");

	unlink $link or die "unlink($link): $!";
	rmtree($bdir) if -e $bdir;
}

# Case 1: pg_tblspc/foo_link points at a regular file outside the data
# directory.
{
	my $f = "$sys_tempdir/foo_target";
	PostgreSQL::Test::Utils::append_to_file($f, "x\n");

	expect_backup_failure(
		'foo_link', $f,
		'pg_basebackup refuses pg_tblspc symlink to a regular file');
}

# Case 2: pg_tblspc/dir_link points at an arbitrary existing directory
# outside the data directory.
{
	my $d = "$sys_tempdir/dir_target";
	mkdir($d) or die "mkdir($d): $!";

	expect_backup_failure(
		'dir_link', $d,
		'pg_basebackup refuses pg_tblspc symlink to an external directory');
}

done_testing();
