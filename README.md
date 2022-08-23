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
required perl modules: 

DateTime, 
DateTime::Duration, 
DateTime::Event::Sunrise, 
Time::Piece, 
Time::Seconds 

In Linux, 
install the required webcam 
software dependency: 

sudo apt-get -y install v4l-utils


