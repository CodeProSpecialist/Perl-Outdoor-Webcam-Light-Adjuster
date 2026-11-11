#!/usr/bin/perl
use warnings;
use strict;
# First run: check the modules this script needs are installed, and offer to
# install the apt packages that provide them if they are not. Nothing is
# printed when they are all there, which is every run after the first.
#
# This has to happen in BEGIN, before the `use` lines below: `use` is a
# compile-time step, so by the time ordinary code could check anything the
# script has already died with "Can't locate ... in @INC". That error names
# @INC and never names the apt package, which is the whole problem.
#
# WebcamBootstrap.pm is looked for next to this file, then in $HOME, then in
# the working directory - the same order the scripts find each other - and if
# it is not in any of them this does nothing and the `use` lines fail as they
# always did. Set WEBCAM_NO_BOOTSTRAP=1 to skip the check.
BEGIN {
    require File::Basename;
    require Cwd;

    my @dirs = (
        File::Basename::dirname(Cwd::abs_path(__FILE__)),
        ($ENV{HOME} ? ($ENV{HOME}) : ()),
        '.',
    );

    for my $dir (@dirs) {
        next if !-r "$dir/WebcamBootstrap.pm";
        unshift @INC, $dir;
        require WebcamBootstrap;
        WebcamBootstrap::ensure(qw(Tk));
        last;
    }
}

use Tk;
use Cwd ();
use File::Basename ();

# A control window for whichever webcam is plugged in.
#
# This is the window version of what the scheduler does from the command line:
# the same presets, through the same engine (webcam-preset.pl), and the same
# automatic light adjustment. The scheduler can keep running while this is
# open; both only set controls, and they re-read each other's work rather than
# fighting over it.
#
# It builds itself from the camera. Every control on the window comes from
# `v4l2-ctl -L` at startup, with the range the camera reported - which is the
# only way one window can serve both the older webcam, whose controls run 0 to
# 255, and the current ones, where brightness runs -64 to 64. Nothing here has
# a control name or a range written into it that the camera did not confirm.
#
# It never opens the video stream. A V4L2 camera lets one program stream at a
# time and the recording software has it, so there is no preview here: judge
# the picture in whatever is recording it. Controls are a different thing from
# the stream - they are ioctls on the device node and can be set while another
# program is streaming, which is why any of this works at all.

my $device = $ENV{WEBCAM_DEVICE} || '/dev/video0';

# Where this user's home directory is.
#
# $HOME is right nearly always, but it is not set under some cron and systemd
# setups - so the password database is the fallback, and it answers for
# whichever user is actually running the program. Nothing here has a user name
# written into it.
sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME} && -d $ENV{HOME};
    my $pw = eval { (getpwuid($<))[7] };
    return $pw if defined $pw && length $pw && -d $pw;
    return '.';
}

# ---- What this particular camera can actually do ----
#
# Read once, before any widget is built. Lines from v4l2-ctl -L look like:
#   brightness 0x00980900 (int) : min=-64 max=64 step=1 default=0 value=0
my %cam;
my %cam_missing_warned;

sub read_camera_controls {
    my %found;
    for my $line (`v4l2-ctl -d $device -L 2>/dev/null`) {
        next unless $line =~ /^\s*(\w+)\s+0x[0-9a-f]+\s+\((int|bool|menu|intmenu)\)/i;
        my ($name, $type) = ($1, lc $2);
        my ($min) = $line =~ /min=(-?\d+)/;
        my ($max) = $line =~ /max=(-?\d+)/;
        my ($def) = $line =~ /default=(-?\d+)/;
        # Booleans report no min or max of their own.
        ($min, $max) = (0, 1) unless defined $min && defined $max;
        $found{$name} = { min => $min, max => $max, default => $def, type => $type };
    }
    return %found;
}

%cam = read_camera_controls();

# Set a control, clamped to the range the camera reported, skipping anything it
# does not have.
#
# Sending a value past the end of the range does not get clamped by the driver,
# it gets refused - and with the errors going to /dev/null it was refused
# silently. Hence the clamp.
sub apply_ctrl {
    my ($ctrl, $val) = @_;
    if (%cam && !$cam{$ctrl}) {
        unless ($cam_missing_warned{$ctrl}) {
            $cam_missing_warned{$ctrl} = 1;
            warn "$device has no $ctrl control - skipping it\n";
        }
        return;
    }
    if ($cam{$ctrl}) {
        my ($lo, $hi) = ($cam{$ctrl}{min}, $cam{$ctrl}{max});
        $val = $lo if $val < $lo;
        $val = $hi if $val > $hi;
    }
    system("v4l2-ctl -d $device --set-ctrl $ctrl=$val 2>/dev/null");
}

sub get_ctrl {
    my ($ctrl) = @_;
    my $out = `v4l2-ctl -d $device --get-ctrl $ctrl 2>/dev/null`;
    return ($out =~ /:\s*(-?\d+)/) ? $1 : undef;
}

# Run a preset through the engine, wherever it actually lives.
#
# Next to this script first, then the home directory, then the working
# directory, which is the same order the wrapper scripts use - these files get
# copied to ~ and run both ways. In a child process, with the same perl this
# window is running under, so the engine's own exit() cannot take the window
# down with it.
sub run_preset {
    my ($preset) = @_;
    my @dirs = (File::Basename::dirname(Cwd::abs_path($0)), home_dir(), Cwd::getcwd());
    for my $dir (@dirs) {
        my $engine = "$dir/webcam-preset.pl";
        next unless -r $engine;
        my $rc = system($^X, $engine, $preset, $device);
        return $rc == 0;
    }
    warn "webcam-preset.pl not found next to $0, in " . home_dir() . ", or in "
        . Cwd::getcwd() . "\n";
    return 0;
}

# ---- Automatic light adjustment (closed loop on the actual picture) ----
#
# This runs 24/7 alongside everything else. It does not replace the presets or
# the sunrise and sunset schedule: night, day, post-sunrise, pre-sunset, bright
# sun, cloudy, mono and the defaults all stay exactly as they are, and the
# clock still decides which of them is in force. What this adds is a
# correction on top of whichever one is active, so that the picture is neither
# too bright nor too dark whatever the light outside is actually doing - a
# cloudy afternoon, a security light coming on at 2am, snow glare at noon.
#
# It is a correction and not a replacement because a preset is more than light.
# The golden hour presets have their warm automatic white balance, bright sun
# has its cold white balance and tight focus. Something that imposed its own
# absolute numbers would flatten all of that into one look. So this measures
# the picture, works out "a bit brighter than this" or "a bit darker than
# this", and moves five light controls away from whatever the preset set them
# to, by a trim of -5 to +5 steps. The preset's character survives; only its
# exposure gets corrected.
#
# It re-learns its baseline on its own. Every pass it reads the five controls
# back off the camera, and if they are not what it last wrote then a preset
# fired, or a hand moved a slider, so that becomes the new baseline and the
# trim returns to zero. Nothing has to tell it a preset ran.
#
# The picture has to come from the external camera software, because a V4L2
# camera lets only one program stream from it and that software holds the
# device. Measuring a still it has already written is not the same as opening
# the camera. Set $snap_src below, or WEBCAM_SNAPSHOT in the environment, to:
#   * a directory - the newest .jpg in it is measured, which is what a "save
#     snapshots to folder" module in the camera software produces
#   * a single file - for software that overwrites the same still each time
#   * an http:// URL - a snapshot URL from the camera software's web server
# With none of those set, nothing is corrected and the presets stand as they
# are, which is exactly how this program behaved before.
#
# Needs ImageMagick for the measuring: sudo apt install imagemagick

# Where this user's home directory is.
#
# $HOME is right nearly always, but it is not set under some cron and systemd
# setups, which is exactly where this runs unattended - so the password
# database is the fallback, and it answers for whichever user is actually
# running the program. Nothing here has a user name written into it.
sub meter_home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME} && -d $ENV{HOME};
    my $pw = eval { (getpwuid($<))[7] };
    return $pw if defined $pw && length $pw && -d $pw;
    return '.';
}

# ---- The error log ----
#
# Everything that goes wrong is written here with a timestamp, so a failure at
# three in the morning can be read back in the morning. The status line in the
# window only ever shows the latest thing; this keeps the history.
#
# What gets logged: the startup probe, every snapshot failure with ffmpeg's own
# words, every trim the meter applies, every time it re-learns a preset, and
# anything that stops it working. What does not: the routine pass where the
# picture is already where it should be, which would be twelve lines a minute
# and would bury everything worth reading.
#
# Repeats are collapsed. A busy camera says so every five seconds, and without
# this the log would be nothing else; an error identical to the last one is
# written again only after ten minutes have passed.
my $LOG_FILE = $ENV{WEBCAM_LOG} || (meter_home_dir() . '/.webcam-light-meter.log');
my $LOG_MAX  = 1024 * 1024;        # trim the file once it passes a megabyte
my $log_last_msg = '';
my $log_last_time = 0;

sub meter_log {
    my ($msg, %opt) = @_;
    return unless defined $msg && length $msg;

    # Collapse an identical message repeated inside ten minutes.
    my $now = time();
    if (!$opt{always} && $msg eq $log_last_msg && ($now - $log_last_time) < 600) {
        return;
    }
    ($log_last_msg, $log_last_time) = ($msg, $now);

    # Keep the file from growing without end: past a megabyte, the newest 500
    # lines are kept and the rest dropped.
    if (-s $LOG_FILE && -s $LOG_FILE > $LOG_MAX) {
        if (open(my $in, '<', $LOG_FILE)) {
            my @lines = <$in>;
            close($in);
            @lines = @lines[-500 .. -1] if @lines > 500;
            if (open(my $out, '>', $LOG_FILE)) {
                print {$out} @lines;
                close($out);
            }
        }
    }

    open(my $fh, '>>', $LOG_FILE) or return;
    my @t = localtime($now);
    printf {$fh} "%04d-%02d-%02d %02d:%02d:%02d  %s\n",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $msg;
    close($fh);
    return 1;
}

sub meter_log_path { return $LOG_FILE; }

# The folder the snapshots live in, under whoever's home directory this is.
# WEBCAM_SNAPSHOT overrides it. It is created at startup if it is not there,
# parent folders and all.
my $SNAP_DEFAULT = meter_home_dir() . '/Pictures/webcam-sample-images';

my $snap_src = $ENV{WEBCAM_SNAPSHOT} || $SNAP_DEFAULT;
my $snap_tmp = '/tmp/.webcam-meter.jpg';

# Directories worth looking in when nothing is configured.
my @snap_guess = (
    $SNAP_DEFAULT,
    # Where this used to put them. Kept so that an installation that has
    # been filling that folder for months is still found rather than
    # starting over with nothing to measure.
    meter_home_dir() . '/Pictures/onn-webcam/program-snapshots-for-auto-adjust-picture',
    meter_home_dir() . '/webcam-snapshots',
    meter_home_dir() . '/.xeoma/snapshots',
    '/opt/Xeoma/snapshots',
    '/tmp/webcam-snapshots',
);

# Measure every 5 seconds, then wait two samples after a correction.
#
# Each change takes a moment to reach the next still the camera software
# writes, and a loop that acts faster than its own feedback arrives will
# oscillate - the picture breathes in and out all night instead of settling.
# Ten seconds of patience is what buys the settling.
my $METER_EVERY  = 30;
my $METER_SETTLE = 1;

# What a good picture looks like, as numbers.
#
# $mean_target is the average grey level wanted out of 255. 100 is a little
# under middle grey, which suits a dark scene with a few bright lights in it
# far better than a true middle grey does: aim at 128 and the security light
# blows out before the car under it is visible.
#
# The two clipping limits are the "not too much white light and not too much
# darkness" check. The mean cannot see either problem on its own - a frame
# that is half blown-out floodlight and half pitch black averages to a
# perfectly respectable middle grey while showing nothing at all. So the
# fraction of the frame gone to pure white and the fraction gone to pure black
# are measured separately, and either one can override the mean.
my $mean_target = $ENV{WEBCAM_TARGET} || 100;
my $MEAN_TOL    = 14;        # dead band, so it is not forever nudging
my $MAX_HOT     = 0.020;     # at most 2% of the frame blown to white
my $MAX_COLD    = 0.300;     # at most 30% of the frame crushed to black

# The five controls this loop may touch, and how far each moves per step of
# trim, as a fraction of that control's own range.
#
# A fraction rather than a fixed number because these programs drive more than
# one camera: brightness is -64 to 64 on one and 0 to 255 on another, so the
# same raw number would be a nudge on one camera and a lurch on the other. The
# real range comes from v4l2-ctl -L at startup.
#
# Gain carries most of the correction, because it is the control that actually
# amplifies signal. Brightness moves least: on these webcams it is a black
# level lift rather than exposure, so it buys apparent brightness at the cost
# of the black end, which is the mistake the old maximum-brightness night
# preset made. Contrast rises with the trim to keep the range spread out once
# gain has lifted everything. Saturation comes DOWN as the trim goes up, which
# is the "a little bit less colour at night" part - colour is never switched
# off at any trim, there is just less of it when the gain is high and most of
# the colour left is noise.
my %trim_rule = (
    gain                   =>  0.120,
    brightness             =>  0.025,
    contrast               =>  0.030,
    saturation             => -0.025,
    backlight_compensation =>  0.200,
);
my @trim_ctrls = sort keys %trim_rule;

# The ranges to use when the camera does not report one.
#
# The hardware is asked first, at startup, and whatever it says is what gets
# used - that is the only way to be right about a camera that has not been
# seen before. These two tables are the fallback for anything it does not
# answer for, and they are not invented: they are the ranges these programs
# have been using all along, the modern set from the ONN webcam's own sliders
# and the legacy set from the older camera's 0-255 controls.
#
# Which table applies is decided by the same test the preset engine uses: a
# camera with exposure_time_absolute is the modern kind, one with
# exposure_absolute is the older kind.
my %FALLBACK_MODERN = (
    brightness             => [-64,  64],
    contrast               => [  0,  95],
    saturation             => [  0, 120],
    gain                   => [  0, 100],
    backlight_compensation => [  0,  12],
    sharpness              => [  0,   7],
);
my %FALLBACK_LEGACY = (
    brightness             => [  0, 255],
    contrast               => [  0, 255],
    saturation             => [  0, 255],
    gain                   => [  0, 255],
    backlight_compensation => [  0,  16],
    sharpness              => [  0, 255],
);

my %ctrl_source;             # control => 'camera' or 'fallback', for reporting
my $camera_kind = 'unknown';
my $ctrl_has_focus;          # whichever continuous-autofocus control this camera has

# The two names continuous autofocus goes by: the current one, and the
# pre-5.10 kernel name on the older webcam.
my $FOCUS_CTRL        = 'focus_automatic_continuous';
my $FOCUS_CTRL_LEGACY = 'focus_auto';

my $TRIM_MAX = 5;            # steps either side of whatever the preset set

my %ctrl_range;              # name => [min, max], read from the camera
my %meter_base;              # the preset's own values, re-learnt automatically
my %meter_wrote;             # what this loop last sent, to spot outside changes
my $trim        = 0;
my $meter_hold  = 0;
my @meter_means = ();
my $meter_dir   = 0;
my $meter_last  = 0;         # epoch second of the last pass

# Ask the camera, once at startup, for the real range of every control this
# loop uses, and fall back to the ranges these programs already used for
# anything it does not answer for.
#
# This matters more than it looks. A trim step is a fraction of a control's
# range, so a wrong range means a step of the wrong size: guess 0-64 for a
# contrast control that really runs 0-95 and every correction lands a third
# short. Asking the hardware is the only way to be right about a camera that
# has not been seen before, and the fallback means an unanswered control still
# gets a sensible step instead of being dropped.
sub meter_learn_ranges {
    my ($dev) = @_;
    %ctrl_range  = ();
    %ctrl_source = ();
    $camera_kind = 'unknown';

    my @lines = `v4l2-ctl -d $dev -L 2>/dev/null`;
    my %seen;
    for my $line (@lines) {
        next unless $line =~ /^\s*(\w+)\s+0x[0-9a-f]+\s+\((?:int|bool|menu|intmenu)\)/i;
        my $name = $1;
        $seen{$name} = 1;
        next unless exists $trim_rule{$name} || $name eq 'sharpness';
        my ($min) = $line =~ /min=(-?\d+)/;
        my ($max) = $line =~ /max=(-?\d+)/;
        if (defined $min && defined $max && $max > $min) {
            $ctrl_range{$name}  = [$min, $max];
            $ctrl_source{$name} = 'camera';
        }
    }

    # Which name this camera's continuous autofocus goes by, if it has one.
    $ctrl_has_focus = $seen{$FOCUS_CTRL}        ? $FOCUS_CTRL
                    : $seen{$FOCUS_CTRL_LEGACY} ? $FOCUS_CTRL_LEGACY
                    :                             undef;

    # Same test the preset engine uses to tell the two cameras apart.
    $camera_kind = 'modern' if $seen{exposure_time_absolute};
    $camera_kind = 'legacy' if !$seen{exposure_time_absolute} && $seen{exposure_absolute};

    # Anything the camera did not answer for gets the settings already in use.
    # With no answer at all - camera unplugged, or v4l2-ctl missing - the
    # modern table is the one to assume, since that is the camera these
    # programs are run against.
    my $fallback = ($camera_kind eq 'legacy') ? \%FALLBACK_LEGACY : \%FALLBACK_MODERN;
    for my $name (@trim_ctrls, 'sharpness') {
        next if $ctrl_range{$name};
        next unless $fallback->{$name};
        $ctrl_range{$name}  = [ @{ $fallback->{$name} } ];
        $ctrl_source{$name} = 'fallback';
    }
    meter_log(meter_range_report(), always => 1);
    return scalar keys %ctrl_range;
}

# One line saying what the startup probe found, for the log or the window.
sub meter_range_report {
    my @all = (@trim_ctrls, 'sharpness');
    my @from_camera = sort grep { ($ctrl_source{$_} || '') eq 'camera'   } @all;
    my @assumed     = sort grep { ($ctrl_source{$_} || '') eq 'fallback' } @all;
    my $text = "light meter: $camera_kind camera";
    $text .= ', ranges read from the camera for ' . join(', ', @from_camera) if @from_camera;
    $text .= ', using the settings already in use for ' . join(', ', @assumed) if @assumed;
    return $text;
}

# Read the controls back in one call. v4l2-ctl takes a comma separated list,
# which is one process instead of five every five seconds.
sub meter_read_ctrls {
    my ($dev) = @_;
    my @names = grep { exists $ctrl_range{$_} } @trim_ctrls;
    return () unless @names;
    # Built as a string first on purpose: backticks are evaluated before any
    # concatenation around them, so writing the list after a closing backtick
    # runs v4l2-ctl with no controls named and quietly returns nothing.
    my $cmd = "v4l2-ctl -d $dev --get-ctrl " . join(',', @names) . ' 2>/dev/null';
    my $out = `$cmd`;
    my %v;
    while ($out =~ /(\w+):\s*(-?\d+)/g) { $v{$1} = $2 if exists $ctrl_range{$1}; }
    return %v;
}

# ---- Making the snapshots, and keeping only the last 30 ----
#
# The recording software may be writing stills into the folder already, in
# which case there is nothing to do here. When it is not - an empty folder on
# the first run - a frame is grabbed here instead, with ffmpeg.
#
# That only works while the camera is free. A V4L2 camera lets one program
# stream at a time, so if the recording software has the device the grab fails
# with a busy error and there is nothing to be done about it: the loop then
# measures whatever stills that software writes, which is the arrangement this
# was built for. The failure is reported once and then left alone, because a
# warning every five seconds all night is worse than the problem.
my $SNAP_KEEP = 30;          # snapshots to keep; the oldest beyond this go
my $snap_capture_note = '';  # set once, so a busy camera is not shouted about
my $snap_capture_tried = 0;
my $snap_busy_until = 0;     # when the camera is held, stop asking for a while
my $SNAP_BUSY_WAIT = 60;

# mkdir -p, without pulling in File::Path for one line.
sub make_dir_path {
    my ($dir) = @_;
    return 1 if -d $dir;
    my $sofar = '';
    for my $part (split m{/}, $dir) {
        $sofar .= "/$part" if length $part;
        next unless length $sofar;
        mkdir $sofar unless -d $sofar;
    }
    return -d $dir;
}

# The snapshot folder, when the source is a folder at all. A single file or an
# http URL is somebody else's to manage, so neither is written to or pruned.
sub snap_dir {
    my $src = length $snap_src ? $snap_src : '';
    return undef if !length $src || $src =~ m{^https?://} || -f $src;
    return $src;
}

# Delete the oldest until only $SNAP_KEEP are left.
#
# Everything with a .jpg name in the folder counts, whoever wrote it, because
# the folder is there for these snapshots and nothing else. Point $snap_src at
# a folder that holds pictures worth keeping and they will be pruned too.
sub prune_snapshots {
    my ($dir) = @_;
    return unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return;
    my @shots;
    while (my $f = readdir($dh)) {
        next unless $f =~ /\.jpe?g$/i;
        my $path = "$dir/$f";
        next unless -f $path;
        push @shots, [ $path, -M $path ];     # -M is age, so smaller is newer
    }
    closedir($dh);
    return if @shots <= $SNAP_KEEP;
    my @oldest_first = sort { $b->[1] <=> $a->[1] } @shots;
    my $to_go = @shots - $SNAP_KEEP;
    unlink $oldest_first[$_][0] for 0 .. ($to_go - 1);
    return $to_go;
}

# Who has the camera open, if anyone.
#
# This exists because of how the two programs actually get used: the snapshot
# grab works when this program is started BEFORE the recording software, and
# stops working the moment that software opens the device - a V4L2 camera
# lets one program stream at a time.
#
# Knowing that is worth more than retrying blindly. If the recorder has the
# camera, running ffmpeg at it every five seconds achieves nothing, and there
# is a real risk in it: if the recorder drops and re-opens its stream at the
# instant our grab lands, our grab wins and the recorder fails to come back.
# So when something else holds the device, nothing is sent to it at all.
#
# fuser and lsof both answer this; whichever is installed is used, and if
# neither is, the grab is simply attempted as before.
sub camera_holder {
    my ($dev) = @_;
    return undef unless -e $dev;

    if (system('command -v fuser >/dev/null 2>&1') == 0) {
        my $out = `fuser -v $dev 2>&1`;
        my %names;
        for my $line (split /\n/, ($out || '')) {
            # fuser -v lines look like:  USER  PID  ACCESS  COMMAND
            next unless $line =~ /^\s*\S*\s+(\d+)\s+\S+\s+(\S+)\s*$/;
            my ($pid, $name) = ($1, $2);
            next if $pid == $$;
            $names{"$name (pid $pid)"} = 1;
        }
        return join(', ', sort keys %names) if %names;
    }

    if (system('command -v lsof >/dev/null 2>&1') == 0) {
        my $out = `lsof -F cp $dev 2>/dev/null`;
        my ($pid, %names);
        for my $line (split /\n/, ($out || '')) {
            $pid = $1 if $line =~ /^p(\d+)/;
            if ($line =~ /^c(\S+)/ && defined $pid && $pid != $$) {
                $names{"$1 (pid $pid)"} = 1;
            }
        }
        return join(', ', sort keys %names) if %names;
    }
    return undef;
}

# Grab one frame into the snapshot folder. Returns the path, or undef when the
# camera is busy, ffmpeg is missing, or there is no folder to write to.
sub capture_snapshot {
    my ($dev) = @_;
    my $dir = snap_dir();
    return undef unless defined $dir;
    return undef unless make_dir_path($dir);

    unless ($snap_capture_tried) {
        $snap_capture_tried = 1;
        if (system('command -v ffmpeg >/dev/null 2>&1') != 0) {
            $snap_capture_note = 'ffmpeg is not installed, so no snapshots can be taken here';
            meter_log($snap_capture_note);
            return undef;
        }
    }
    # The note is cleared each attempt, so a camera that was busy a minute ago
    # is tried again rather than written off for the rest of the session.
    # ffmpeg missing is the one thing that will not fix itself, so that one
    # stops here.
    return undef if $snap_capture_note =~ /not installed/;

    # Something else has the camera. Say who, leave the device alone, and look
    # again in a minute rather than every five seconds.
    my $holder = camera_holder($dev);
    if (defined $holder) {
        $snap_capture_note =
            "$holder has $dev - snapshots come from the recording software while it runs";
        meter_log("camera held by $holder, not grabbing");
        $snap_busy_until = time() + $SNAP_BUSY_WAIT;
        return undef;
    }
    return undef if time() < $snap_busy_until;

    $snap_capture_note = '';

    my @t = localtime();
    my $name = sprintf('%s/snapshot-%04d%02d%02d-%02d%02d%02d.jpg',
        $dir, $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    # ffmpeg's own error is kept rather than thrown away. It used to go to
    # /dev/null and every failure was reported as a busy camera, which is only
    # one of the things that can go wrong here - the device can be missing, the
    # user can be outside the video group, the driver can refuse the pixel
    # format. Guessing at which one wastes an evening; the actual line says.
    my $err_file = '/tmp/.webcam-meter-ffmpeg.err';
    my $rc = system("ffmpeg -nostdin -loglevel error -f v4l2 -i $dev"
                  . " -frames:v 1 -q:v 2 -y '$name' 2>$err_file");
    if ($rc != 0 || !-s $name) {
        unlink $name if -e $name;
        my $why = '';
        if (open(my $fh, '<', $err_file)) {
            my @lines = <$fh>;
            close($fh);
            # The last line is the one that says what actually failed.
            for my $line (reverse @lines) {
                chomp $line;
                next unless $line =~ /\S/;
                $why = $line;
                last;
            }
        }
        $snap_capture_note =
              $why =~ /busy/i             ? "camera is busy ($dev is held by something else), so stills come from the recording software"
            : $why =~ /permission|denied/i ? "no permission to open $dev - add this user to the video group"
            : $why =~ /No such file/i      ? "$dev does not exist - is the camera plugged in?"
            : length $why                  ? "ffmpeg could not take a snapshot: $why"
            :                                "ffmpeg could not take a snapshot from $dev";
        meter_log("snapshot failed: $snap_capture_note"
                . (length $why ? " [ffmpeg: $why]" : ''));
        return undef;
    }
    my $gone = prune_snapshots($dir);
    meter_log("deleted $gone snapshots over the $SNAP_KEEP kept") if $gone;
    # Worth one line when it starts working again after failing.
    meter_log("snapshots are being taken again: $name") if length $snap_capture_note;
    $snap_capture_note = '';
    return $name;
}

# Make the snapshot folder if it is not there, and bring it down to size, so
# the first run starts from a clean folder of at most 30.
sub meter_prepare_snapshots {
    my $dir = snap_dir();
    return 'light meter: no snapshot folder set' unless defined $dir;
    unless (make_dir_path($dir)) {
        meter_log("cannot create the snapshot folder $dir");
        return "light meter: cannot create $dir";
    }
    my $gone = prune_snapshots($dir);
    my $line = "light meter: snapshots in $dir, keeping the newest $SNAP_KEEP"
             . ($gone ? " (deleted $gone older)" : '');
    meter_log($line, always => 1);
    return $line;
}

# Find a still to measure. Returns a path, or undef if there is nothing usable.
sub meter_snapshot {
    my $src = $snap_src;
    if (!length $src) {
        for my $d (@snap_guess) { if (-d $d) { $src = $d; last; } }
    }
    return undef unless length $src;

    if ($src =~ m{^https?://}) {
        unlink $snap_tmp;
        system("curl -s -m 4 -o '$snap_tmp' '$src' 2>/dev/null");
        return (-s $snap_tmp) ? $snap_tmp : undef;
    }
    if (-d $src) {
        my ($newest, $newest_age) = (undef, 1e18);
        if (opendir(my $dh, $src)) {
            while (my $f = readdir($dh)) {
                next unless $f =~ /\.jpe?g$/i;
                my $path = "$src/$f";
                next unless -f $path;
                my $age = -M $path;
                if ($age < $newest_age) { ($newest_age, $newest) = ($age, $path); }
            }
            closedir($dh);
        }
        # A still from last week says nothing about the light right now.
        return undef if !defined $newest || $newest_age > (10 / 1440);
        return $newest;
    }
    return (-f $src) ? $src : undef;
}

# Measure a still: average grey level out of 255, and how much of it has gone
# to pure white and to pure black.
#
# The mean is taken on a quarter size copy, which is both faster and steadier -
# averaging is exactly what shrinking an image does. The clipping figures are
# taken at full size, where a count of individual blown pixels still means
# something.
# Which ImageMagick is installed.
#
# ImageMagick 7, which is what Ubuntu 26.04 ships, dropped the `convert`
# command in favour of `magick`; ImageMagick 6, on 24.04 and earlier, has
# `convert` and no `magick`. The arguments are the same either way, so it is
# only the command name that has to be worked out - once, and then remembered.
# Without this the measuring silently finds nothing on a newer Ubuntu and the
# light meter sits there reporting no snapshot.
my $MAGICK;
sub magick_cmd {
    return $MAGICK if defined $MAGICK;
    for my $try ('magick', 'convert') {
        if (system("command -v $try >/dev/null 2>&1") == 0) {
            $MAGICK = $try;
            return $MAGICK;
        }
    }
    $MAGICK = '';
    return $MAGICK;
}

sub meter_measure {
    my ($f) = @_;
    return () unless defined $f;
    my $im = magick_cmd();
    return () unless length $im;
    my $mean = `$im "$f" -colorspace Gray -resize 25% -format "%[fx:mean*255]" info: 2>/dev/null`;
    return () unless defined $mean && $mean =~ /([\d.]+)/;
    $mean = $1;
    my $hot  = `$im "$f" -colorspace Gray -threshold 97% -format "%[fx:mean]" info: 2>/dev/null`;
    my $warm = `$im "$f" -colorspace Gray -threshold 3%  -format "%[fx:mean]" info: 2>/dev/null`;
    $hot  = ($hot  =~ /([\d.]+)/) ? $1 : 0;
    $warm = ($warm =~ /([\d.]+)/) ? $1 : 1;
    # -threshold keeps what is ABOVE the level, so the black fraction is what
    # is left once the pixels above 3% are taken out.
    return ($mean, $hot, 1 - $warm);
}

# Sharpness, as a fraction of the control's range: full sharpness in daylight
# and through the golden hours, backed off to 80-90% at night.
#
# This is set outright rather than trimmed, and it overrides whatever sharpness
# the preset asked for - including the night preset's deliberately low value.
# That is on purpose and on request: the picture is wanted sharp.
#
# What decides night from day here is gain, not the clock. Gain is the only
# control that amplifies the sensor's noise along with the signal, so a camera
# running near the top of its gain range is by definition working in the dark,
# whatever time the clock says - and the golden hour presets, which sit under
# half of the gain range, come out at full sharpness as they should. Sharpening
# is contrast enhancement at the pixel level and it sharpens noise as happily
# as it sharpens the edge of a number plate, which is the one reason to ease
# off at all once the gain is high.
my $SHARP_DAY   = 1.00;      # at or below half gain: full sharpness
my $SHARP_NIGHT = 0.90;      # just into high gain
my $SHARP_DARK  = 0.80;      # at the top of the gain range
my $SHARP_KNEE  = 0.50;      # the gain fraction where the easing off starts

# Work out the sharpness this amount of gain calls for, in the control's own
# units. Returns nothing when the camera has no sharpness control or no gain
# to judge by.
sub meter_sharpness_for {
    my ($gain_now) = @_;
    return undef unless $ctrl_range{sharpness} && $ctrl_range{gain} && defined $gain_now;
    my ($glo, $ghi) = @{ $ctrl_range{gain} };
    my ($slo, $shi) = @{ $ctrl_range{sharpness} };
    my $gain_fraction = ($gain_now - $glo) / ($ghi - $glo);
    $gain_fraction = 0 if $gain_fraction < 0;
    $gain_fraction = 1 if $gain_fraction > 1;

    my $want;
    if ($gain_fraction <= $SHARP_KNEE) {
        $want = $SHARP_DAY;
    } else {
        # Straight line from 90% at the knee down to 80% at full gain.
        my $into_dark = ($gain_fraction - $SHARP_KNEE) / (1 - $SHARP_KNEE);
        $want = $SHARP_NIGHT - ($SHARP_NIGHT - $SHARP_DARK) * $into_dark;
    }
    my $value = int($slo + ($shi - $slo) * $want + 0.5);
    $value = $slo if $value < $slo;
    $value = $shi if $value > $shi;
    return $value;
}

# Re-run the autofocus after a light change.
#
# Changing gain, brightness or contrast changes what the autofocus is looking
# at, and the camera does not always re-run it on its own: the first seconds
# after a change come out soft, which on a recording is the part you most want
# sharp. Switching continuous autofocus off and straight back on makes it start
# a fresh search.
#
# It is switched back ON every time, unconditionally, and nothing in these
# programs ever leaves the camera in manual focus.
#
# The pause between off and on is there because the driver has to see the
# control actually change state; without it the two writes can land in the same
# instant and nothing is re-triggered. A third of a second is enough, and is
# not long enough to be felt.
sub meter_refocus {
    my ($dev) = @_;
    # Falls back to the current control name when the probe found nothing, so
    # autofocus still ends up on; a write to a control the camera lacks fails
    # harmlessly.
    my $ctrl = defined $ctrl_has_focus ? $ctrl_has_focus : $FOCUS_CTRL;
    system("v4l2-ctl -d $dev --set-ctrl $ctrl=0 2>/dev/null");
    select(undef, undef, undef, 0.33);
    system("v4l2-ctl -d $dev --set-ctrl $ctrl=1 2>/dev/null");
    return 1;
}

# Send the current trim, worked out from the preset's own baseline.
sub meter_apply_trim {
    my ($dev, $t) = @_;
    $t = -$TRIM_MAX if $t < -$TRIM_MAX;
    $t =  $TRIM_MAX if $t >  $TRIM_MAX;
    $trim = $t;
    %meter_wrote = ();
    for my $ctrl (@trim_ctrls) {
        next unless defined $meter_base{$ctrl} && $ctrl_range{$ctrl};
        my ($lo, $hi) = @{ $ctrl_range{$ctrl} };
        my $per = int($trim_rule{$ctrl} * ($hi - $lo) + 0.5 * ($trim_rule{$ctrl} <=> 0));
        $per = ($trim_rule{$ctrl} > 0 ? 1 : -1) if $per == 0;   # never a no-op step
        my $v = $meter_base{$ctrl} + ($per * $t);
        $v = $lo if $v < $lo;
        $v = $hi if $v > $hi;
        system("v4l2-ctl -d $dev --set-ctrl $ctrl=$v 2>/dev/null");
        $meter_wrote{$ctrl} = $v;
    }

    # Sharpness follows the gain that was just sent. It is deliberately kept
    # out of %meter_wrote: that hash is how an outside change is spotted, and
    # sharpness is a value this loop owns outright rather than a trim away
    # from the preset's own.
    my $sharp = meter_sharpness_for($meter_wrote{gain});
    system("v4l2-ctl -d $dev --set-ctrl sharpness=$sharp 2>/dev/null") if defined $sharp;

    # The light just moved, so give the autofocus a fresh start on it.
    meter_refocus($dev);
    return;
}

sub meter_median {
    my @s = sort { $a <=> $b } @_;
    return @s ? $s[int(@s / 2)] : undef;
}

# One pass. Called as often as you like; it does its work every $METER_EVERY
# seconds and returns immediately the rest of the time. Returns a status line.
sub meter_pass {
    my ($dev) = @_;
    my $now = time();
    return undef if $now - $meter_last < $METER_EVERY;
    $meter_last = $now;

    # Normally already done at startup; this covers a camera that was not
    # plugged in then.
    meter_learn_ranges($dev) unless keys %ctrl_range;

    # Re-learn the baseline if anything other than this loop moved the
    # controls - a preset firing, or a hand on a slider. This is how the
    # correction stays a correction to whatever is in force rather than
    # drifting off on its own.
    #
    # Two units of slack, because a driver may round a control to its own step
    # size. Without the slack a value that comes back as 99 after 100 was sent
    # would look like an outside change, the baseline would be re-learnt with
    # the trim already inside it, and the next correction would trim again from
    # there: a ratchet that walks the picture off in one direction.
    my %have = meter_read_ctrls($dev);
    if (keys %have) {
        my $outside = 0;
        for my $ctrl (keys %have) {
            if (!defined $meter_wrote{$ctrl} || abs($meter_wrote{$ctrl} - $have{$ctrl}) > 2) {
                $outside = 1;
                last;
            }
        }
        if ($outside) {
            %meter_base  = %have;
            %meter_wrote = %have;
            $trim        = 0;
            $meter_dir   = 0;
            @meter_means = ();
            $meter_hold  = 1;    # let the new preset show up before correcting
            # The preset just overwrote sharpness with its own value, so put
            # the wanted sharpness back for the gain this preset runs at.
            my $sharp = meter_sharpness_for($have{gain});
            system("v4l2-ctl -d $dev --set-ctrl sharpness=$sharp 2>/dev/null") if defined $sharp;
            # A preset just changed the light, so refocus for it as well.
            meter_refocus($dev);
            meter_log('learnt new baseline: '
                . join(' ', map { "$_=$have{$_}" } sort keys %have), always => 1);
            return 'light meter: learnt the current preset as the baseline'
                 . (defined $sharp ? ", sharpness set to $sharp" : '');
        }
        # Rounding, not an outside change: keep the baseline and the trim, and
        # accept what the driver actually holds as what was written.
        $meter_wrote{$_} = $have{$_} for keys %have;
    }

    if ($meter_hold > 0) {
        $meter_hold--;
        return sprintf('light meter: trim %+d, waiting for the picture to catch up', $trim);
    }

    # Take one of our own first. When the recording software has the camera
    # this does nothing and the still it wrote is used instead.
    capture_snapshot($dev);

    my $frame = meter_snapshot();
    my ($mean, $hot, $cold) = meter_measure($frame);
    unless (defined $mean) {
        unless (length magick_cmd()) {
            meter_log('ImageMagick is not installed, so the picture cannot be measured');
            return 'light meter: ImageMagick is not installed, so the picture cannot be measured';
        }
        return 'light meter: no snapshot to measure, the preset stands as it is'
             . (length $snap_capture_note ? " - $snap_capture_note" : '');
    }

    # Median of the last three keeps a passing pair of headlights from
    # dragging the picture darker for the next minute.
    push @meter_means, $mean;
    shift @meter_means while @meter_means > 3;
    my $m = meter_median(@meter_means);

    # Which way to go. The clipping checks come first: they are the too much
    # white light and too much darkness tests, and either can override a mean
    # that looks perfectly reasonable on its own.
    my $dir = 0;
    my $why = 'picture is where it should be';
    if ($hot > $MAX_HOT && $m > $mean_target - $MEAN_TOL) {
        $dir = -1; $why = sprintf('%.1f%% of the frame blown to white', $hot * 100);
    } elsif ($cold > $MAX_COLD && $m < $mean_target + $MEAN_TOL) {
        $dir =  1; $why = sprintf('%.0f%% of the frame crushed to black', $cold * 100);
    } elsif ($m > $mean_target + $MEAN_TOL) {
        $dir = -1; $why = 'too bright';
    } elsif ($m < $mean_target - $MEAN_TOL) {
        $dir =  1; $why = 'too dark';
    }

    # A security light over black tarmac holds more range than the sensor can
    # take, and then both checks fail at once: brightening blows the light
    # further, darkening loses the car. Rather than run off to one end of the
    # trim chasing an impossible picture, it stops and says so.
    if ($dir > 0 && $hot > $MAX_HOT * 3) {
        $dir = 0; $why = 'high contrast scene - cannot lift the dark without blowing the light';
    } elsif ($dir < 0 && $cold > $MAX_COLD * 2) {
        $dir = 0; $why = 'high contrast scene - cannot tame the light without losing the dark';
    }

    # Two samples in a row have to agree before anything moves.
    if ($dir != 0 && $dir == $meter_dir) {
        if (($dir > 0 && $trim >= $TRIM_MAX) || ($dir < 0 && $trim <= -$TRIM_MAX)) {
            $why .= ' - trim at its limit, the preset itself needs changing';
        } else {
            meter_apply_trim($dev, $trim + $dir);
            $meter_hold  = $METER_SETTLE;
            @meter_means = ();
            $why .= sprintf(' - trimmed to %+d', $trim);
            meter_log(sprintf('trim %+d: mean %d of target %d, white %.1f%%, black %.0f%% (%s)',
                $trim, $m, $mean_target, $hot * 100, $cold * 100, $why), always => 1);
        }
    }
    $meter_dir = $dir;

    return sprintf('light meter: trim %+d, mean %d of target %d, white %.1f%%, black %.0f%% - %s',
        $trim, $m, $mean_target, $hot * 100, $cold * 100, $why);
}

# ---- The terminal at the bottom of the window ----
#
# Eighty columns by fifteen lines, with the day and night scheduler running in
# it, so the window shows what the schedule is actually doing and not only
# what has been pressed here. It is read-only: the scheduler takes no input,
# and a text box that cannot be typed into cannot be scrolled away from the
# newest line by a stray keystroke.
#
# Perl/Tk has one thread and one event loop, and a blocking read on a pipe
# inside that loop would freeze every widget until the next line arrived.
# fileevent is the way round it: the event loop watches the pipe itself and
# calls back only when there is something to be read, so this costs nothing
# at all while the scheduler is quiet, which is most of the day.

my $TERM_COLS      = 80;
my $TERM_ROWS      = 15;
my $TERM_MAX_LINES = 2000;   # scrollback kept before the oldest lines go
my $TERM_SCRIPT    = 'perl-webcam-day-night-command.pl';

my %term;

# Next to this file, then the home directory, then the working directory - the
# same order run_preset uses, and for the same reason: these files get copied
# to ~ and run from either place.
sub term_find {
    my ($filename) = @_;
    for my $dir (File::Basename::dirname(Cwd::abs_path($0)), home_dir(), Cwd::getcwd()) {
        return "$dir/$filename" if -r "$dir/$filename";
    }
    return undef;
}

sub term_write {
    my ($line) = @_;
    my $text = $term{text} or return;
    # Follow the newest line only when the view is already at the bottom, so
    # that scrolling back to read something is not yanked away again by the
    # next line arriving.
    my @view = $text->yview;
    my $at_bottom = ($view[1] >= 0.999);
    $text->configure(-state => 'normal');
    $text->insert('end', $line);
    my $lines = int($text->index('end-1c'));
    if ($lines > $TERM_MAX_LINES) {
        $text->delete('1.0', ($lines - $TERM_MAX_LINES + 1) . '.0');
    }
    $text->configure(-state => 'disabled');
    $text->see('end') if $at_bottom;
}

sub term_clear {
    my $text = $term{text} or return;
    $text->configure(-state => 'normal');
    $text->delete('1.0', 'end');
    $text->configure(-state => 'disabled');
}

sub term_start {
    return if $term{pid};
    my $path = $term{path} ||= term_find($term{file});
    if (!defined $path) {
        term_write("$term{file} was not found next to $0, in " . home_dir()
            . ", or in " . Cwd::getcwd() . ".\n");
        $term{status}->configure(-text => 'not found', -fg => '#a00');
        return;
    }

    # stdbuf keeps the output coming a line at a time. Writing to a pipe makes
    # a program buffer in blocks instead of lines, and a block of log an hour
    # from now is no use in a window meant to show what is happening; where
    # stdbuf is not installed the lines still arrive, just in batches.
    # 2>&1 because the warnings are the half of the output most worth seeing.
    my $quote = sub { my $s = shift; $s =~ s/'/'\\''/g; "'$s'" };
    my $cmd = (-x '/usr/bin/stdbuf' ? 'stdbuf -oL -eL ' : '')
        . $quote->($^X) . ' ' . $quote->($path) . ' 2>&1';

    my $fh;
    my $pid = open($fh, '-|', 'sh', '-c', "exec $cmd");
    if (!$pid) {
        term_write("could not start $path: $!\n");
        $term{status}->configure(-text => 'failed to start', -fg => '#a00');
        return;
    }
    $term{fh}       = $fh;
    $term{pid}      = $pid;
    $term{stopping} = 0;
    term_write('--- ' . File::Basename::basename($path) . " started, pid $pid ---\n");
    $term{status}->configure(-text => "running, pid $pid", -fg => '#060');
    $term{mw}->fileevent($fh, 'readable', \&term_readable);
}

sub term_readable {
    my $fh = $term{fh} or return;
    my $line = <$fh>;
    if (defined $line) {
        term_write($line);
        return;
    }
    # Nothing more to come: the child has closed its end and finished.
    eval { $term{mw}->fileevent($fh, 'readable', '') };
    close $fh;
    my $status = $? >> 8;
    delete $term{fh};
    delete $term{pid};
    term_write("--- exited, status $status ---\n");
    $term{status}->configure(
        -text => $term{stopping} ? 'stopped' : "exited, status $status",
        -fg   => $term{stopping} ? '#555'    : '#a00',
    );
}

sub term_stop {
    my $pid = $term{pid};
    if (!$pid) {
        $term{status}->configure(-text => 'not running', -fg => '#555') if $term{status};
        return;
    }
    $term{stopping} = 1;
    # Ask first: the scheduler may be part way through writing to the camera,
    # and it gets to finish. Insist only if it ignores the asking.
    kill 'TERM', $pid;
    my $reaped = 0;
    for (1 .. 30) {
        if (waitpid($pid, 1) == $pid) { $reaped = 1; last }
        select undef, undef, undef, 0.1;
    }
    if (!$reaped) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
    if (my $fh = delete $term{fh}) {
        eval { $term{mw}->fileevent($fh, 'readable', '') };
        close $fh;
    }
    delete $term{pid};
    $term{status}->configure(-text => 'stopped', -fg => '#555');
}

sub term_restart { term_stop(); term_start(); }

# How much of the window height the terminal takes, so that the scrolling area
# above it can be given what is left of the screen rather than the whole of
# it - otherwise the window opens taller than the screen and the terminal is
# pushed off the bottom edge, which is where it is least use.
sub term_height {
    return 0 unless $term{frame};
    $term{frame}->update;
    return $term{frame}->reqheight;
}

sub build_terminal {
    my ($mw, $filename) = @_;
    %term = (mw => $mw, file => $filename);

    my $frame = $mw->Frame(-borderwidth => 1, -relief => 'sunken');
    $frame->pack(-side => 'bottom', -fill => 'x', -padx => 4, -pady => 3);
    $term{frame} = $frame;

    my $bar = $frame->Frame->pack(-fill => 'x');
    $bar->Label(-text => $filename, -font => 'Helvetica 9 bold')
        ->pack(-side => 'left', -padx => 4);
    $term{status} = $bar->Label(-text => 'starting', -font => 'Helvetica 8', -fg => '#036');
    $term{status}->pack(-side => 'left', -padx => 4);
    $bar->Button(-text => 'Clear', -font => 'Helvetica 8', -command => \&term_clear)
        ->pack(-side => 'right', -padx => 2);
    $bar->Button(-text => 'Restart', -font => 'Helvetica 8', -command => \&term_restart)
        ->pack(-side => 'right', -padx => 2);
    $bar->Button(-text => 'Stop', -font => 'Helvetica 8', -command => \&term_stop)
        ->pack(-side => 'right', -padx => 2);

    # The horizontal scrollbar is packed before the body, because pack hands
    # out space in the order it is asked and the body expands into whatever is
    # left - ask the other way round and the scrollbar gets squeezed to
    # nothing.
    my $hscroll = $frame->Scrollbar(-orient => 'horizontal');
    $hscroll->pack(-side => 'bottom', -fill => 'x');

    my $body = $frame->Frame->pack(-fill => 'both', -expand => 1);
    my $text = $body->Text(
        -width            => $TERM_COLS,
        -height           => $TERM_ROWS,
        -wrap             => 'none',
        -font             => 'Courier 9',
        -background       => '#101010',
        -foreground       => '#d0d0d0',
        -insertbackground => '#d0d0d0',
        -highlightthickness => 0,
        -state            => 'disabled',
    );
    my $vscroll = $body->Scrollbar(-orient => 'vertical',
        -command => [ 'yview', $text ], -width => 16);
    $hscroll->configure(-command => [ 'xview', $text ]);
    $text->configure(-yscrollcommand => [ 'set', $vscroll ],
                     -xscrollcommand => [ 'set', $hscroll ]);
    $text->pack(-side => 'left', -fill => 'both', -expand => 1);
    $vscroll->pack(-side => 'right', -fill => 'y');
    $term{text} = $text;

    # The wheel bindings for the controls above are on the toplevel, which
    # child widgets inherit, so without a break here the wheel over the
    # terminal would scroll the controls behind it instead of the log.
    $text->bind('<Button-4>', sub { $text->yview('scroll', -3, 'units'); Tk->break });
    $text->bind('<Button-5>', sub { $text->yview('scroll',  3, 'units'); Tk->break });
    $text->bind('<MouseWheel>', [ sub {
        my ($widget, $delta) = @_;
        $text->yview('scroll', ($delta > 0 ? -3 : 3), 'units');
        Tk->break;
    }, Tk::Ev('D') ]);

    term_start();
    return $frame;
}

# ---- The window ----

my $mw = MainWindow->new(-title => 'Webcam Settings');

$mw->Label(-text => 'Webcam Controls', -font => 'Helvetica 13 bold')->pack(-pady => 4);

my $cam_line = %cam
    ? sprintf('%d controls read from %s', scalar keys %cam, $device)
    : "No controls readable from $device - is the camera plugged in?";
$mw->Label(-text => $cam_line, -font => 'Helvetica 9', -fg => '#036')->pack;

# Everything below scrolls. A camera with every control the kernel defines
# makes a taller column than most screens have room for.
my $scroll_area = $mw->Frame;
my $canvas = $scroll_area->Canvas(-highlightthickness => 0, -takefocus => 1)
    ->pack(-side => 'left', -fill => 'both', -expand => 1);
# Wide enough to get hold of with the mouse - this is the slider for the
# camera settings above, and it is used often enough to be worth the pixels.
my $vbar = $scroll_area->Scrollbar(-orient => 'vertical', -command => ['yview', $canvas],
    -width => 18)
    ->pack(-side => 'right', -fill => 'y');
build_terminal($mw, $TERM_SCRIPT);
my $hbar = $mw->Scrollbar(-orient => 'horizontal', -command => ['xview', $canvas])
    ->pack(-side => 'bottom', -fill => 'x');
$canvas->configure(-yscrollcommand => ['set', $vbar], -xscrollcommand => ['set', $hbar]);
$scroll_area->pack(-fill => 'both', -expand => 1);

my $cols = $canvas->Frame;
my $cols_id = $canvas->createWindow(0, 0, -window => $cols, -anchor => 'nw');
$cols->bind('<Configure>', sub { $canvas->configure(-scrollregion => [ $canvas->bbox('all') ]) });
$canvas->bind('<Configure>', sub {
    my $width = $canvas->width;
    return if $width <= 1;
    my $needed = $cols->reqwidth;
    $canvas->itemconfigure($cols_id, -width => ($width > $needed ? $width : $needed));
});
$mw->bind('<Button-4>', sub { $canvas->yview('scroll', -3, 'units') });
$mw->bind('<Button-5>', sub { $canvas->yview('scroll',  3, 'units') });
$mw->bind('<MouseWheel>', [ sub {
    my ($widget, $delta) = @_;
    $canvas->yview('scroll', ($delta > 0 ? -3 : 3), 'units');
}, Tk::Ev('D') ]);
$mw->bind('<Next>',  sub { $canvas->yview('scroll',  1, 'pages') });
$mw->bind('<Prior>', sub { $canvas->yview('scroll', -1, 'pages') });
$mw->bind('<Home>',  sub { $canvas->yview('moveto', 0) });
$mw->bind('<End>',   sub { $canvas->yview('moveto', 1) });

my $c1 = $cols->Frame->pack(-side => 'left', -anchor => 'n', -padx => 6);
my $c2 = $cols->Frame->pack(-side => 'left', -anchor => 'n', -padx => 6);
my ($r1, $r2) = (0, 0);

# ---- Column one: a control for everything the camera reported ----
#
# The order below is the order they appear in, when the camera has them; any
# control the camera reports that is not in the list follows afterwards, so a
# camera with something unusual on it still gets a slider for it rather than
# having it quietly dropped.
my @preferred = qw(
    brightness contrast saturation hue gamma gain sharpness
    backlight_compensation white_balance_automatic white_balance_temperature
    power_line_frequency auto_exposure exposure_time_absolute exposure_absolute
    exposure_dynamic_framerate exposure_auto_priority
    focus_automatic_continuous focus_auto focus_absolute
    pan_absolute tilt_absolute zoom_absolute privacy led1_mode led1_frequency
);
my %in_preferred = map { $_ => 1 } @preferred;
my @order = (grep({ $cam{$_} } @preferred), sort grep { !$in_preferred{$_} } keys %cam);

$c1->Label(-text => '--- Camera Controls ---', -font => 'Helvetica 10 bold')
    ->grid(-row => $r1++, -column => 0, -columnspan => 3, -pady => 4);

my %bool_var;
for my $ctrl (@order) {
    my $info = $cam{$ctrl};
    my $start = defined $info->{default} ? $info->{default} : $info->{min};
    my $live  = get_ctrl($ctrl);
    $start = $live if defined $live;

    if ($info->{type} eq 'bool') {
        $bool_var{$ctrl} = $start ? 1 : 0;
        $c1->Checkbutton(
            -text     => $ctrl,
            -variable => \$bool_var{$ctrl},
            -command  => sub { apply_ctrl($ctrl, $bool_var{$ctrl}); },
        )->grid(-row => $r1++, -column => 0, -columnspan => 3, -sticky => 'w', -padx => 3);
        next;
    }

    # menu controls are small integer ranges; a slider reads them well enough
    # and needs no table of names this program would have to keep up to date.
    $c1->Label(-text => $ctrl, -width => 26, -anchor => 'w')
        ->grid(-row => $r1, -column => 0, -sticky => 'w', -padx => 3);
    my $value_label = $c1->Label(-text => $start, -width => 7);
    $value_label->grid(-row => $r1, -column => 2, -padx => 2);
    $c1->Scale(
        -from => $info->{min}, -to => $info->{max},
        -orient => 'horizontal', -length => 190, -showvalue => 0,
        -command => sub {
            my ($v) = @_;
            $value_label->configure(-text => $v);
            apply_ctrl($ctrl, $v);
        },
    )->grid(-row => $r1, -column => 1)->set($start);
    $r1++;
}

# ---- Column two: presets, then the light meter ----

$c2->Label(-text => '--- Presets ---', -font => 'Helvetica 10 bold')
    ->grid(-row => $r2++, -column => 0, -columnspan => 2, -pady => 4);

my $preset_status = $c2->Label(-text => 'The engine clamps every value to this camera.',
    -anchor => 'w', -font => 'Helvetica 8', -wraplength => 300);

# Each one runs the same preset the scheduler runs at that time of day.
my @presets = (
    [ 'Night',      'night',      '#223', 'white' ],
    [ 'Night Mono', 'night-mono', '#001', 'white' ],
    [ 'Golden AM',  'golden-am',  '#e9a', 'black' ],
    [ 'Day',        'day',        '#cde', 'black' ],
    [ 'Bright Sun', 'bright-sun', '#ff9', 'black' ],
    [ 'Golden PM',  'golden-pm',  '#e85', 'black' ],
);
my $preset_frame = $c2->Frame->grid(-row => $r2++, -column => 0, -columnspan => 2);
my $col = 0;
for my $p (@presets) {
    my ($label, $name, $bg, $fg) = @$p;
    $preset_frame->Button(
        -text => $label, -bg => $bg, -fg => $fg, -width => 10,
        -command => sub {
            $preset_status->configure(-text => "Applying $name...");
            $mw->update;
            my $ok = run_preset($name);
            # The preset just changed the light, so the autofocus needs a fresh
            # search on it; the engine does this too, and doing it twice costs
            # nothing but a third of a second.
            meter_refocus($device);
            $preset_status->configure(-text => $ok
                ? "Applied $name. The light meter will re-learn it as its baseline."
                : "Could not run $name - is webcam-preset.pl next to this file?");
        },
    )->grid(-row => int($col / 3), -column => $col % 3, -padx => 3, -pady => 3);
    $col++;
}
$preset_status->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);

# ---- The light meter panel ----

my $meter_on = 1;
my $meter_status;
my $meter_detail;

meter_learn_ranges($device);
my $snap_setup = meter_prepare_snapshots();

$c2->Label(-text => '--- Automatic Light Adjustment (24/7) ---', -font => 'Helvetica 10 bold')
    ->grid(-row => $r2++, -column => 0, -columnspan => 2, -pady => 5);

$c2->Label(
    -text => "Corrects whichever preset is in force by measuring the picture\n"
           . "itself every 5 seconds, so it is neither too bright nor too dark.\n"
           . "It does not replace the presets or the scheduler - both keep\n"
           . "working, and this trims what they set. Press any preset and it\n"
           . "re-learns that preset as its new starting point. Colour is kept\n"
           . "day and night, with less of it at night.",
    -justify => 'left', -anchor => 'w', -font => 'Helvetica 8', -wraplength => 310,
)->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);

$c2->Label(-text => meter_range_report(), -anchor => 'w', -font => 'Helvetica 8',
    -wraplength => 310, -fg => '#036')
    ->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);

my $snap_frame = $c2->Frame->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);
$snap_frame->Label(-text => 'Snapshots:', -font => 'Helvetica 8')->pack(-side => 'left');
$snap_frame->Entry(-textvariable => \$snap_src, -width => 36, -font => 'Helvetica 8')->pack(-side => 'left');

my $meter_btns = $c2->Frame->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6, -pady => 2);
$meter_btns->Checkbutton(
    -text     => 'Adjust the light automatically',
    -variable => \$meter_on,
    -font     => 'Helvetica 8',
    -command  => sub {
        %meter_wrote = ();      # forces a fresh baseline on the next pass
        @meter_means = ();
        $meter_dir   = 0;
        $meter_status->configure(-text => $meter_on
            ? 'Automatic light adjustment on' : 'Automatic light adjustment off');
    },
)->pack(-side => 'left');

$meter_btns->Button(-text => 'Clear trim', -font => 'Helvetica 8', -command => sub {
    meter_apply_trim($device, 0);
    @meter_means = ();
    $meter_dir   = 0;
    $meter_hold  = $METER_SETTLE;
    $meter_detail->configure(-text => 'Trim cleared - back to the preset as written');
})->pack(-side => 'left', -padx => 4);

$meter_btns->Button(-text => 'Snapshot + test', -font => 'Helvetica 8', -command => sub {
    capture_snapshot($device);
    my $f = meter_snapshot();
    my ($mean, $hot, $cold) = meter_measure($f);
    $meter_detail->configure(-text => defined $mean
        ? sprintf('Measured %s: mean %d, white %.1f%%, black %.0f%%', $f, $mean, $hot * 100, $cold * 100)
        : 'No snapshot found'
          . (length $snap_capture_note ? " - $snap_capture_note" : ''));
})->pack(-side => 'left', -padx => 4);

my $target_frame = $c2->Frame->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);
$target_frame->Label(-text => 'Target brightness', -font => 'Helvetica 8')->pack(-side => 'left');
$target_frame->Scale(-from => 60, -to => 160, -orient => 'horizontal', -length => 150,
    -variable => \$mean_target, -showvalue => 1, -font => 'Helvetica 8')->pack(-side => 'left');

$meter_status = $c2->Label(-text => 'Automatic light adjustment starting', -anchor => 'w',
    -font => 'Helvetica 8', -wraplength => 310);
$meter_status->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);
$meter_detail = $c2->Label(-text => $snap_setup, -anchor => 'w', -font => 'Helvetica 8', -wraplength => 310);
$meter_detail->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);

# Where to read back what went wrong hours ago, since the lines above only ever
# show the latest thing.
$c2->Label(-text => 'Error log: ' . meter_log_path(), -anchor => 'w',
    -font => 'Helvetica 8', -wraplength => 310, -fg => '#555')
    ->grid(-row => $r2++, -column => 0, -columnspan => 2, -sticky => 'w', -padx => 6);

# meter_pass only does work every 30 seconds and returns nothing in between, so
# checking every 2 keeps the window responsive and costs nothing.
sub meter_tick {
    if ($meter_on) {
        my $line = meter_pass($device);
        $meter_status->configure(-text => $line) if defined $line;
    }
    $mw->after(5000, \&meter_tick);
}
$mw->after(6000, \&meter_tick);


# Open at the size the controls ask for, but never taller than the screen will
# take - which is the whole reason for the scrollbars.
$mw->update;
my $want_w = $cols->reqwidth;
my $want_h = $cols->reqheight;
my $max_h  = int($mw->screenheight * 0.88) - term_height();
$max_h = 200 if $max_h < 200;
my $max_w  = int($mw->screenwidth  * 0.98);
$want_w = $max_w if $want_w > $max_w;
$canvas->configure(
    -width  => $want_w,
    -height => ($want_h > $max_h ? $max_h : $want_h),
    -scrollregion => [ $canvas->bbox('all') ],
);

# Take the scheduler with us. Without this the child process in the terminal
# would outlive the window that started it.
$mw->protocol('WM_DELETE_WINDOW', sub { term_stop(); $mw->destroy });

MainLoop;
