#!/usr/bin/perl
use warnings;
use strict;

# The recorder and the archive, without a window - for cron, for a systemd
# unit, and for looking at what is there from a terminal.
#
#     perl webcam-record.pl              # record every enabled camera
#     perl webcam-record.pl preview      # live preview only, nothing kept
#     perl webcam-record.pl status       # what is running, what is on disk
#     perl webcam-record.pl devices      # every camera node that can be taped
#     perl webcam-record.pl janitor      # recycle the oldest once, then exit
#     perl webcam-record.pl scan         # bring the archive index up to date
#     perl webcam-record.pl search [last]        # e.g. search 1h, search 30m
#     perl webcam-record.pl clip FROM TO [cam] [format]
#
# The clip times are "YYYY-MM-DD HH:MM:SS", or "HH:MM" for today.

BEGIN {
    require File::Basename;
    require Cwd;
    unshift @INC, File::Basename::dirname(Cwd::abs_path(__FILE__));
}

use POSIX ();
use WebcamRecord ();
use WebcamArchive ();

my $action = lc(shift(@ARGV) || 'record');
my $settings = WebcamRecord::read_settings();
WebcamRecord::ensure_dirs($settings);

if ($action eq 'devices') {
    print "$_->{label}\n" for @{ WebcamRecord::list_devices() };
    exit 0;
}

if ($action eq 'janitor') {
    my ($removed, $freed) = WebcamRecord::free_space($settings, 1);
    printf "%d segment(s) recycled, %.1f GB freed, %.1f GB free now\n",
           $removed, $freed, WebcamRecord::free_gb($settings->{archive_dir});
    exit 0;
}

if ($action eq 'scan') {
    WebcamArchive::scan(verbose => 1, reprobe => (($ARGV[0] || '') eq '--reprobe'));
    exit 0;
}

if ($action eq 'status') {
    my $info = WebcamArchive::stats();
    print "cameras   $settings->{cameras}\n";
    print "archive   $settings->{archive_dir}\n";
    printf "cap       %d GB (the loop recycles the oldest past this)\n",
           $settings->{max_archive_gb};
    printf "free      %.1f GB (floor %d GB)\n",
           WebcamRecord::free_gb($settings->{archive_dir}),
           $settings->{keep_free_gb};
    printf "index     %d segments, %.1f hours, %.2f GB across %d day(s)\n",
           $info->{segments}, $info->{hours}, $info->{gigabytes}, $info->{days};
    printf "          cam%d: %d segments\n", $_, $info->{cameras}{$_}
        for sort keys %{ $info->{cameras} };
    print "first     $info->{first}\nlast      $info->{last}\n"
        if $info->{first};
    exit 0;
}

if ($action eq 'search') {
    # "search 30m", "search 5h", "search 24h", or no argument for the last hour
    my $span = shift(@ARGV) || '1h';
    my %unit = (m => 60, h => 3600, d => 86400, s => 1);
    my ($count, $suffix) = $span =~ /^(\d+)\s*([mhds]?)$/;
    die "cannot read a span out of '$span' - try 30m, 5h or 24h\n"
        if !$count;
    my $seconds = $count * ($unit{ $suffix || 'h' } || 3600);
    my $rows = WebcamArchive::search(since => $seconds, limit => 20000);
    printf "cam%d  %s %s  %6.0fs  %7.0f MB  %s\n", $_->{camera}, $_->{day},
           $_->{clock}, $_->{duration}, $_->{size} / 1e6, $_->{name}
        for @$rows;
    printf "%d segment(s) in the last %s\n", scalar @$rows, $span;
    exit 0;
}

if ($action eq 'clip') {
    my ($from, $to, $camera, $format) = @ARGV;
    die "usage: webcam-record.pl clip FROM TO [camera] [format]\n"
        if !$from || !$to;
    my $out = WebcamArchive::clip(
        start    => WebcamArchive::parse_when($from),
        end      => WebcamArchive::parse_when($to),
        camera   => ($camera || 1),
        export   => ($format || 'mp4'),
        progress => sub { print "$_[0]\n" });
    printf "wrote %s  (%.0f MB)\n", $out, (-s $out) / 1e6;
    exit 0;
}

# ---- recording ----

my $record = ($action ne 'preview');
my $recorder = WebcamRecord->new(settings => $settings);
my @cameras = $recorder->cameras;
printf "%s %s @ %sfps from %d camera(s): %s\n",
       ($record ? 'recording' : 'preview only'),
       "$settings->{width}x$settings->{height}", $settings->{fps},
       scalar @cameras, join(', ', @cameras);
printf "segments into %s, looping at %d GB and keeping %d GB free\n",
       $settings->{archive_dir}, $settings->{max_archive_gb},
       $settings->{keep_free_gb} if $record;

$recorder->start($record);

# Stop on either signal rather than being killed outright: ffmpeg needs to be
# asked politely or the segment it is writing has no moov atom and will not
# play, and that is exactly what a systemd stop or a Ctrl-C would otherwise do.
my $running = 1;
$SIG{INT} = $SIG{TERM} = sub { $running = 0 };

while ($running) {
    sleep 1;
    $recorder->poll;
}
print "\nstopping\n";
$recorder->stop;
exit 0;
