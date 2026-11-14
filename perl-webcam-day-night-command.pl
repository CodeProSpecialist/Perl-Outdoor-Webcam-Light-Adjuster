#!/usr/bin/env perl
use strict;
use warnings;

use utf8;
use strict;
use warnings;
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
        WebcamBootstrap::ensure(qw(
            DateTime
            DateTime::Duration
            DateTime::Event::Sunrise
        ));
        # The python side too - this is the program that actually runs the
        # correction, so OpenCV and TensorFlow being installed matters here
        # more than anywhere. Every step is printed; under cron there is no
        # terminal to ask on, so it prints the plan and carries on unless
        # WEBCAM_AUTO_INSTALL=1 says to go ahead.
        WebcamBootstrap::ensure_python_stack();
        last;
    }
}

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

# ---- Keeping time ----
#
# Everything here is driven by the clock: the sunrise and sunset offsets, the
# 04:46 refresh, which preset belongs to this minute. A computer whose clock
# has drifted applies the night preset in daylight and nobody notices until
# the recording is useless.
#
# So the real time is fetched at startup and once a day after that, and the
# difference between it and this machine's clock is kept as an offset. Every
# decision in these programs goes through corrected_time() rather than the
# system clock directly.
#
# The system clock itself is NOT changed. That needs root, and a camera
# program is no business asking for it - Ubuntu already runs
# systemd-timesyncd, and if this reports a large offset for days on end, that
# is the thing to look at (`timedatectl status`) rather than something for
# this program to override.
#
# Being offline is not a failure here: the fetch simply does not answer, the
# previous offset stays, and the programs carry on with the system clock as
# they always did. The fetch is also how "are we connected" is answered - no
# separate check, because a check that passes while the time server is
# unreachable would tell us nothing useful.

use Time::Local ();

my $TIME_REFRESH = 24 * 3600;       # once a day
my $time_offset  = 0;               # seconds to add to this machine's clock
my $time_how     = 'not checked yet';
my $time_last_try = 0;

my %MONTH_NUM = (
    Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4,  Jun => 5,
    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);

# "Tue, 10 Nov 2026 17:15:52 GMT" -> epoch seconds.
sub parse_http_date {
    my ($text) = @_;
    return undef unless defined $text;
    return undef unless $text =~ /(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})/;
    my ($day, $mon, $year, $hh, $mm, $ss) = ($1, $2, $3, $4, $5, $6);
    my $month = $MONTH_NUM{$mon};
    return undef unless defined $month;
    my $epoch = eval { Time::Local::timegm($ss, $mm, $hh, $day, $month, $year) };
    return $epoch;
}

# What time the internet thinks it is, in epoch seconds, or undef when there
# is no answer - which is also what being offline looks like.
#
# The Date header of any HTTPS response is the first choice: every web server
# sends one, it needs no API and no key, and it cannot be rate limited away.
# Two hosts, in case one is unreachable, then a time service as a third.
sub fetch_network_time {
    return undef unless system('command -v curl >/dev/null 2>&1') == 0;

    for my $host ('https://www.google.com', 'https://www.cloudflare.com') {
        my $head = `curl -sS -I -m 6 $host 2>/dev/null`;
        next unless defined $head && length $head;
        for my $line (split /\n/, $head) {
            next unless $line =~ /^date:\s*(.+?)\s*$/i;
            my $epoch = parse_http_date($1);
            return $epoch if defined $epoch;
        }
    }

    my $json = `curl -sS -m 6 'https://timeapi.io/api/Time/current/zone?timeZone=UTC' 2>/dev/null`;
    if (defined $json && $json =~ /"year"\s*:\s*(\d+)/) {
        my $year = $1;
        my ($mon)  = $json =~ /"month"\s*:\s*(\d+)/;
        my ($day)  = $json =~ /"day"\s*:\s*(\d+)/;
        my ($hour) = $json =~ /"hour"\s*:\s*(\d+)/;
        my ($min)  = $json =~ /"minute"\s*:\s*(\d+)/;
        my ($sec)  = $json =~ /"seconds"\s*:\s*(\d+)/;
        if (defined $mon && defined $day && defined $hour && defined $min && defined $sec) {
            my $epoch = eval {
                Time::Local::timegm($sec, $min, $hour, $day, $mon - 1, $year);
            };
            return $epoch if defined $epoch;
        }
    }
    return undef;
}

# Fetch the real time and remember how far off this machine is. Returns the
# offset in seconds, or undef when there was no answer.
sub sync_network_time {
    $time_last_try = time();
    my $real = fetch_network_time();
    unless (defined $real) {
        $time_how = 'no answer from a time server - using this machine\'s clock';
        return undef;
    }

    my $was = $time_offset;
    $time_offset = $real - time();
    $time_how = ($time_offset == 0)
        ? 'this machine\'s clock agrees with the time server'
        : sprintf('this machine\'s clock is %d seconds %s, corrected in this program',
                  abs($time_offset), ($time_offset > 0 ? 'slow' : 'fast'));

    # Worth a line in the log when it matters: a few seconds is nothing, half
    # a minute will start moving the preset changes about.
    if (abs($time_offset) >= 10 || abs($time_offset - $was) >= 10) {
        meter_log("time check: $time_how") if defined &meter_log;
    }
    return $time_offset;
}

# The time everything in these programs should use.
sub corrected_time { return time() + $time_offset; }

# Re-check once a day. Call it as often as you like; it does nothing until the
# day is up, so it can live inside a loop that runs every second.
sub time_check_due {
    return 0 if ($time_last_try && (time() - $time_last_try) < $TIME_REFRESH);
    sync_network_time();
    return 1;
}

sub time_status { return $time_how; }

# ---- Where this camera is ----
#
# The sunrise and sunset times depend on where you are, and nowhere in these
# programs is there a place written down any more. The location is worked out
# at startup, in this order, and the first answer wins:
#
#   1. WEBCAM_LAT and WEBCAM_LON in the environment, for a machine that should
#      not be guessing at all - a camera on a tower a county away from the
#      computer driving it, say.
#   2. The cached answer in ~/.webcam-location.conf, if it is less than a week
#      old. Nothing goes out to the network on an ordinary run.
#   3. An IP lookup, which gives the city the connection comes out of.
#   4. The last cached answer whatever its age, since a stale location beats
#      none at all - sunrise moves by about a minute a day, not an hour.
#
# The IP lookup is worth being plain about: it tells a third party (ipinfo.io,
# and ip-api.com if that one is not answering) this machine's IP address, and
# what comes back is where the internet connection surfaces, not where the
# camera is. On a VPN it is wrong by however far the VPN reaches. That is why
# the answer is cached, shown, and overridable - and if neither is wanted, set
# WEBCAM_LAT and WEBCAM_LON and no lookup is ever made.
#
# Accuracy only has to be rough. A tenth of a degree of latitude moves sunrise
# by well under a minute, and these presets switch on offsets of 7 to 122
# minutes, so a city-level answer is as good as a surveyed one here.

my $LOCATION_FILE = $ENV{WEBCAM_LOCATION_FILE}
    || (home_dir() . '/.webcam-location.conf');
my $LOCATION_MAX_AGE = 7 * 24 * 3600;      # a week, then look again

# The system's own idea of its time zone, which needs no network at all.
sub system_timezone {
    my $tz = `timedatectl show -p Timezone --value 2>/dev/null`;
    chomp $tz if defined $tz;
    return $tz if defined $tz && $tz =~ m{^[A-Za-z]+/};
    if (open(my $fh, '<', '/etc/timezone')) {
        my $line = <$fh>;
        close($fh);
        chomp $line if defined $line;
        return $line if defined $line && $line =~ m{^[A-Za-z]+/};
    }
    my $link = readlink('/etc/localtime');
    return $1 if defined $link && $link =~ m{zoneinfo/(\w+/[\w/+-]+)$};
    return 'UTC';
}

# The time zone the coordinates sit in, asked of a service that knows the
# zone map - not guessed from the system clock.
#
# This matters because the two are different things. The system zone is
# whatever this computer was set up with, and a camera reporting to a machine
# in another state, or a laptop carried across a zone line, would have the sun
# times worked out for the wrong one. The coordinates are where the camera is,
# so the zone that belongs to those coordinates is the right answer.
#
# Two services again, since free ones come and go. Whatever is found is cached
# with the location, so this is asked once a week at most.
sub timezone_for_coords {
    my ($la, $ln) = @_;
    return undef unless defined $la && defined $ln;
    return undef unless system('command -v curl >/dev/null 2>&1') == 0;

    my $url = "https://timeapi.io/api/TimeZone/coordinate?latitude=$la&longitude=$ln";
    my $json = `curl -s --max-time 6 '$url' 2>/dev/null`;
    return $1 if defined $json && $json =~ /"timeZone"\s*:\s*"([^"]+)"/;

    $url = "https://api.open-meteo.com/v1/forecast?latitude=$la&longitude=$ln"
         . "&timezone=auto&forecast_days=1";
    $json = `curl -s --max-time 6 '$url' 2>/dev/null`;
    return $1 if defined $json && $json =~ /"timezone"\s*:\s*"([^"]+)"/;

    return undef;
}

sub save_location {
    my ($la, $ln, $tz, $source) = @_;
    open(my $fh, '>', $LOCATION_FILE) or return 0;
    my @t = localtime();
    printf {$fh} "lat=%s\nlon=%s\ntz=%s\nsource=%s\nsaved=%04d-%02d-%02d %02d:%02d\n",
        $la, $ln, $tz, $source, $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1];
    close($fh);
    return 1;
}

# Returns (lat, lon, tz, source, age in seconds), or an empty list.
sub load_location {
    return () unless -f $LOCATION_FILE;
    open(my $fh, '<', $LOCATION_FILE) or return ();
    my %v;
    while (my $line = <$fh>) {
        $v{$1} = $2 if $line =~ /^(\w+)=(.*?)\s*$/;
    }
    close($fh);
    return () unless defined $v{lat} && defined $v{lon};
    my $age = time() - (stat($LOCATION_FILE))[9];
    return ($v{lat}, $v{lon}, ($v{tz} || system_timezone()),
            ($v{source} || 'saved'), $age);
}

# Ask where this connection comes out. Returns (lat, lon, tz) or nothing.
#
# Two services, because one of them is always rate limiting somebody. Short
# timeouts: this runs at startup and must never be what stops the program
# coming up.
sub lookup_location_online {
    return () unless system('command -v curl >/dev/null 2>&1') == 0;

    my $json = `curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null`;
    if (defined $json && $json =~ /"loc"\s*:\s*"(-?[\d.]+),(-?[\d.]+)"/) {
        my ($la, $ln) = ($1, $2);
        my ($tz) = $json =~ /"timezone"\s*:\s*"([^"]+)"/;
        return ($la, $ln, ($tz || system_timezone()));
    }

    $json = `curl -s --max-time 6 'http://ip-api.com/json/?fields=status,lat,lon,timezone' 2>/dev/null`;
    if (defined $json && $json =~ /"status"\s*:\s*"success"/) {
        my ($la) = $json =~ /"lat"\s*:\s*(-?[\d.]+)/;
        my ($ln) = $json =~ /"lon"\s*:\s*(-?[\d.]+)/;
        my ($tz) = $json =~ /"timezone"\s*:\s*"([^"]+)"/;
        return ($la, $ln, ($tz || system_timezone())) if defined $la && defined $ln;
    }
    return ();
}

# The whole order above, in one call. Returns (lat, lon, tz, how it was found).
sub detect_location {
    my (%opt) = @_;

    if (defined $ENV{WEBCAM_LAT} && defined $ENV{WEBCAM_LON}
        && length $ENV{WEBCAM_LAT} && length $ENV{WEBCAM_LON}) {
        my $tz = $ENV{WEBCAM_TZ}
              || timezone_for_coords($ENV{WEBCAM_LAT}, $ENV{WEBCAM_LON})
              || system_timezone();
        return ($ENV{WEBCAM_LAT}, $ENV{WEBCAM_LON}, $tz, 'WEBCAM_LAT and WEBCAM_LON');
    }

    my @saved = load_location();
    if (@saved && !$opt{force} && $saved[4] < $LOCATION_MAX_AGE) {
        my ($la, $ln, $tz) = @saved[0, 1, 2];
        # A settings file written before the zone was worked out from the
        # coordinates, or by hand without one, gets it filled in once.
        if (!defined $tz || !length $tz || $tz eq 'UTC') {
            my $better = timezone_for_coords($la, $ln);
            if ($better) {
                $tz = $better;
                save_location($la, $ln, $tz, $saved[3]);
            }
        }
        return ($la, $ln, $tz, 'the saved location');
    }

    my ($la, $ln, $tz_from_ip) = lookup_location_online();
    if (defined $la) {
        # The zone that belongs to these coordinates, falling back to the one
        # the IP lookup volunteered and then to the system's own.
        my $tz = timezone_for_coords($la, $ln) || $tz_from_ip || system_timezone();
        save_location($la, $ln, $tz, 'ip lookup');
        return ($la, $ln, $tz, 'an IP lookup');
    }

    # The lookup failed. A stale saved location beats none.
    return (@saved[0, 1, 2], 'the saved location, which could not be refreshed')
        if @saved;

    return (undef, undef, system_timezone(), 'nothing - no saved location and no lookup');
}

# Worked out at startup - no place is written down in this file.
my ($lat, $lon, $detected_tz, $location_how) = detect_location();
my $sun_tzid = $detected_tz || system_timezone();



# Current date
my $now = DateTime->from_epoch(epoch => corrected_time());

$now->set_time_zone($sun_tzid); 

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

my $sun_file = home_dir() . '/.webcam-sun-times.conf';

sub save_sun_file {
    my ($sunrise_hhmm, $sunset_hhmm, $source) = @_;
    open(my $fh, '>', $sun_file) or return 0;
    my $t = localtime(corrected_time());
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
    my $t = localtime(corrected_time());
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
        # The times came back for these coordinates, so the location they were
        # worked out for is worth keeping as the saved setting.
        save_location($lat, $lon, $sun_tzid, 'confirmed by the sun-times fetch');
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
    time_zone  => $sun_tzid,
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
    time_zone  => $sun_tzid,
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
# Every 10 seconds. The light at dusk moves faster than a half-minute check
# can follow, and looking is cheap: a mean and two clipping figures off a
# still the recorder already wrote, with nothing captured and the camera not
# touched. The trim is still rate-limited by the settle time and the dead
# band, so looking every 10 seconds means noticing sooner, not moving the
# controls oftener.
my $METER_EVERY  = 10;
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
# gain has lifted everything.
#
# Saturation used to be in here, coming down as the trim went up. It is out
# now, deliberately: the colour level a preset asks for is the colour level
# that is wanted, at every hour, and a meter quietly walking it down five
# steps into the night is the meter overruling the preset about how the
# picture should look. The colour wanted at night is set in the night preset
# itself, where it can be seen and changed. See %locked_ctrls below.
my %trim_rule = (
    gain                   =>  0.120,
    brightness             =>  0.025,
    contrast               =>  0.030,
    backlight_compensation =>  0.200,
);
my @trim_ctrls = sort keys %trim_rule;

# The controls this loop is not allowed to move, whatever the picture looks
# like.
#
# Saturation and hue belong to the preset outright: they decide what the
# colours *are*, not how bright the frame is, and no amount of metering the
# grey level is evidence about either. Gamma is the awkward one and gets a
# rule of its own - it does change brightness, which is exactly why it is
# tempting, and raising it is the cheapest-looking way to brighten a night
# frame. It is also the worst: gamma lifts the noise floor along with the
# shadows and flattens the midtones the number plate lives in, and it does it
# to the stream the recorder is writing rather than to a copy. So gamma may be
# left where the preset put it or pulled back DOWN from there, and never
# raised above it. The software correction, which works on copies of the
# stills and can be deleted and redone, is where a gamma lift belongs.
my @LOCKED_CTRLS = ('saturation', 'hue');
my $GAMMA_CTRL   = 'gamma';
my @locked_have  = ();       # which of them this camera actually has
my %locked_base  = ();       # and the values the preset gave them

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

# The manual focus control, read so that the preset's focus distance can be
# kept and gone back to.
my $FOCUS_ABS_CTRL = 'focus_absolute';
my $ctrl_focus_abs;          # the name, when this camera has it
my @focus_range;             # its range, for the drift window
my $focus_base;              # where the preset left the focus

# How far the focus may wander from where the preset left it before it is put
# back, as a fraction of the control's range. Twelve per cent is about a foot
# at the distance these cameras are aimed at: enough slack for the autofocus
# to find the edge of a car properly, not enough for it to give up and go
# hunting the fence behind it or the moth in front of it.
my $FOCUS_WINDOW = 0.12;

# How blurry the picture has to be before the autofocus is allowed to re-run.
#
# This is the variance of the Laplacian - the standard "is it in focus" number
# - taken on a half size grey copy. A sharp daylight frame from this camera
# runs in the hundreds; a frame that has lost focus runs in the low tens. The
# night threshold is lower because a correctly focused night frame is
# genuinely less detailed than a correctly focused day one, and judging night
# by the day number would have the autofocus hunting all night, which is the
# exact behaviour that puts a soft first few seconds into every recording.
my $BLUR_DAY   = 55.0;
my $BLUR_NIGHT = 22.0;
# The gain fraction where the easing off starts - the same knee the sharpness
# curve uses, repeated here because this is declared earlier in the file than
# that curve is.
my $BLUR_KNEE  = 0.50;
my $last_blur;               # the last reading, for the status line
my $lock_note = '';          # what the locked-on target did this pass

my $TRIM_MAX = 5;            # steps either side of whatever the preset set

# The presets that run from golden PM, through night, to golden AM. Across
# these the meter may brighten the picture or hold it, and may NOT darken it
# below what the preset set.
#
# Why: the light is falling or already gone, and the meter's own measurement
# is the thing that misleads it. A night frame with a security light in it
# reads as "too bright" on the mean and on the blown-white test, and the meter
# answers by trimming gain and brightness DOWN - which takes the car and the
# tarmac with it to tame a lamp that was never the subject. The trims then
# accumulate pass after pass and the live picture walks off into the dark.
#
# By day there is nothing wrong with trimming down: the sensor has range to
# spare and a blown frame really is worth taming. So the floor applies to
# these presets only; day and bright sun keep the full range either way.
my @DARK_PRESETS = qw(golden_pm night night_mono golden_am);

# Whether the preset in force is one of the falling-light ones.
sub meter_dark_preset {
    my $preset = eval { WebcamEnhance::current_preset() };
    return 0 unless defined $preset && length $preset;
    my $name = lc $preset;
    $name =~ s/[-\s]+/_/g;
    for my $dark (@DARK_PRESETS) {
        return 1 if $dark eq $name;
    }
    return 0;
}

# How far below the preset's own values the meter may go: nothing from golden
# PM through to golden AM, the full range by day.
sub meter_trim_floor {
    return meter_dark_preset() ? 0 : -$TRIM_MAX;
}

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

    # The manual focus control, if the camera has one. Only read, and only
    # ever written back to the value the preset asked for.
    $ctrl_focus_abs = $seen{$FOCUS_ABS_CTRL} ? $FOCUS_ABS_CTRL : undef;
    if ($ctrl_focus_abs) {
        for my $line (@lines) {
            next unless $line =~ /^\s*\Q$FOCUS_ABS_CTRL\E\s/;
            my ($min) = $line =~ /min=(-?\d+)/;
            my ($max) = $line =~ /max=(-?\d+)/;
            @focus_range = ($min, $max)
                if defined $min && defined $max && $max > $min;
        }
    }

    # Which of the hands-off controls this camera actually has, so that the
    # guard reads back only what exists.
    @locked_have = grep { $seen{$_} } (@LOCKED_CTRLS, $GAMMA_CTRL);
    meter_learn_locked($dev);

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

# ---- Night image enhancement (frame averaging, CLAHE, brain G) ----
#
# A separate module because it is a separate kind of work: it never touches the
# camera, it only reads the stills in the picture folder that the loop below
# has already measured. With WebcamEnhance.pm missing, everything here carries
# on exactly as it did before it existed.
my $ENHANCE;
sub enhance_module {
    return $ENHANCE if defined $ENHANCE;
    $ENHANCE = 0;
    # Next to this script first, then the home directory, then the working
    # directory - the same order the preset wrappers use, because these files
    # get copied to ~ and run from either place.
    my @where = ('.', meter_home_dir());
    if ($0 =~ m{^(.*)/[^/]+$}) { unshift @where, $1; }
    for my $dir (@where) {
        next unless -f "$dir/WebcamEnhance.pm";
        local @INC = (@INC, $dir);
        if (eval { require WebcamEnhance; 1 }) {
            $ENHANCE = 1;
            last;
        }
    }
    return $ENHANCE;
}

# How far up its own range the gain is sitting, 0 to 1, or undef.
#
# This is the one honest test of how dark it actually is. The clock says what
# time it is; the gain says whether the camera is struggling, which is what the
# enhancement needs to know - a floodlit yard at midnight needs none of it and
# an overcast dusk may need all of it. It is the same test the sharpness uses,
# so the two agree about when night has started.
sub enhance_gain_fraction {
    my ($dev) = @_;
    return undef unless $ctrl_range{gain};
    my ($glo, $ghi) = @{ $ctrl_range{gain} };
    return undef unless $ghi > $glo;
    my $now = defined $meter_wrote{gain} ? $meter_wrote{gain} : get_ctrl($dev, 'gain');
    return undef unless defined $now && $now =~ /^-?\d+$/;
    my $fraction = ($now - $glo) / ($ghi - $glo);
    $fraction = 0 if $fraction < 0;
    $fraction = 1 if $fraction > 1;
    return $fraction;
}

# Hand the current still to the enhancer. Returns a status line, or nothing.
#
# This is deliberately kept well away from everything else: it reads a file and
# writes a file, and it sends nothing to the camera. A failure in here cannot
# affect the correction loop, and the corrected copies go into their own
# subfolder so that the next pass still measures the camera's own output rather
# than measuring its own correction and chasing it.
sub meter_enhance {
    my ($dev, $frame, $mean) = @_;
    return undef unless enhance_module();
    my ($line, $note) = (undef, '');
    my $ok = eval {
        ($line, $note) = WebcamEnhance::enhance_pass(
            frame         => $frame,
            folder        => snap_dir(),
            gain_fraction => enhance_gain_fraction($dev),
            mean          => $mean,
        );
        1;
    };
    unless ($ok) {
        my $why = $@ || 'unknown error';
        $why =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
        meter_log("enhancement failed: $why");
        return "enhance: failed - $why";
    }
    meter_log($line) if defined $line;
    return $line;
}

# How often to file a still into the brain's training set. Every pass would
# fill the quotas with thirty near-identical frames a minute; two minutes apart
# gives the light time to have actually changed. A preset or light change
# overrides this and files one immediately, which is the point of it.
my $HARVEST_EVERY = 120;
my $harvest_last  = 0;
my $harvest_now   = 1;      # file one on the first pass
our $harvest_note = '';
our $train_note   = '';

# File this still into the training set, and retrain on it once a day.
#
# Deliberately last and wrapped: it reads and writes files and sends nothing to
# the camera, so it cannot affect the correction loop.
sub meter_harvest {
    my ($dev, $frame) = @_;
    return undef unless enhance_module();
    my $now = time();
    return undef if !$harvest_now && $now - $harvest_last < $HARVEST_EVERY;
    $harvest_now  = 0;
    $harvest_last = $now;

    my $line;
    my $ok = eval {
        $line = WebcamEnhance::harvest(
            frame         => $frame,
            preset        => WebcamEnhance::current_preset(),
            gain_fraction => enhance_gain_fraction($dev),
        );
        1;
    };
    unless ($ok) {
        my $why = $@ || 'unknown error';
        $why =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
        $harvest_note = "harvest failed: $why";
        meter_log($harvest_note);
        return undef;
    }
    $harvest_note = $line if defined $line;
    meter_log($line) if defined $line && $line =~ /^harvested:/;

    # Retrain on this camera once there is enough, and then once a day. The
    # trainer returns at once when it is not time, so this costs nothing.
    my $trained;
    $ok = eval { $trained = WebcamEnhance::self_train(); 1 };
    if ($ok && defined $trained) {
        $train_note = $trained;
        if ($trained =~ /retrained on this camera/) {
            meter_log($trained, always => 1);
            return $trained;
        }
    }
    return undef;
}

# ---- the locked-on target ----
#
# One object picked out in the window - a particular car on the kerb, a
# particular doorway - and kept as *the* thing these programs are trying to
# get a good picture of, around the clock. The lock itself lives in
# ~/.webcam-object-lock.json, written by the window and read here, and the
# matching is done by webcam_lock.py, which is shared with the python repo so
# that both lock on to the same object by the same rules.
my $LOCK_FILE = ($ENV{HOME} || '/root') . '/.webcam-object-lock.json';

# Where a file that ships beside this scheduler actually lives.
sub find_beside {
    my ($name) = @_;
    for my $dir (File::Basename::dirname(Cwd::abs_path($0)),
                 home_dir(), Cwd::getcwd()) {
        next unless defined $dir;
        my $path = "$dir/$name";
        return $path if -r $path;
    }
    return undef;
}

# Is anything locked? A stat, so it can be asked every pass.
sub meter_lock_is_set {
    return -s $LOCK_FILE ? 1 : 0;
}

# Where the locked-on target is in this still, as a crop written beside the
# lock, or nothing.
#
# The matching itself is done by webcam_lock.py, which is shared with the
# python programs so that both repos lock on to the same object by the same
# rules and one lock file serves both. Perl asks it for a file name and gets
# on with measuring, which is all this side needs.
sub meter_lock_region {
    my ($f) = @_;
    return undef unless defined $f && -e $f;
    my $script = find_beside('webcam_lock.py');
    return undef unless defined $script && -e $script;
    my $out = `python3 "$script" roi "$f" 2>/dev/null`;
    return undef unless defined $out;
    chomp $out;
    my ($path, $how, $label) = split /\t/, $out;
    return undef unless defined $path && length $path && -e $path;
    return { path => $path, how => ($how || 'found'),
             label => ($label || 'object') };
}

sub meter_measure {
    my ($f) = @_;
    return () unless defined $f;
    my $im = magick_cmd();
    return () unless length $im;

    # The locked-on target, when there is one. Everything below is unchanged
    # - it just runs on a crop of the target and its surroundings instead of
    # on the whole frame, which is the whole point of locking on: the
    # exposure is then decided by the car, and the floodlight at the far end
    # of the yard gets a vote proportional to how much of the car it lights
    # rather than to how bright it is.
    $lock_note = '';
    if (meter_lock_is_set()) {
        my $found = meter_lock_region($f);
        if ($found) {
            $f = $found->{path};
            $lock_note = "metering the locked $found->{label} "
                       . "($found->{how})";
        } else {
            $lock_note = 'locked target not found in this frame - metering '
                       . 'the whole frame';
        }
    }

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

# ---- the controls this loop keeps its hands off ----

# Read saturation, hue and gamma as the preset left them, along with the
# preset's focus distance.
#
# These are not trimmed, so the only reason to read them is to be able to tell
# later whether they are still where the preset put them - and, for gamma,
# what the ceiling is. Re-read whenever the baseline is re-learnt, because a
# preset firing is exactly when they legitimately change.
sub meter_learn_locked {
    my ($dev) = @_;
    my @names = @locked_have;
    push @names, $ctrl_focus_abs if $ctrl_focus_abs;
    return unless @names;
    my $list = join(',', @names);
    my $out = `v4l2-ctl -d $dev --get-ctrl $list 2>/dev/null`;
    my %found;
    while ($out =~ /(\w+):\s*(-?\d+)/g) { $found{$1} = $2 + 0; }
    $focus_base = delete $found{$ctrl_focus_abs}
        if $ctrl_focus_abs && exists $found{$ctrl_focus_abs};
    %locked_base = ();
    for my $name (@locked_have) {
        $locked_base{$name} = $found{$name} if exists $found{$name};
    }
    return \%locked_base;
}

# Put saturation, hue and gamma back if they have moved off the preset - and,
# for gamma, only ever downwards.
#
# Nothing in this loop writes them, so in normal running this finds nothing
# and costs one read. It is here for the case that is not normal running:
# another program, a half-finished preset, or a driver that resets a control
# when the exposure mode changes. Without it a gamma that got raised once
# would stay raised for the rest of the night with the correction dutifully
# metering around it.
sub meter_guard_locked {
    my ($dev) = @_;
    return '' unless @locked_have && keys %locked_base;
    my $list = join(',', @locked_have);
    my $out = `v4l2-ctl -d $dev --get-ctrl $list 2>/dev/null`;
    my %have;
    while ($out =~ /(\w+):\s*(-?\d+)/g) { $have{$1} = $2 + 0; }
    my @fixed;
    for my $name (sort keys %locked_base) {
        my $want = $locked_base{$name};
        my $now  = $have{$name};
        next unless defined $now;
        next if $now == $want;
        if ($name eq $GAMMA_CTRL && $now < $want) {
            # Pulled down, not up. Allowed, and worth keeping: a lower gamma
            # holds the midtones together. Take it as the new ceiling rather
            # than undoing it.
            $locked_base{$name} = $now;
            next;
        }
        system("v4l2-ctl -d $dev --set-ctrl $name=$want 2>/dev/null");
        push @fixed, "$name $now -> $want";
    }
    if (@fixed) {
        meter_log('put the hands-off controls back: ' . join(', ', @fixed),
                  always => 1);
        return 'restored ' . join(', ', @fixed);
    }
    return '';
}

# ---- focus ----

# How sharp the picture actually is: the variance of its Laplacian.
#
# A big number is a detailed picture, a small one is a soft picture, and the
# useful property is that it does not care how bright the frame is - which is
# what makes it the right test here, where the frame is dark half the time by
# design.
#
# Done with ImageMagick, which these programs already depend on, through the
# standard deviation of an edge-detected copy; the variance is its square,
# which is what the thresholds above are written in. Returns nothing when
# ImageMagick is missing, which means "no opinion" and leaves the focus alone.
sub meter_blur_score {
    my ($f) = @_;
    return undef unless defined $f && -e $f;
    my $im = magick_cmd();
    return undef unless length $im;
    my $out = `$im "$f" -colorspace Gray -resize 50% -define convolve:scale=! -morphology Convolve Laplacian:0 -format "%[fx:standard_deviation*255]" info: 2>/dev/null`;
    return undef unless defined $out && $out =~ /([\d.]+)/;
    return $1 * $1;
}

# The blur threshold for how dark it is now: the day number in daylight,
# easing to the night number at the top of the gain range.
sub meter_blur_limit {
    my ($dev) = @_;
    my $fraction = enhance_gain_fraction($dev);
    return $BLUR_DAY unless defined $fraction;
    return $BLUR_DAY if $fraction <= $BLUR_KNEE;
    my $into_dark = ($fraction - $BLUR_KNEE) / (1 - $BLUR_KNEE);
    return $BLUR_DAY - ($BLUR_DAY - $BLUR_NIGHT) * $into_dark;
}

# Put the focus back near where the preset left it.
#
# Only when it has drifted further than $FOCUS_WINDOW, and only to the
# preset's own value - this never picks a focus distance of its own.
# Continuous autofocus is switched back on afterwards, because nothing in
# these programs leaves the camera in manual focus.
sub meter_hold_focus {
    my ($dev) = @_;
    return '' unless $ctrl_focus_abs && defined $focus_base && @focus_range == 2;
    my ($lo, $hi) = @focus_range;
    my $window = int($FOCUS_WINDOW * ($hi - $lo) + 0.5);
    $window = 1 if $window < 1;
    my $out = `v4l2-ctl -d $dev --get-ctrl $ctrl_focus_abs 2>/dev/null`;
    return '' unless $out =~ /(\w+):\s*(-?\d+)/;
    my $now = $2 + 0;
    return '' if abs($now - $focus_base) <= $window;
    my $ctrl = defined $ctrl_has_focus ? $ctrl_has_focus : $FOCUS_CTRL;
    system("v4l2-ctl -d $dev --set-ctrl $ctrl=0 2>/dev/null");
    system("v4l2-ctl -d $dev --set-ctrl $ctrl_focus_abs=$focus_base 2>/dev/null");
    select(undef, undef, undef, 0.2);
    system("v4l2-ctl -d $dev --set-ctrl $ctrl=1 2>/dev/null");
    meter_log("focus had drifted to $now, put back to the preset's $focus_base",
              always => 1);
    return "focus put back to $focus_base";
}

# Refocus only when the picture is actually blurry.
#
# The old behaviour was to re-run the autofocus after every light change, on
# the grounds that the first seconds after a change come out soft. That is
# true and it is also how the focus ends up somewhere the preset never asked
# for: every trim sent the autofocus hunting, and a night scene with nothing
# well-lit to lock on to is precisely the scene it hunts worst in. Hunting is
# worse than a slightly stale focus.
#
# So the picture gets measured first. Blurry - refocus, which is the case the
# refocus was put in for. Sharp enough - leave the focus alone and only pull
# it back if it has wandered out of the window around the preset.
sub meter_maybe_refocus {
    my ($dev, $frame) = @_;
    $last_blur = defined $frame ? meter_blur_score($frame) : undef;
    my $limit = meter_blur_limit($dev);
    return meter_hold_focus($dev) unless defined $last_blur;
    if ($last_blur < $limit) {
        meter_log(sprintf('picture is blurry (sharpness score %.0f, wanted '
                        . '%.0f) - refocusing', $last_blur, $limit));
        meter_refocus($dev);
        return sprintf('blurry (%.0f < %.0f) - refocused', $last_blur, $limit);
    }
    return meter_hold_focus($dev);
}

# Sharpness, as a fraction of the control's range: full sharpness in daylight
# and through the golden hours, backed off at night.
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
my $SHARP_DARK  = 0.70;      # at the top of the gain range
my $SHARP_KNEE  = 0.50;      # the gain fraction where the easing off starts

# And the two ends sharpness is never allowed outside of, whatever the curve
# above works out and whatever a preset asked for: half sharpness at the very
# least, full sharpness at the very most.
#
# The floor is the useful half of this. Sharpening amplifies grain, so the
# honest night answer looks like "turn it down", and turned down far enough
# the picture is a smooth grey blur with no edge left to read a number plate
# off - grain-free and useless. Half is the point below which this stops
# buying anything. The ceiling only says there is no such thing as more than
# all of a control.
my $SHARP_FLOOR = 0.50;
my $SHARP_CEIL  = 1.00;

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
    # Clamped to the 50-100% band before it is turned into the control's own
    # units, so the curve above can be changed freely without any edit of it
    # being able to put the picture outside the band that is wanted.
    $want = $SHARP_FLOOR if $want < $SHARP_FLOOR;
    $want = $SHARP_CEIL  if $want > $SHARP_CEIL;
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
# ---- before and after, for every adjustment ----
#
# "The program sent it" and "the camera took it" are different facts, and only
# the second one is what the picture is being taken with. v4l2-ctl reports
# success for a write the camera ignores, a recorder holding the stream can
# put a value back a moment later, and a driver may round a value to its own
# step size. Reading every control before and after a change, and writing both
# down, is the only way to tell those apart - and it turns "the picture did
# not change" from a mystery into a line saying the camera reported the old
# value afterwards.
#
# Same file and same format as the python side, so one log covers both.
my $ADJUST_LOG = ($ENV{HOME} || '/root') . '/.webcam-adjustments.log';

sub meter_read_all {
    my ($dev) = @_;
    my %v;
    for my $line (`v4l2-ctl -d $dev -L 2>/dev/null`) {
        next unless $line =~ /^\s*(\w+)\s+0x[0-9a-f]+\s+\(\w+\)\s*:(.*)$/;
        my ($name, $rest) = ($1, $2);
        $v{$name} = $1 if $rest =~ /\bvalue=(-?\d+)/;
    }
    return %v;
}

sub meter_track_adjustment {
    my ($stage, $before, $after, $asked) = @_;
    return unless $before && %$before;
    my %names = map { $_ => 1 } (keys %$before, keys %$after);
    my (@rows, $asked_n, $took_n);
    ($asked_n, $took_n) = (0, 0);
    for my $name (sort keys %names) {
        my $was = $before->{$name};
        my $now = $after->{$name};
        my $want = $asked->{$name};
        next if defined $was && defined $now && $was eq $now
             && !defined $want;
        my $state;
        if (defined $want) {
            $asked_n++;
            if (defined $now && $now == $want) { $state = 'took'; $took_n++ }
            elsif (defined $was && defined $now && $was == $now) {
                $state = "IGNORED (camera reports " . (defined $now ? $now : '?') . ")";
            } else {
                $state = 'rounded to ' . (defined $now ? $now : '?');
            }
        } else {
            $state = 'moved on its own';
        }
        push @rows, sprintf('    %-30s %s -> %s%s  %s', $name,
            defined $was ? $was : '?', defined $now ? $now : '?',
            defined $want ? " (asked $want)" : '', $state);
    }
    my @when = localtime(time);
    my $head = sprintf('%04d-%02d-%02d %02d:%02d:%02d  %s  %d/%d asked changes took',
        $when[5] + 1900, $when[4] + 1, $when[3], $when[2], $when[1], $when[0],
        $stage, $took_n, $asked_n);
    push @rows, '    nothing moved' unless @rows;
    if (open my $fh, '>>', $ADJUST_LOG) {
        print {$fh} "$head\n", map { "$_\n" } @rows;
        close $fh;
    }
    # A write that did not take is a failure, not a note.
    meter_log("$stage: " . ($asked_n - $took_n) . ' of the values asked for '
            . 'did not take - see ' . $ADJUST_LOG, always => 1)
        if $asked_n > $took_n;
    return;
}

# Send the given trim, worked out from the preset's own baseline. Returns the
# number of controls actually written.
#
# That return value matters. Without a baseline there is nothing to trim
# *from*, every control is skipped, and this used to go round the loop writing
# nothing and still report "trimmed to +5" - the picture stayed exactly as
# dark as it was while the log said it was being corrected. A silent failure
# that reads as success is the worst kind here.
#
# The baseline is normally learnt on the first pass. It can be missing when
# the camera could not be read at all: unplugged, or no v4l2-ctl. So try once
# more to learn it here, and if there is still nothing, say so.
sub meter_apply_trim {
    my ($dev, $t) = @_;
    my $floor = meter_trim_floor();
    $t = $floor if $t < $floor;
    $t =  $TRIM_MAX if $t >  $TRIM_MAX;
    $trim = $t;
    unless (%meter_base) {
        my %have = meter_read_ctrls($dev);
        if (%have) {
            %meter_base = %have;
            meter_log('learnt the baseline late, from the camera, because '
                    . 'the first pass could not read it', always => 1);
        }
    }
    # Every control the camera has, as it stands before anything is sent.
    # Read in full rather than just the ones being trimmed: the exposure
    # time and the focus move on their own when the light changes, and
    # seeing that beside the values that were asked for is most of the use
    # of keeping the record.
    my %before = meter_read_all($dev);

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

    unless (%meter_wrote) {
        # Nothing reached the camera. Loud, because the alternative is a log
        # full of corrections that never happened.
        meter_log('TRIM NOT APPLIED: no control could be written - the '
                . 'camera could not be read, so there is no baseline to trim '
                . 'from. Check that the camera is plugged in and v4l2-ctl '
                . 'works.', always => 1);
        return 0;
    }

    # Sharpness follows the gain that was just sent. It is deliberately kept
    # out of %meter_wrote: that hash is how an outside change is spotted, and
    # sharpness is a value this loop owns outright rather than a trim away
    # from the preset's own.
    my $sharp = meter_sharpness_for($meter_wrote{gain});
    system("v4l2-ctl -d $dev --set-ctrl sharpness=$sharp 2>/dev/null") if defined $sharp;

    # Saturation, hue and gamma are not trimmed; check nothing else moved
    # them, and pull gamma back down if it was raised.
    meter_guard_locked($dev);

    # The light just moved. Whether that costs any sharpness is a question
    # about the picture, so it is answered from the picture rather than
    # assumed: refocus if it has actually gone soft, otherwise hold the
    # preset's focus distance.
    meter_maybe_refocus($dev, meter_snapshot());

    # And the same controls again, afterwards. A moment first: a driver does
    # not always report a new value the instant it is written, and reading
    # too early would record a change that took as one that did not.
    if (%before) {
        select(undef, undef, undef, 0.4);
        my %after = meter_read_all($dev);
        my %asked = %meter_wrote;
        $asked{sharpness} = $sharp if defined $sharp;
        meter_track_adjustment(sprintf('light meter trim %+d', $trim),
                               \%before, \%after, \%asked);
    }
    return scalar keys %meter_wrote;
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
            # The preset owns saturation, hue, gamma and the focus distance,
            # so whatever it just set them to is the new reference the guard
            # holds them at.
            meter_learn_locked($dev);
            # A preset just changed the light. Measure the picture before
            # deciding whether the focus needs anything: a preset change does
            # not make a sharp picture blurry, and the old
            # refocus-on-every-change is what used to walk the focus off the
            # distance the preset was set up for.
            meter_maybe_refocus($dev, meter_snapshot());
            # A preset or a hand on a slider just changed the light. This is
        # exactly the moment worth filing: the scene is the same and the
        # exposure is different, which is how the training set gets this
        # camera's own before and after instead of a guess at one.
        $harvest_now = 1;
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

    # The corrected copy of this still, when either switch is on. This is not
    # part of the correction loop - it changes no control and the recording is
    # untouched by it - so it happens here, once the frame is in hand and
    # measured, and whatever it says is added to the status line.
    my $enhanced = meter_enhance($dev, $frame, $mean);
    my $trained = meter_harvest($dev, $frame);

    # Median of the last three keeps a passing pair of headlights from
    # dragging the picture darker for the next minute.
    push @meter_means, $mean;
    shift @meter_means while @meter_means > 3;
    my $m = meter_median(@meter_means);

    # A trim left over from the daylight that came before. The sun going down
    # does not undo a cut the meter made at noon, so a preset change into the
    # falling light can arrive with the picture already held below the preset.
    # Lift it back to the floor before deciding anything, rather than waiting
    # for two "too dark" passes to walk it up a step at a time.
    if ($trim < meter_trim_floor()) {
        my $was = $trim;
        if (meter_apply_trim($dev, meter_trim_floor())) {
            meter_log(sprintf('trim %+d -> %+d: the light meter does not '
                            . 'darken the picture from golden PM through to '
                            . 'golden AM, so the daylight trim is released',
                              $was, $trim), always => 1);
            $meter_hold  = $METER_SETTLE;
            @meter_means = ();
            return sprintf('light meter: trim %+d, the daylight trim is '
                         . 'released - the picture is not darkened from '
                         . 'golden PM through to golden AM', $trim);
        }
    }

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

    # From golden PM through to golden AM the meter may not darken the
    # picture. The measurement that asks it to is usually a lamp or a pair of
    # headlights in an otherwise dark frame, and the answer - less gain, less
    # brightness - costs the whole picture to tame one bright patch. Held at
    # the preset rather than cut, and said plainly so the status line does not
    # read as a correction that never happened.
    if ($dir < 0 && $trim <= meter_trim_floor()) {
        $dir = 0;
        $why .= ' - holding at the preset: the light meter does not darken '
              . 'the picture from golden PM through to golden AM';
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
        if (($dir > 0 && $trim >= $TRIM_MAX)
            || ($dir < 0 && $trim <= meter_trim_floor())) {
            $why .= ' - trim at its limit, the preset itself needs changing';
        } else {
            my $sent = meter_apply_trim($dev, $trim + $dir);
            $meter_hold  = $METER_SETTLE;
            @meter_means = ();
            if ($sent) {
                $why .= sprintf(' - trimmed to %+d', $trim);
                meter_log(sprintf('trim %+d: mean %d of target %d, white %.1f%%, black %.0f%% (%s)',
                    $trim, $m, $mean_target, $hot * 100, $cold * 100, $why), always => 1);
            } else {
                # Say it here too. The status line is what is on the screen,
                # and it should never claim a correction that did not reach
                # the camera.
                $why .= ' - COULD NOT TRIM: nothing could be written to the camera';
            }
        }
    }
    $meter_dir = $dir;

    my $status = sprintf(
        'light meter: trim %+d, mean %d of target %d, white %.1f%%, black %.0f%% - %s',
        $trim, $m, $mean_target, $hot * 100, $cold * 100, $why);
    $status .= sprintf(' | sharpness score %.0f', $last_blur) if $last_blur;
    $status .= " | $lock_note" if length $lock_note;
    $status .= " | $enhanced" if defined $enhanced;
    $status .= " | $trained" if defined $trained;
    return $status;
}

# The startup probe: ask this camera what its controls can actually do before
# the schedule starts, and say what came back. Anything the camera does not
# answer for falls back to the ranges these programs already used.
meter_learn_ranges($meter_device);
print meter_range_report(), "\n";
print meter_prepare_snapshots(), "\n";
print "light meter: errors are logged to ", meter_log_path(), "\n";

# Every light change below is worked out from the clock, so the clock is
# checked against a time server now and once a day after that.
sync_network_time();
print "clock: ", time_status(), "\n";

 for (;;) { # I prefer using "for for infinite loops


# localtime creates a Time::Piece object
my $timepiece = localtime(corrected_time());

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
    # Once a day; offline it does nothing and the system clock is used.
    time_check_due();

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
$timepiece = localtime(corrected_time());

# The detected $lat and $lon from the top of the file are still in scope here.
# This used to re-declare them with a hard-coded place, which inside the loop
# meant the detected location was thrown away on the first pass.

# Current date
 $now = DateTime->from_epoch(epoch => corrected_time());

$now->set_time_zone($sun_tzid);



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
    time_zone  => $sun_tzid,
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
    time_zone  => $sun_tzid,
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
 
 
