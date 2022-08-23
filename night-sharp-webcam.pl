#!/usr/bin/perl
use warnings;
use strict;
use Tk;



# BELOW IS DAY SETTINGS BEFORE NIGHT SETTINGS WORK
system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=128 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=64 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=166 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_absolute=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');

sleep(1);
# BELOW IS NIGHT SETTINGS
system('v4l2-ctl --set-ctrl sharpness=250 '); 


system('v4l2-ctl --set-ctrl  brightness=193 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=255 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');

#sleep(4);

system('v4l2-ctl --set-ctrl exposure_absolute=1873 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=1 ');

system('v4l2-ctl --set-ctrl focus_absolute=51 ');

system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');

######################  repeat
sleep(2);

system('v4l2-ctl --set-ctrl sharpness=250 '); 


system('v4l2-ctl --set-ctrl  brightness=193 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=255 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');

#sleep(4);

system('v4l2-ctl --set-ctrl exposure_absolute=1873 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=1 ');

system('v4l2-ctl --set-ctrl focus_absolute=51 ');

system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');

sleep(3);

system('v4l2-ctl --set-ctrl exposure_absolute=166 ');

sleep(3);

system('v4l2-ctl --set-ctrl exposure_absolute=1873 ');

sleep(2);

die; 
# system('xterm -hold -e "v4l2-ctl -L " '); 


