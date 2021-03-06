#!/usr/bin/perl

use Modern::Perl;

use File::Basename;
use File::Slurp;
use Getopt::Compact;
use String::Util qw/trim/;
use Time::HiRes qw/time/;

my $script_path = dirname(__FILE__);

my $options = Getopt::Compact->new(
	name => 'checker if the output of aig2qbf is ok',
	struct => [
		[ 'input', 'Input aig/cnf file to check', '=s' ],
		[ 'k', 'Unrolling step k', ':i' ],
		[ 'no-reduction', 'Do not apply any reduction' ],
		[ 'verbose', 'Verbose output' ],
		[ 'with-sanity', 'Apply sanity checks.' ],
	]
);

my $opts = $options->opts();

sub options_validate {
	if (not $opts->{input}) {
		return;
	}

	if ($opts->{k} and $opts =~ m/^\d+$/) {
		return;
	}

	return 1;
}

if (not $options->status() or not options_validate()) {
	say $options->usage();

	exit 7;
}

my $file = $opts->{input};

if ($file =~ m/\.cnf$/) {
	my $cnf2aig_out = `"$script_path/../tools/cnf2aig" "$file" "$file-aig.aig"`;

	if ($opts->{verbose}) {
		say $cnf2aig_out;
	}

	$file = "$file-aig.aig";
}

my @ks = ($opts->{k}) ? ($opts->{k}) : (1..10);

my $build_file = "$script_path/../build/classes/at/jku/aig2qbf/aig2qbf.class";

if (not -f $build_file) {
	print `make -C "$script_path/../" 2>&1`;

	if (not -f $build_file) {
		print "Cannot find aig2qbf class. aig2qbf not built into folder 'build'!\n";

		exit 5;
	}
}

if ($opts->{verbose}) {
	$|++;
}

my %ignore_files = (
	'd392065d0606079baa34d135fd01953e' => 'empty aig',
);

my $file_md5_sum = trim(`md5sum "$file" 2>&1`);
$file_md5_sum =~ s/^(.+?)\s.+$/$1/sg;

while (my ($sum, $msg) = each %ignore_files) {
	if ($file_md5_sum eq $sum) {
		print "IGNORE FILE $msg\n";

		exit 6;
	}
}

my $aig2qbf_options = '';

if ($opts->{'no-reduction'}) {
	$aig2qbf_options .= ' --no-reduction';
}
if ($opts->{'verbose'}) {
	$aig2qbf_options .= ' --verbose';
}
if ($opts->{'with-sanity'}) {
	$aig2qbf_options .= ' --with-sanity';
}

my $mcaiger_options = '-r';

if ($opts->{'no-reduction'}) {
	$mcaiger_options = '-b';
}

for my $k (@ks) {
	if ($opts->{verbose}) {
		print "Check k=$k\n";
	}

	time_start();
	my $out = `java -cp "$script_path/../build/classes/:$script_path/../lib/commons-cli-1.2.jar" at.jku.aig2qbf.aig2qbf -k $k --input "$file" $aig2qbf_options`;
	time_end();
	print_elapsed_time('aig2qbf');

	if ($out =~ m/Exception in thread/) {
		print "aig2qbf load error on k=$k\n";
		print "\n$out\n";

		exit 1;
	}

	write_file("$file-$k.qbf", $out);

	time_start();
	my $depqbf_out = trim(`"$script_path/../tools/depqbf" "$file-$k.qbf" 2>&1`);
	time_end();
	print_elapsed_time('depqbf');

	my $depqbf_sat;

	if ($depqbf_out and $depqbf_out eq 'SAT') {
		$depqbf_sat = 1;
	}
	elsif ($depqbf_out and $depqbf_out eq 'UNSAT') {
		$depqbf_sat = 0;
	}
	else {
		print "depqbf solve error on k=$k\n";
		print "\n$depqbf_out\n";

		exit 2;
	}

	if ($opts->{verbose}) {
		print "depqbf says " . ($depqbf_sat ? 'SAT' : 'UNSAT') . "\n";
	}

	print `"$script_path/../tools/aigor" "$file" "$file-or.aig"`;

	time_start();
	my $mcaiger_out = trim(`"$script_path/../tools/mcaiger" $mcaiger_options $k "$file-or.aig" 2>&1`);
	time_end();
	print_elapsed_time('mcaiger');

	my $mcaiger_sat;

	if ($mcaiger_out eq '1') {
		$mcaiger_sat = 1;
	}
	elsif ($mcaiger_out eq '0') {
		$mcaiger_sat = 0;
	}
	elsif ($mcaiger_out eq '2') {
		$mcaiger_sat = 0;

		#print "mcaiger's output is 2\n";

		#exit 8;
	}
	else {
		print "mcaiger solve error on k=$k\n";
		print "\n$mcaiger_out\n";

		exit 3;
	}

	if ($opts->{verbose}) {
		print "mcaiger says " . ($mcaiger_sat ? 'SAT' : 'UNSAT') . "\n";
	}

	if ($depqbf_sat != $mcaiger_sat) {
		print "depqbf and mcaiger are divided over the satisfiability, error on k=$k\n";
		print "depqbf says " . ($depqbf_sat ? 'SAT' : 'UNSAT') . "\n";
		print "mcaiger says " . ($mcaiger_sat ? 'SAT' : 'UNSAT') . "\n";

		exit 4;
	}

	if ($opts->{verbose}) {
		print "AGREED\n";
	}
}

print "Check OK\n";

exit 0;

my ($time_start, $time_end);
sub time_start { $time_start = time; }
sub time_end { $time_end = time; }
sub print_elapsed_time {
	my ($text) = @_;

	$text ||= '';

	if ($opts->{verbose}) {
		printf("%s (%d ms)\n", $text, ($time_end - $time_start) * 1000.0);
	}
}
