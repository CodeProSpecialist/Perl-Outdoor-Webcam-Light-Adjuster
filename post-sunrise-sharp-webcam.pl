#!/usr/bin/perl
use warnings;
use strict;

# Golden morning settings: low warm sun just after sunrise.
#
# The camera settings themselves now live in webcam-preset.pl, which reads the
# control list from whichever camera is plugged in and picks the matching
# values. The older webcam and the ONN webcam use different control names and
# different ranges, so one hard-coded set of numbers cannot serve both.
#
# This wrapper is kept so existing habits and the scheduler keep working:
#   ./post-sunrise-sharp-webcam.pl
# is the same as
#   ./webcam-preset.pl golden_am

my $preset = 'golden_am';
my $device = $ENV{WEBCAM_DEVICE} || '/dev/video0';

# Look for the engine next to this script, then in the home directory, then in
# the current directory, because these scripts get copied to ~ and run both ways.
my @dirs;
if ($0 =~ m{^(.*)/[^/]+$}) { push @dirs, $1; }
# $HOME is not set under some cron setups, so fall back to the password
# database, which answers for whichever user is actually running this.
my $home = $ENV{HOME};
$home = eval { (getpwuid($<))[7] } unless defined $home && length $home && -d $home;
push @dirs, (defined $home && length $home ? $home : '.'), '.';

for my $d (@dirs) {
    my $engine = "$d/webcam-preset.pl";
    next unless -r $engine;
    my $rc = system($^X, $engine, $preset, $device);
    exit($rc == 0 ? 0 : 1);
}

print STDERR "webcam-preset.pl not found next to $0, in \$HOME, or in the current directory.\n";
exit 1;
