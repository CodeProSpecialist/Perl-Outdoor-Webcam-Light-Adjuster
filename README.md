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

#install datetime::Event::Sunrise

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






