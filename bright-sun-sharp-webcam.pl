#!/usr/bin/perl
use warnings;
use strict;
# use Tk;



 system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=128 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=64 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=2047 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_absolute=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');


sleep(2);

# BELOW IS the DAY SETTINGS for the afternoon bright sun settings: 
system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=153 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=0 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=4 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_absolute=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');

sleep(3);

system('v4l2-ctl --set-ctrl exposure_absolute=100 ');

sleep(3);

system('v4l2-ctl --set-ctrl exposure_absolute=4 ');

sleep(2);


 die;
# system('xterm -hold -e "v4l2-ctl -L " '); 
   
 

 


