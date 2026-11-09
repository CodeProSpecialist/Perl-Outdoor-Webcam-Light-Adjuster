# Perl-Outdoor-Webcam-Light-Adjuster
This software has been tested 
to work in Ubuntu Linux to 
automatically adjust webcam light 
depending upon the sunrise and 
sunset times. It was designed to work 
best with a 1080p HD usb webcam. 
This Perl code is pre-configured to automatically 
work directly from the Linux home directory 
for relatively convenient file access 
just in case the webcam light settings 
need to be adjusted. 
Place all of these Perl files in 
your Linux home directory unless 
you prefer to edit the Perl 
source code to change directory 
locations of the Perl support files 
from this Perl script application. 

First utilize cpan to install the 
required perl modules like this: 

#cpan

#install DateTime::Event::Sunrise

( Continue installing each of 
the Perl modules listed below 
by installing them one by one 
with cpan. 
Some of the modules take close to 1 
hour to install, depending on 
CPU speed and internet connection speed. 


DateTime, 
DateTime::Duration, 
DateTime::Event::Sunrise, 
Time::Piece, 
Time::Seconds 

In Linux, 
install the required webcam 
software dependencies: 

sudo apt-get -y install v4l-utils perl-tk 

The Perl script named "Webcam-settings.pl" 
is a separate Perl Tk application that 
pairs nicely with these Perl scripts 
because it has a control window with buttons. 

Run the main command 
in a command line terminal: 

perl perl-webcam-day-night-command.pl

In a different command line 
terminal: 
perl Webcam-settings.pl







## Camera settings engine

The per-preset scripts no longer hold hard-coded numbers. They all call
`webcam-preset.pl`, which reads the control list from whichever camera is
plugged in and picks the matching values:

* The older webcam uses the pre-5.10 kernel control names (`exposure_auto`,
  `exposure_absolute`, `focus_auto`) on 0-255 ranges.
* The Walmart ONN webcam uses the current names (`auto_exposure`,
  `exposure_time_absolute`) on much smaller ranges.

The same number means a different brightness on each, so the engine keeps one
value table per family and clamps every value to the range the camera reports.
Controls a camera does not have are skipped.

Run a preset directly:

    ./webcam-preset.pl night
    ./webcam-preset.pl golden-am
    ./webcam-preset.pl day
    ./webcam-preset.pl bright-sun
    ./webcam-preset.pl golden-pm

Set `WEBCAM_DEVICE` or pass a second argument for a camera other than
`/dev/video0`.

Night brightness comes from a long manual exposure rather than the brightness
control, which saturates. The night preset asks for a long exposure, reads it
back, and steps down until the driver accepts one, because the driver silently
clamps any exposure that will not fit inside the current frame interval.

`post-sunrise-sharp-webcam.pl` is the golden morning preset, so the schedule
now changes four kinds of light per day: golden morning, day, bright sun,
golden evening, then night.
