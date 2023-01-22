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


my $sunrise = $sun->sunrise_datetime($now)->strftime("%H:%M:%S");

my $sunset = $sun->sunset_datetime($now)->strftime("%H:%M:%S");

################################ adding time and subtracting time code  ######################################
##############################
##### calculate for sunrise  #####
 
my $sunrise_dt = DateTime->new(
    year       => $sun->sunrise_datetime($now)->strftime("%Y"),
    month      => $sun->sunrise_datetime($now)->strftime("%m"),
    day        => $sun->sunrise_datetime($now)->strftime("%d"),
    hour       => $sun->sunrise_datetime($now)->strftime("%H"),
    minute     => $sun->sunrise_datetime($now)->strftime("%M"),
    second     => $sun->sunrise_datetime($now)->strftime("%S"),
    time_zone  => 'America/Chicago',
);

# Remember that the "say" command will also print something with automatic spacing.  
#say $dt;
 
##############################
##### calculate for sunset  #####
 
my $sunset_dt = DateTime->new(
    year       => $sun->sunset_datetime($now)->strftime("%Y"),
    month      => $sun->sunset_datetime($now)->strftime("%m"),
    day        => $sun->sunset_datetime($now)->strftime("%d"),
    hour       => $sun->sunset_datetime($now)->strftime("%H"),
    minute     => $sun->sunset_datetime($now)->strftime("%M"),
    second     => $sun->sunset_datetime($now)->strftime("%S"),
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
do './pre-sunset-sharp-webcam.pl' ;

sleep(1); 

system('perl ~/pre-sunset-sharp-webcam.pl; ');



};



###########################################################
# I could also simply look at $time

##### night code is here #####
if ( $timepiece->hms eq $minutes_after_sunset_B->strftime("%H:%M:%S") ) {

# remember that night = "17:36:00"
# remember that day = "07:23:00"


sleep(1);

print "The night sharp webcam settings are correctly working right now.\n";


do './day-sharp-webcam.pl'  ;

sleep(5);

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command
do './night-sharp-webcam.pl'   ;


sleep(1);

system('perl ~/night-sharp-webcam.pl; ');



};




########## below is the code for day webcam #############################################


# I could also simply look at $time
##### day #####
if ( $timepiece->hms eq $minutes_before_sunrise_A->strftime("%H:%M:%S") ) {

# remember that night = "21:06:00"
# remember that day = "07:23:00"


sleep(1);

print "The Pre-Sunrise webcam settings are correctly working right now.\n";

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command 
do './pre-sunset-sharp-webcam.pl'  ;

sleep(1);

system('perl ~/pre-sunset-sharp-webcam.pl; ');

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


##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command

system('perl ~/night-sharp-webcam.pl; '); 

sleep(3); 

system('perl ~/day-sharp-webcam.pl; ' ); 


sleep(1);

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command

do './day-sharp-webcam.pl'  ;

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
do './bright-sun-sharp-webcam.pl'  ;

sleep(1); 

system('perl ~/bright-sun-sharp-webcam.pl; ' );



};




########### The daytime webcam command after the bright sun is not bright. 


##### day #####
if ( $timepiece->hms eq $minutes_before_sunset_B->strftime("%H:%M:%S") ) {

# remember that night = "21:06:00"
# remember that day = "07:23:00"


sleep(1);

print "The Daytime webcam settings are correctly working right now.\n";


##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command


system('perl ~/day-sharp-webcam.pl; ' ); 

sleep(1);

do './day-sharp-webcam.pl'  ;


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


system('perl ~/night-sharp-webcam.pl; ' );

sleep(1); 

##### do './pre-sunset-sharp-webcam.pl'  ;  ## the correct do command
do './night-sharp-webcam.pl'  ;


};

###########  below is code to update sunrise / sunset / localtime 
##### times every single day and to clear the terminal text. 


###########################################################
# I could also simply look at $time

##### night code is here #####
if ( $timepiece->hms eq ("04:45:29") ) {

## set this for:  if ( $timepiece->hms eq ("04:45:29") ) {
## I remember that daylight savings = 2:00am


sleep(1);

 system('reset; ');

#######  reset and clear all necessary variables 


$timepiece = localtime ; 

$now = localtime ;

$sun = localtime ;

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


 $sunrise = $sun->sunrise_datetime($now)->strftime("%H:%M:%S");

 $sunset = $sun->sunset_datetime($now)->strftime("%H:%M:%S");

################################ adding time and subtracting time code  ######################################
##############################
##### calculate for sunrise  #####
 
 $sunrise_dt = DateTime->new(
    year       => $sun->sunrise_datetime($now)->strftime("%Y"),
    month      => $sun->sunrise_datetime($now)->strftime("%m"),
    day        => $sun->sunrise_datetime($now)->strftime("%d"),
    hour       => $sun->sunrise_datetime($now)->strftime("%H"),
    minute     => $sun->sunrise_datetime($now)->strftime("%M"),
    second     => $sun->sunrise_datetime($now)->strftime("%S"),
    time_zone  => 'America/Chicago',
);

# Remember that the "say" command will also print something with automatic spacing.  
#say $dt;
 
##############################
##### calculate for sunset  #####
 
 $sunset_dt = DateTime->new(
    year       => $sun->sunset_datetime($now)->strftime("%Y"),
    month      => $sun->sunset_datetime($now)->strftime("%m"),
    day        => $sun->sunset_datetime($now)->strftime("%d"),
    hour       => $sun->sunset_datetime($now)->strftime("%H"),
    minute     => $sun->sunset_datetime($now)->strftime("%M"),
    second     => $sun->sunset_datetime($now)->strftime("%S"),
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

my $math_minutes_before_sunset_B = $sunset_dt - DateTime::Duration->new( minutes => 39 );

my $minutes_before_sunset_B = $math_minutes_before_sunset_B ;
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


# clear the text in the terminal screen
 system('reset; ');

};


  





}; # <- the main loop bracket
print "This message is only displayed when the perl script exited the repeating clock loop and ended the perl program.";

return 0;
 
 
