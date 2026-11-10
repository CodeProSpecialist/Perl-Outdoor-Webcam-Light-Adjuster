#!/usr/bin/env perl
use strict;
use warnings;

use utf8;
use strict;
use warnings;
use DateTime;
use DateTime::Duration;
use DateTime::Event::Sunrise;
use Time::Piece;
use Time::Seconds;
use File::Basename ();
use Cwd ();

# Run one of the preset wrapper scripts.
#
# The presets used to be fired two different ways, one after the other:
#
#     do './night-sharp-webcam.pl';
#     system('perl ~/night-sharp-webcam.pl; ');
#
# Both are broken, in different ways.
#
# "do FILE" runs the file inside THIS process. Every wrapper script ends in
# exit(), so the exit took the scheduler down with it. Started from its own
# directory - the obvious way to start it - this scheduler died the first time
# a preset fired. At sunset that happens on the day preset a few lines before
# night, so the camera never reached the night settings at all; the program
# simply vanished. "do" also silently does nothing when the working directory
# is not the one holding the scripts, which is the case under cron.
#
# The system('perl ~/...') line was there to cover that, but it only works if
# the scripts have been copied into the home directory, and it ignores the
# exit status, so a failure looked exactly like a success.
#
# This runs the script in a child process, where its exit() ends the child and
# not the scheduler, finds it wherever it actually lives, uses the same perl
# this scheduler is running under, and complains when it fails.
sub run_preset {
    my ($script) = @_;
    my @dirs = (File::Basename::dirname(Cwd::abs_path($0)),
                home_dir(),
                Cwd::getcwd());
    for my $dir (@dirs) {
        my $path = "$dir/$script";
        next unless -r $path;
        my $rc = system($^X, $path);
        warn "$script exited " . ($rc >> 8) . "\n" if $rc != 0;
        return $rc == 0;
    }
    warn "$script not found next to $0, in \$HOME, or in " . Cwd::getcwd() . "\n";
    return 0;
}

#use feature qw/say/;

#use POSIX qw(strftime tzset);

#use Date::Simple qw(date);

# use Date::Calc qw(Add_Delta_DHMS);

# use Date::Manip::Date;  


 
# 
 # I found out that this perl code works 100% correctly with: 
#print "     Sunset time with 1 hour added: ", $minutes_after_sunset_C->strftime("%H:%M:%S"),"\n" ; 
# if ( $timepiece->hms eq $minutes_after_sunset_C->strftime("%H:%M:%S") ) {  
# }
#my $minutes_after_sunset_C = $sunset_dt - DateTime::Duration->new( minutes => 490 );
 #####
 
 #################################################
# here are the global variables to be declared outside of the main loop 
# to reduce processor usage and to reduce network downloads of data:  
 
 




# Location for Kansas 
my $lat = "+39.403889"; ## N or S (+)
my $lon = "-94.181667"; ## E or W (-)


# Current date
my $now = DateTime->now;

$now->set_time_zone('America/Chicago'); 

my $fmt = "%H:%M:%S";

 
# set perl cpan datetime time zone variable during daylight savings time hour changes. CDT or CST
my $PERL_DATETIME_DEFAULT_TZ = ('CST') ;





# Get sunrise and sunset data
my $sun = DateTime::Event::Sunrise->new (
longitude => $lon,
latitude => $lat,
precise => 1
);

##### Sunrise and sunset: online first, then the shared file #####
#
# All three webcam programs now get the times the same way:
#   1. fetch today's times from api.sunrise-sunset.org (free, no key)
#   2. if there is no internet, use the newest times saved in the text file
#   3. if there is no file either, work them out locally with
#      DateTime::Event::Sunrise, which needs no network
#
# Every successful fetch or calculation is written to the shared file, so the
# ONN settings GUI and the Python program can fall back on it as well.

# Where this user's home directory is.
#
# $HOME is right nearly always, but it is not set under some cron and systemd
# setups, which is exactly where this runs unattended - so the password
# database is the fallback, and it answers for whichever user is actually
# running the program. Nothing here has a user name written into it.
sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME} && -d $ENV{HOME};
    my $pw = eval { (getpwuid($<))[7] };
    return $pw if defined $pw && length $pw && -d $pw;
    return '.';
}

my $sun_file = home_dir() . '/.webcam-sun-times.conf';
my $sun_tzid = 'America/Chicago';

sub save_sun_file {
    my ($sunrise_hhmm, $sunset_hhmm, $source) = @_;
    open(my $fh, '>', $sun_file) or return 0;
    my $t = localtime;
    printf $fh "# webcam sunrise/sunset times - written %s\n", $t->strftime("%Y-%m-%d %H:%M");
    print $fh "sunrise=$sunrise_hhmm\n";
    print $fh "sunset=$sunset_hhmm\n";
    print $fh "lat=$lat\n";
    print $fh "lng=$lon\n";
    print $fh "source=$source\n";
    close($fh);
    return 1;
}

# Returns (sunrise_hhmm, sunset_hhmm, written_text) or an empty list.
sub load_sun_file {
    return () unless -r $sun_file;
    open(my $fh, '<', $sun_file) or return ();
    my (%kv, $written);
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /^#.*written\s+(.+)$/) { $written = $1; next; }
        next if $line =~ /^\s*(#|$)/;
        my ($k, $v) = split(/=/, $line, 2);
        next unless defined $k && defined $v;
        $k =~ s/\s+//g;
        $v =~ s/^\s+|\s+$//g;
        $kv{$k} = $v;
    }
    close($fh);
    for my $key (qw(sunrise sunset)) {
        return () unless defined $kv{$key} && $kv{$key} =~ /^\d{1,2}:\d{2}$/;
    }
    return ($kv{sunrise}, $kv{sunset}, $written || 'an unknown date');
}

# formatted=0 returns ISO timestamps already converted to the given time zone,
# so the local clock times can be read straight out of the string.
sub fetch_sun_online {
    return () unless system("command -v curl >/dev/null 2>&1") == 0;
    my $url = sprintf(
        'https://api.sunrise-sunset.org/json?lat=%s&lng=%s&tzid=%s&formatted=0',
        $lat, $lon, $sun_tzid);
    my $json = `curl -s --max-time 12 '$url' 2>/dev/null`;
    return () unless defined $json && length $json;
    return () unless $json =~ /"status"\s*:\s*"OK"/;
    my ($srh, $srm) = $json =~ /"sunrise"\s*:\s*"[^"]*?T(\d{2}):(\d{2})/;
    my ($ssh, $ssm) = $json =~ /"sunset"\s*:\s*"[^"]*?T(\d{2}):(\d{2})/;
    return () unless defined $srh && defined $ssh;
    return ("$srh:$srm", "$ssh:$ssm");
}

# Build today's DateTime for an HH:MM string.
sub dt_for_hhmm {
    my ($hhmm) = @_;
    my ($h, $m) = $hhmm =~ /^(\d{1,2}):(\d{2})$/ or return undef;
    my $t = localtime;
    return DateTime->new(
        year => $t->year, month => $t->mon, day => $t->mday,
        hour => $h, minute => $m, second => 0,
        time_zone => $sun_tzid,
    );
}

# Today's sunrise and sunset as two DateTime objects, by the order above.
# Returns an empty list only if all three sources fail.
sub todays_sun_dts {
    my ($sr, $ss) = fetch_sun_online();
    if (defined $sr) {
        save_sun_file($sr, $ss, 'online');
        return (dt_for_hhmm($sr), dt_for_hhmm($ss));
    }

    my @saved = load_sun_file();
    if (@saved) {
        print "No internet for the sunrise/sunset lookup; using the times saved $saved[2]\n";
        return (dt_for_hhmm($saved[0]), dt_for_hhmm($saved[1]));
    }

    my ($a, $b);
    if (eval { $a = $sun->sunrise_datetime($now); $b = $sun->sunset_datetime($now); 1 }) {
        print "No internet and no saved times; worked them out locally instead.\n";
        save_sun_file($a->strftime("%H:%M"), $b->strftime("%H:%M"), 'calculated');
        return ($a, $b);
    }
    return ();
}



my ($sr_src, $ss_src) = todays_sun_dts();
die "Could not get sunrise and sunset from the internet, the saved file, or a "
  . "local calculation.\n" unless defined $sr_src && defined $ss_src;

my $sunrise = $sr_src->strftime("%H:%M:%S");

my $sunset = $ss_src->strftime("%H:%M:%S");

################################ adding time and subtracting time code  ######################################
##############################
##### calculate for sunrise  #####
 
my $sunrise_dt = DateTime->new(
    year       => $sr_src->strftime("%Y"),
    month      => $sr_src->strftime("%m"),
    day        => $sr_src->strftime("%d"),
    hour       => $sr_src->strftime("%H"),
    minute     => $sr_src->strftime("%M"),
    second     => $sr_src->strftime("%S"),
    time_zone  => 'America/Chicago',
);

# Remember that the "say" command will also print something with automatic spacing.  
#say $dt;
 
##############################
##### calculate for sunset  #####
 
my $sunset_dt = DateTime->new(
    year       => $ss_src->strftime("%Y"),
    month      => $ss_src->strftime("%m"),
    day        => $ss_src->strftime("%d"),
    hour       => $ss_src->strftime("%H"),
    minute     => $ss_src->strftime("%M"),
    second     => $ss_src->strftime("%S"),
    time_zone  => 'America/Chicago',
);

# Remember that the "say" command will also print something with automatic spacing.  
#say $dt;
 

#my $year_before = $sunrise_dt - DateTime::Duration->new( years => 1 );

# say $year_before->strftime("%Y");


############################


#my $minutes_before_sunrise = $sunrise_dt - DateTime::Duration->new( minutes => 15 );
#print "5 Minutes Before sunrise " , $minutes_before_sunrise->strftime("%H:%M:%S"),"\n" ;
 
#my $minutes_after_sunrise = $sunrise_dt + DateTime::Duration->new( minutes => 18 );
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;
 
 
 
 
#my $year_before = $sunrise_dt - DateTime::Duration->new( years => 1 );

# say $year_before->strftime("%Y");


############################




##### debug code here to adjust minutes to current localtime for right now. I found out that this perl code works 100% correctly with: 
#print "     Sunset time with 1 hour added: ", $minutes_after_sunset_C->strftime("%H:%M:%S"),"\n" ; 
# if ( $timepiece->hms eq $minutes_after_sunset_C->strftime("%H:%M:%S") ) {  
# }
#my $minutes_after_sunset_C = $sunset_dt - DateTime::Duration->new( minutes => 490 );
 #####

#print "This is working without printing the time to reduce processor usage.\n";



##### Place 100% of all time math calculations here 
##### for the computer to not have to do every single 
##### math calculation for every second of the 24 hour day. 


my $math_minutes_before_sunrise_A = $sunrise_dt - DateTime::Duration->new( minutes => 7);

my $minutes_before_sunrise_A = $math_minutes_before_sunrise_A ;
#print "5 Minutes Before sunrise " , $minutes_before_sunrise->strftime("%H:%M:%S"),"\n" ;

my $math_minutes_after_sunrise_B = $sunrise_dt + DateTime::Duration->new( minutes => 26 );

my $minutes_after_sunrise_B = $math_minutes_after_sunrise_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

my $math_minutes_after_sunrise_C = $sunrise_dt + DateTime::Duration->new( minutes => 122 );

my $minutes_after_sunrise_C = $math_minutes_after_sunrise_C ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

my $math_minutes_before_sunset_B = $sunset_dt - DateTime::Duration->new( minutes => 39 );

my $minutes_before_sunset_B = $math_minutes_before_sunset_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;



my $math_minutes_before_sunset_A = $sunset_dt - DateTime::Duration->new( minutes => 10 );

my $minutes_before_sunset_A = $math_minutes_before_sunset_A ;
#print "5 Minutes Before sunrise " , $minutes_before_sunrise->strftime("%H:%M:%S"),"\n" ;
 
my $math_minutes_after_sunset_B = $sunset_dt + DateTime::Duration->new( minutes => 14 );

my $minutes_after_sunset_B = $math_minutes_after_sunset_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

my $math_minutes_after_sunset_C = $sunset_dt + DateTime::Duration->new( minutes => 30 );

my $minutes_after_sunset_C = $math_minutes_after_sunset_C ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;



##### Place 100% of all time math calculations here 
##### for the computer to not have to do every single 
##### math calculation for every second of the 24 hour day. 



########
########## below is the alarm to run code for night webcam ################

# Which day the 04:46 time refresh last ran on, so that matching the minute
# rather than one exact second cannot run it twice.
my $last_refresh_yday = -1;

# The camera these corrections are sent to. The preset wrapper scripts take
# the same environment variable, so setting WEBCAM_DEVICE once covers both.
my $meter_device = $ENV{WEBCAM_DEVICE} || '/dev/video0';

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
my $SNAP_DEFAULT = meter_home_dir()
    . '/Pictures/onn-webcam/program-snapshots-for-auto-adjust-picture';

my $snap_src = $ENV{WEBCAM_SNAPSHOT} || $SNAP_DEFAULT;
my $snap_tmp = '/tmp/.webcam-meter.jpg';

# Directories worth looking in when nothing is configured.
my @snap_guess = (
    $SNAP_DEFAULT,
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
my $METER_EVERY  = 5;
my $METER_SETTLE = 2;

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

# The startup probe: ask this camera what its controls can actually do before
# the schedule starts, and say what came back. Anything the camera does not
# answer for falls back to the ranges these programs already used.
meter_learn_ranges($meter_device);
print meter_range_report(), "\n";
print meter_prepare_snapshots(), "\n";
print "light meter: errors are logged to ", meter_log_path(), "\n";

 for (;;) { # I prefer using "for for infinite loops


# localtime creates a Time::Piece object
my $timepiece = localtime;

##### for code debugging and experimenting, I will modify localtime 


# sleep 0.9 seconds to reduce processor usage 
 #sleep(0.4);  # ( Never change this from 0.9 to 1 or else seconds will be skipped. )
 

# below line is only for debugging this exact part of code. 
# print "strftime","\n";

#stop printing the time to use less processor percentage. 
# do this by commenting out the print command below:

 print ".....working every 1 second.  " , $timepiece->strftime("%A, %B %d, %Y, %H:%M:%S") ,"\n";

# \r will reprint the text line on the same text line 
# to allow the command line to look like a clock:
print "Sunrise time: ", $sunrise, "     Sunset time: ", $sunset, "\n";
# print "I need to add 18 minutes to Sunset time and I subtract 18 minutes from Sunrise time.\n";


print "     Early Sunrise time with 7 minutes subtracted: ", $minutes_before_sunrise_A->strftime("%H:%M:%S"),"\n" ; 




print "     Sunrise time with 26 minutes added: " , $minutes_after_sunrise_B->strftime("%H:%M:%S"),"\n" ; 

print "     Begin Bright Sunlight Sunrise time with 122 minutes added: " , $minutes_after_sunrise_C->strftime("%H:%M:%S"),"\n" ; 

print "     End Bright Sunlight Sunrise time with 39 minutes subtracted: " , $minutes_before_sunset_B->strftime("%H:%M:%S"),"\n" ; 

print "     Pre-Sunset time with 10 minutes subtracted in memory is: ", $minutes_before_sunset_A->strftime("%H:%M:%S"),"\n" ; 



print "     Sunset time with 14 minutes added in memory is: ", $minutes_after_sunset_B->strftime("%H:%M:%S"),"\n" ; 




print "     Sunset time with 30 minutes added: ", $minutes_after_sunset_C->strftime("%H:%M:%S") , "\n" ;

print "Current localtime Time Zone: " , $now->strftime("%Z")  , "  updated on: " , $now->strftime("%A, %B %d, %Y, %H:%M:%S") , "\n" ;

print "Current Sunrise Time Zone: " , $sunrise_dt->strftime("%Z")  , "  updated on: " , $now->strftime("%A, %B %d, %Y, %H:%M:%S") , "\n" ;

print "Current Sunset Time Zone: " , $sunset_dt->strftime("%Z")   , "  updated on: " , $now->strftime("%A, %B %d, %Y, %H:%M:%S") , "\n" ;


##### only clear the screen after printing time information on the screen. ##### 

# sleep 0.8 to 0.7 seconds to reduce processor usage 
 #sleep(0.8);  # ( Never change this from 0.8 to 1 or else seconds will be skipped. )
sleep(1) ;

# One pass of the automatic light adjustment. It returns straight away except
# every 5 seconds, and prints only when it has something to say, so the clock
# display above is not buried.
{
    my $meter_line = meter_pass($meter_device);
    print $meter_line, "\n" if defined $meter_line;
}

# clear the screen every 0.79 second:
# #for ( sleep(0.79) ){

##system('clear;'); 

##};
 #system('clear;');  # clear does not erase text, clear skips   
#  lines. 
# print to skip 10 lines per second. This is faster. 
# print "\n" , "\n" , "\n" , "\n" , "\n" , "\n" , "\n" , "\n" , "\n" , "\n" ; 


# print "\r", "The current time is:", $timepiece ;
# I need to declare time piece object before strftime




########################################################################################################################

##### Pre-Sunset Webcam code is here #####

if ( $timepiece->hms eq $minutes_before_sunset_A->strftime("%H:%M:%S") ) {

# remember that night = "17:36:00"
# remember that day = "07:23:00"


sleep(1);

print "The Pre-Sunset webcam settings are correctly working right now." , "\n";

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command 
run_preset('pre-sunset-sharp-webcam.pl');

sleep(1); 
};



###########################################################
# I could also simply look at $time

##### night code is here #####
if ( $timepiece->hms eq $minutes_after_sunset_B->strftime("%H:%M:%S") ) {

# remember that night = "17:36:00"
# remember that day = "07:23:00"


sleep(1);

print "The night sharp webcam settings are correctly working right now.\n";


run_preset('day-sharp-webcam.pl');

sleep(5);

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command
run_preset('night-sharp-webcam.pl');


sleep(1);
};




########## below is the code for day webcam #############################################


# I could also simply look at $time
##### day #####
if ( $timepiece->hms eq $minutes_before_sunrise_A->strftime("%H:%M:%S") ) {

# remember that night = "21:06:00"
# remember that day = "07:23:00"


sleep(1);

print "The Golden Morning webcam settings are correctly working right now.\n";

##### golden morning: low warm sun just after sunrise
run_preset('post-sunrise-sharp-webcam.pl');

sleep(1);
};





########### 2nd day webcam command to sharpen the vision in the daylight:


# I could also simply look at $time
##### 2nd day webcam command #####


# I could also simply look at $time
##### day #####
if ( $timepiece->hms eq $minutes_after_sunrise_B->strftime("%H:%M:%S") ) {

# remember that night = "21:06:00"
# remember that day = "07:23:00"


sleep(1);

print "The Sunrise, brighter, Daytime webcam settings are correctly working right now.\n";


# Bounce through night before settling on day. This block always did that, and
# it is kept deliberately: sending the opposite preset first shakes the camera
# out of whatever state it has drifted into overnight, so the day settings land
# on a sensor that has actually been reset rather than being merged into the
# long night exposure. The same bounce happens the other way round at sunset.
run_preset('night-sharp-webcam.pl');

sleep(3);

run_preset('day-sharp-webcam.pl');

};




########## below is the code for day afternoon bright sun webcam #############################################


# I could also simply look at $time
##### day #####
if ( $timepiece->hms eq $minutes_after_sunrise_C->strftime("%H:%M:%S") ) {


# This is the command for the afternoon bright sun 
# from 14:43 until 16:29 on a January day. 

#     bright-sun-sharp-webcam.pl 

sleep(1);

print "The Afternoon bright sun webcam settings are correctly working right now.\n";

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command 
run_preset('bright-sun-sharp-webcam.pl');

sleep(1); 
};




########### The daytime webcam command after the bright sun is not bright. 


##### day #####
if ( $timepiece->hms eq $minutes_before_sunset_B->strftime("%H:%M:%S") ) {

# remember that night = "21:06:00"
# remember that day = "07:23:00"


sleep(1);

print "The Daytime webcam settings are correctly working right now.\n";


##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command
sleep(1);

run_preset('day-sharp-webcam.pl');


# sleep(1);

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command

# do './day-sharp-webcam.pl'  ;

};






########### 2nd night webcam command to sharpen the vision in the dark:

##### 2nd night webcam command #####
if ( $timepiece->hms eq $minutes_after_sunset_C->strftime("%H:%M:%S") ) {

# remember that night = "18:05:00"



sleep(1);

print "The night sharp webcam settings are correctly working right now.\n";
sleep(1); 

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command
run_preset('night-sharp-webcam.pl');


};

###########  below is code to update sunrise / sunset / localtime 
##### times every single day and to clear the terminal text. 


###########################################################
# I could also simply look at $time

##### night code is here #####
if ( $timepiece->strftime("%H:%M") eq "04:46"
     && $timepiece->yday != $last_refresh_yday ) {

## 04:46 is the daily time refresh in all three webcam programs.
## Matching the minute rather than one exact second, because this loop can
## skip a second and then the refresh would not run at all that day. The
## yday guard keeps it to once per day.
## I remember that daylight savings = 2:00am

$last_refresh_yday = $timepiece->yday;

sleep(1);

 system('reset; ');

#######  reset and clear all necessary variables 


$timepiece = localtime ; 

$now = localtime ;

# $sun is deliberately left alone: todays_sun_dts needs it for the local
# fallback when there is no internet and no saved file.
$sunrise = localtime ;

$sunset = localtime ;

$sunrise_dt = localtime ;

$sunset_dt = localtime ; 

print "The time update settings are correctly working right now.\n";

sleep(1); 


#######
$timepiece = localtime;

# Location for Kansas 
my $lat = "+39.403889"; ## N or S (+)
my $lon = "-94.181667"; ## E or W (-)

# Current date
 $now = DateTime->now;

$now->set_time_zone('America/Chicago');



# Get sunrise and sunset data
 $sun = DateTime::Event::Sunrise->new (
longitude => $lon,
latitude => $lat,
precise => 1
);


# Online first, then the saved file, then a local calculation. If all three
# fail, yesterday's times stay in use rather than being wiped.
 my ($sr_new, $ss_new) = todays_sun_dts();
 if (defined $sr_new && defined $ss_new) {
 ($sr_src, $ss_src) = ($sr_new, $ss_new);

 $sunrise = $sr_src->strftime("%H:%M:%S");

 $sunset = $ss_src->strftime("%H:%M:%S");

################################ adding time and subtracting time code  ######################################
##############################
##### calculate for sunrise  #####
 
 $sunrise_dt = DateTime->new(
    year       => $sr_src->strftime("%Y"),
    month      => $sr_src->strftime("%m"),
    day        => $sr_src->strftime("%d"),
    hour       => $sr_src->strftime("%H"),
    minute     => $sr_src->strftime("%M"),
    second     => $sr_src->strftime("%S"),
    time_zone  => 'America/Chicago',
);

# Remember that the "say" command will also print something with automatic spacing.  
#say $dt;
 
##############################
##### calculate for sunset  #####
 
 $sunset_dt = DateTime->new(
    year       => $ss_src->strftime("%Y"),
    month      => $ss_src->strftime("%m"),
    day        => $ss_src->strftime("%d"),
    hour       => $ss_src->strftime("%H"),
    minute     => $ss_src->strftime("%M"),
    second     => $ss_src->strftime("%S"),
    time_zone  => 'America/Chicago',
);


##### The code below will update the new math time calculations 
##### after the sunrise and sunset times are changed. 


$math_minutes_before_sunrise_A = $sunrise_dt - DateTime::Duration->new( minutes => 7);

 $minutes_before_sunrise_A = $math_minutes_before_sunrise_A ;
#print "5 Minutes Before sunrise " , $minutes_before_sunrise->strftime("%H:%M:%S"),"\n" ;

 $math_minutes_after_sunrise_B = $sunrise_dt + DateTime::Duration->new( minutes => 26 );

 $minutes_after_sunrise_B = $math_minutes_after_sunrise_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

 $math_minutes_after_sunrise_C = $sunrise_dt + DateTime::Duration->new( minutes => 122 );

 $minutes_after_sunrise_C = $math_minutes_after_sunrise_C ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

 $math_minutes_before_sunset_B = $sunset_dt - DateTime::Duration->new( minutes => 39 );

 $minutes_before_sunset_B = $math_minutes_before_sunset_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;



 $math_minutes_before_sunset_A = $sunset_dt - DateTime::Duration->new( minutes => 10 );

 $minutes_before_sunset_A = $math_minutes_before_sunset_A ;
#print "5 Minutes Before sunrise " , $minutes_before_sunrise->strftime("%H:%M:%S"),"\n" ;
 
 $math_minutes_after_sunset_B = $sunset_dt + DateTime::Duration->new( minutes => 14 );

 $minutes_after_sunset_B = $math_minutes_after_sunset_B ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;

 $math_minutes_after_sunset_C = $sunset_dt + DateTime::Duration->new( minutes => 30 );

 $minutes_after_sunset_C = $math_minutes_after_sunset_C ;
#print "5 Minutes after sunrise " , $minutes_after_sunrise->strftime("%H:%M:%S"),"\n" ;


##### The code above will update the new math time calculations 
##### after the sunrise and sunset times are changed. 

# print "The time update settings are correctly working right now.\n";

 } else {
     print "Could not refresh the times from any source; keeping yesterday's.\n";
 }

# clear the text in the terminal screen
 system('reset; ');

};


  





}; # <- the main loop bracket
print "This message is only displayed when the perl script exited the repeating clock loop and ended the perl program.";

return 0;
 
 
