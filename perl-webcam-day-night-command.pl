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
                ($ENV{HOME} || '.'),
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

my $sun_file = ($ENV{HOME} || '.') . '/.webcam-sun-times.conf';
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
 
 
