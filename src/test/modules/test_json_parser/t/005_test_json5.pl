
# Copyright (c) 2021-2026, PostgreSQL Global Development Group

# Test JSON5 support in the standalone (recursive descent) JSON parser.
# Each feature fixture must be accepted in --json5 mode with the
# expected semantic output, and rejected without --json5.  The
# incremental parser does not support JSON5.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Utils;
use Test::More;
use FindBin;
use File::Temp qw(tempfile);

my $dir = PostgreSQL::Test::Utils::tempdir;

my @exes = (
	[ "test_json_parser_standalone", ],
	[ "test_json_parser_standalone", "-o", ],
	[ "test_json_parser_standalone_shlib", ],
	[ "test_json_parser_standalone_shlib", "-o", ]);

# One entry per feature: fixture basename plus, where the failing token
# is predictable, a regex for the error reported without --json5.
my @features = (
	{
		name => 'comments',
		file => 'json5_comments',
		error => qr/Token "\/" is invalid/,
	},
	{ name => 'trailing commas', file => 'json5_trailing_commas' },
	{ name => 'unquoted keys', file => 'json5_keys' },
	{ name => 'single-quoted strings', file => 'json5_strings' },
	{ name => 'multi-line strings', file => 'json5_multiline' },
	{ name => 'numbers', file => 'json5_numbers' },);

# Inputs that stay invalid even in json5 mode.
my @json5_invalid = (
	[ 'doubled trailing comma', '[1,,]' ],
	[ 'doubled trailing comma in object', '{"a":1,,}' ],
	[ 'digit-led key', '{ 1a: 1 }' ],
	[ 'identifier value in object', '{ a: b }' ],
	[ 'identifier value in array', '[a]' ],
	[ 'bare identifier', 'undefined' ],
	[ 'dollar after number', '2$' ],
	[ 'dollar after number in array', '[25$]' ],
	[ 'digit as first key', '{1: 1}' ],
	[ 'bare 0x', '0x' ],
	[ 'bare dot', '.' ],
	[ 'missing value', '{"a":}' ],
	[ 'missing colon and value', '{"a"}' ],
	[ 'missing value after unquoted key', '{a:}' ],
	[ 'reserved word key without value', '{true}' ],
	[ 'missing colon and value after second key', '{"a":1,"b"}' ],
	[ 'unterminated block comment after value', '1 /*' ],
	[ 'unterminated block comment in array', '[1 /*' ],
	[ 'unterminated block comment with content', '1 /*/ 2' ],
	[ 'garbage after cr-terminated line comment', "1 // c\rx" ],
	[ 'signed infinity key', '{-Infinity: 1}' ],
	[ 'signed infinity with trailing junk', '-Infinityz' ],
	[ 'signed infinity with trailing dollar', '-Infinity$' ],
	[ 'signed nan with trailing junk', '+NaN5' ],);

# Valid json5 corner cases not covered by the feature fixtures.
my @json5_misc_valid = (
	[ 'reserved word as first key', '{true: 1, a: 2}' ],
	[ 'block comment containing /*-like text', '/*/ */ 1' ],
	[ 'dollar inside unquoted key', '{ab$c: 1}' ],
	[ 'Infinity as unquoted key', '{Infinity: 1}' ],
	[ 'NaN as unquoted key', '{NaN: 1}' ],
	[ 'negative NaN', '-NaN' ],
	[ 'positive NaN', '+NaN' ],
	[ 'cr-terminated line comment', "[1, // c\r2\n]" ],);

# Number extensions, each individually rejected without --json5.
my @json_invalid_numbers = (
	[ 'hex', '0x1F' ],
	[ 'leading dot', '.5' ],
	[ 'trailing dot', '5.' ],
	[ 'plus sign', '+42' ],
	[ 'infinity', 'Infinity' ],
	[ 'negative infinity', '-Infinity' ],
	[ 'positive infinity', '+Infinity' ],
	[ 'nan', 'NaN' ],);

# Write $content to a temp file and return the file name.
sub inline_file
{
	my ($content) = @_;
	my ($fh, $fname) = tempfile(DIR => $dir);
	print $fh $content;
	close($fh);
	return $fname;
}

# Parse $file with --json5 and compare the semantic output against
# $expected.
sub check_accepted
{
	my ($exe, $file, $expected, $label) = @_;

	my ($stdout, $stderr) = run_command([ @$exe, "-s", "--json5", $file ]);

	is($stderr, "", "$label: no error output");

	my ($fh, $fname) = tempfile(DIR => $dir);
	print $fh $stdout, "\n";
	close($fh);

	my @diffopts = ("-u");
	push(@diffopts, "--strip-trailing-cr") if $windows_os;
	($stdout, $stderr) =
	  run_command([ "diff", @diffopts, $fname, $expected ]);

	is($stdout, "", "$label: no output diff");
	is($stderr, "", "$label: no diff error");
}

# Check that parsing $file fails, matching $error on stderr if given.
sub check_rejected
{
	my ($exe, $file, $label, $error, @flags) = @_;

	my ($stdout, $stderr) = run_command([ @$exe, "-s", @flags, $file ]);

	unlike($stdout, qr/SUCCESS/, "$label: parsing fails");
	if (defined $error)
	{
		like($stderr, $error, "$label: correct error output");
	}
	else
	{
		isnt($stderr, "", "$label: error output");
	}
}

foreach my $exe (@exes)
{
	note "testing executable @$exe";

	foreach my $f (@features)
	{
		my $file = "$FindBin::RealBin/../$f->{file}.json5";
		my $expected = "$FindBin::RealBin/../$f->{file}.out";

		check_accepted($exe, $file, $expected, "json5 $f->{name}");
		check_rejected($exe, $file, "non-json5 mode: $f->{name}",
			$f->{error});
	}

	foreach my $inv (@json5_invalid)
	{
		my ($label, $content) = @$inv;
		my $fname = inline_file($content);

		check_rejected($exe, $fname, "json5 mode: $label", undef, "--json5");
	}

	foreach my $v (@json5_misc_valid)
	{
		my ($label, $content) = @$v;
		my $fname = inline_file($content);

		my ($stdout, $stderr) = run_command([ @$exe, "--json5", $fname ]);

		like($stdout, qr/SUCCESS/, "json5 mode: $label: parse succeeds");
		is($stderr, "", "json5 mode: $label: no error output");
	}

	foreach my $inv (@json_invalid_numbers)
	{
		my ($label, $content) = @$inv;

		check_rejected($exe, inline_file($content),
			"non-json5 mode: $label form");
	}

	# Multi-line string continuations are also handled on the "not
	# de-escaping" path (no -s flag).
	my $ml_file = "$FindBin::RealBin/../json5_multiline.json5";
	my ($ml_out, $ml_err) = run_command([ @$exe, "--json5", $ml_file ]);

	like($ml_out, qr/SUCCESS/,
		"json5 multi-line strings, no de-escaping: parse succeeds");
	is($ml_err, "",
		"json5 multi-line strings, no de-escaping: no error output");

	# A backslash-newline continuation in a quoted key's value exercises
	# the gate directly: a quoted key rules out the unrelated
	# unquoted-key rejection reached via the fixture file.
	my $cont_file = inline_file("{ \"a\": \"line \\\nb\" }");
	my ($cont_out, $cont_err) =
	  run_command([ @$exe, "-s", "--json5", $cont_file ]);

	is($cont_out, "{\n\"a\": \"line b\"\n}",
		"json5 mode: backslash-newline continuation accepted");
	is($cont_err, "",
		"json5 mode: backslash-newline continuation no error");

	check_rejected($exe, $cont_file,
		"non-json5 mode: backslash-newline continuation",
		qr/Escape sequence.*is invalid/s);

	# Same continuation with a lone CR (no LF) as the line terminator.
	my $cr_file = inline_file("{ \"a\": \"line \\\rb\" }");
	my ($cr_out, $cr_err) =
	  run_command([ @$exe, "-s", "--json5", $cr_file ]);

	is($cr_out, "{\n\"a\": \"line b\"\n}",
		"json5 mode: backslash-cr continuation accepted");
	is($cr_err, "",
		"json5 mode: backslash-cr continuation no error");
}

done_testing();
