#!/usr/bin/perl
#----------------------------------------------------------------------
#
# Generate wait events support files from wait_event_names.txt:
# - wait_event_types.h (if --code is passed)
# - pgstat_wait_event.c (if --code is passed)
# - wait_event_types.sgml (if --docs is passed)
#
# Portions Copyright (c) 1996-2023, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/backend/utils/activity/generate-wait_event_types.pl
#
#----------------------------------------------------------------------

use strict;
use warnings;
use Getopt::Long;

my $output_path = '.';
my $gen_docs = 0;
my $gen_code = 0;

my $continue = "\n";
my %hashwe;

GetOptions(
	'outdir:s' => \$output_path,
	'docs' => \$gen_docs,
	'code' => \$gen_code) || usage();

die "Needs to specify --docs or --code"
  if (!$gen_docs && !$gen_code);

die "Not possible to specify --docs and --code simultaneously"
  if ($gen_docs && $gen_code);

open my $wait_event_names, '<', $ARGV[0] or die;

my @lines;
my $section_name;
my $note;
my $note_name;

# Remove comments and empty lines and add waitclassname based on the section
while (<$wait_event_names>)
{
	chomp;

	# Skip comments
	next if /^#/;

	# Skip empty lines
	next if /^\s*$/;

	# Get waitclassname based on the section
	if (/^Section: ClassName(.*)/)
	{
		$section_name = $_;
		$section_name =~ s/^.*- //;
		next;
	}

	push(@lines, $section_name . "\t" . $_);
}

# Sort the lines based on the third column.
# uc() is being used to force the comparison to be case-insensitive.
my @lines_sorted =
  sort { uc((split(/\t/, $a))[2]) cmp uc((split(/\t/, $b))[2]) } @lines;

# Read the sorted lines and populate the hash table
foreach my $line (@lines_sorted)
{
	die "unable to parse wait_event_names.txt"
	  unless $line =~ /^(\w+)\t+(\w+)\t+("\w+")\t+("\w.*\.")$/;

	(   my $waitclassname,
		my $waiteventenumname,
		my $waiteventdescription,
		my $waitevendocsentence) = split(/\t/, $line);

	my @waiteventlist =
	  [ $waiteventenumname, $waiteventdescription, $waitevendocsentence ];
	my $trimmedwaiteventname = $waiteventenumname;
	$trimmedwaiteventname =~ s/^WAIT_EVENT_//;

	# An exception is required for LWLock and Lock as these don't require
	# any C and header files generated.
	die "wait event names must start with 'WAIT_EVENT_'"
	  if ( $trimmedwaiteventname eq $waiteventenumname
		&& $waiteventenumname !~ /^LWLock/
		&& $waiteventenumname !~ /^Lock/);
	$continue = ",\n";
	push(@{ $hashwe{$waitclassname} }, @waiteventlist);
}


# Generate the .c and .h files.
if ($gen_code)
{
	# Include PID in suffix in case parallel make runs this script
	# multiple times.
	my $htmp = "$output_path/wait_event_types.h.tmp$$";
	my $ctmp = "$output_path/pgstat_wait_event.c.tmp$$";
	open my $h, '>', $htmp or die "Could not open $htmp: $!";
	open my $c, '>', $ctmp or die "Could not open $ctmp: $!";

	my $header_comment =
	  '/*-------------------------------------------------------------------------
 *
 * %s
 *    Generated wait events infrastructure code
 *
 * Portions Copyright (c) 1996-2023, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * NOTES
 *  ******************************
 *  *** DO NOT EDIT THIS FILE! ***
 *  ******************************
 *
 *  It has been GENERATED by src/backend/utils/activity/generate-wait_event_types.pl
 *
 *-------------------------------------------------------------------------
 */

';

	printf $h $header_comment, 'wait_event_types.h';
	printf $h "#ifndef WAIT_EVENT_TYPES_H\n";
	printf $h "#define WAIT_EVENT_TYPES_H\n\n";
	printf $h "#include \"utils/wait_event.h\"\n\n";

	printf $c $header_comment, 'pgstat_wait_event.c';

	# uc() is being used to force the comparison to be case-insensitive.
	foreach my $waitclass (sort { uc($a) cmp uc($b) } keys %hashwe)
	{

		# Don't generate .c and .h files for LWLock and Lock, these are
		# handled independently.
		next
		  if ( $waitclass =~ /^WaitEventLWLock$/
			|| $waitclass =~ /^WaitEventLock$/);

		my $last = $waitclass;
		$last =~ s/^WaitEvent//;
		my $lastuc = uc $last;
		my $lastlc = lc $last;
		my $firstpass = 1;
		my $pg_wait_class;

		printf $c
		  "static const char *\npgstat_get_wait_$lastlc($waitclass w)\n{\n";
		printf $c "\tconst char *event_name = \"unknown wait event\";\n\n";
		printf $c "\tswitch (w)\n\t{\n";

		foreach my $wev (@{ $hashwe{$waitclass} })
		{
			if ($firstpass)
			{
				printf $h "typedef enum\n{\n";
				$pg_wait_class = "PG_WAIT_" . $lastuc;
				printf $h "\t%s = %s", $wev->[0], $pg_wait_class;
				$continue = ",\n";
			}
			else
			{
				printf $h "%s\t%s", $continue, $wev->[0];
				$continue = ",\n";
			}
			$firstpass = 0;

			printf $c "\t\t case %s:\n", $wev->[0];
			printf $c "\t\t\t event_name = %s;\n\t\t\t break;\n", $wev->[1];
		}

		printf $h "\n} $waitclass;\n\n";

		printf $c
		  "\t\t\t /* no default case, so that compiler will warn */\n";
		printf $c "\t}\n\n";
		printf $c "\treturn event_name;\n";
		printf $c "}\n\n";
	}

	printf $h "#endif                          /* WAIT_EVENT_TYPES_H */";
	close $h;
	close $c;

	rename($htmp, "$output_path/wait_event_types.h")
	  || die "rename: $htmp to $output_path/wait_event_types.h: $!";
	rename($ctmp, "$output_path/pgstat_wait_event.c")
	  || die "rename: $ctmp to $output_path/pgstat_wait_event.c: $!";
}
# Generate the .sgml file.
elsif ($gen_docs)
{
	# Include PID in suffix in case parallel make runs this multiple times.
	my $stmp = "$output_path/wait_event_names.s.tmp$$";
	open my $s, '>', $stmp or die "Could not open $stmp: $!";

	# uc() is being used to force the comparison to be case-insensitive.
	foreach my $waitclass (sort { uc($a) cmp uc($b) } keys %hashwe)
	{
		my $last = $waitclass;
		$last =~ s/^WaitEvent//;
		my $lastlc = lc $last;

		printf $s "  <table id=\"wait-event-%s-table\">\n", $lastlc;
		printf $s
		  "   <title>Wait Events of Type <literal>%s</literal></title>\n",
		  ucfirst($lastlc);
		printf $s "   <tgroup cols=\"2\">\n";
		printf $s "    <thead>\n";
		printf $s "     <row>\n";
		printf $s
		  "      <entry><literal>$last</literal> Wait Event</entry>\n";
		printf $s "      <entry>Description</entry>\n";
		printf $s "     </row>\n";
		printf $s "    </thead>\n\n";
		printf $s "    <tbody>\n";

		foreach my $wev (@{ $hashwe{$waitclass} })
		{
			printf $s "     <row>\n";
			printf $s "      <entry><literal>%s</literal></entry>\n",
			  substr $wev->[1], 1, -1;
			printf $s "      <entry>%s</entry>\n", substr $wev->[2], 1, -1;
			printf $s "     </row>\n";
		}

		printf $s "    </tbody>\n";
		printf $s "   </tgroup>\n";
		printf $s "  </table>\n\n";
	}

	close $s;

	rename($stmp, "$output_path/wait_event_types.sgml")
	  || die "rename: $stmp to $output_path/wait_event_types.sgml: $!";
}

close $wait_event_names;

sub usage
{
	die <<EOM;
Usage: perl  [--output <path>] [--code ] [ --sgml ] input_file

Options:
    --outdir         Output directory (default '.')
    --code           Generate wait_event_types.h and pgstat_wait_event.c.
    --sgml           Generate wait_event_types.sgml.

generate-wait_event_types.pl generates the SGML documentation and code
related to wait events.  This should use wait_event_names.txt in input, or
an input file with a compatible format.

Report bugs to <pgsql-bugs\@lists.postgresql.org>.
EOM
}