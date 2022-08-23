#!/usr/bin/perl
use warnings;
use strict;
use Tk;

my $mw = new MainWindow;

 $mw->geometry("247x131+350+647");
 $mw->title("Webcam");
 

# my $frame = $mw->Frame()->pack();


$mw->Button(-text => "Pre-Sunset Sharp Webcam",
          -command => sub{ &Pre_Sunset_settings  })->pack();

$mw->Button(-text => "Night Sharp Webcam",
          -command => sub{ &night_settings  })->pack();


$mw->Button(-text => "Day Sharp Webcam",
          -command => sub{ &day_settings  })->pack();

$mw->Button(-text => "Afternoon Bright Sun Sharp Webcam",
          -command => sub{ &bright_sun_settings  })->pack();


MainLoop;
             

sub night_settings{
# below is day settings before night settings can work correctly
 system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=128 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=64 ');

system('v4l2-ctl --set-ctrl exposure_auto=3 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=166 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_absolute=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');

sleep(1);
# below is night settings
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
   
  };



sub day_settings{

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

# BELOW IS DAY SETTINGS 
system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=153 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=104 ');

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
   
 



  };


sub Pre_Sunset_settings{

system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=128 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=64 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=168 ');

system('v4l2-ctl --set-ctrl exposure_auto_priority=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_absolute=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl focus_auto=0 ');
#sleep(4);
system('v4l2-ctl --set-ctrl  zoom_absolute=1 ');


sleep(2);

# BELOW IS THE PRE-SUNSET SETTINGS CODE

system('v4l2-ctl --set-ctrl sharpness=250 '); 

system('v4l2-ctl --set-ctrl  brightness=153 '); 

system('v4l2-ctl --set-ctrl contrast=32 ');

system('v4l2-ctl --set-ctrl saturation=32 ');

system('v4l2-ctl --set-ctrl gain=104 ');

system('v4l2-ctl --set-ctrl exposure_auto=1 ');
#sleep(4);
system('v4l2-ctl --set-ctrl exposure_absolute=50 ');

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

system('v4l2-ctl --set-ctrl exposure_absolute=50 ');

sleep(2);

die;
# system('xterm -hold -e "v4l2-ctl -L " '); 
   
 

};

# below is afternoon bright sun settings: 

sub bright_sun_settings{

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
   
 



  };

