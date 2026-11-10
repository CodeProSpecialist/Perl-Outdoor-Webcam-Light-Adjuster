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
    ./webcam-preset.pl night-mono
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

## Night tuning and white balance

Night was retuned to match the ONN settings, mapped onto this camera's 0-255
ranges rather than copied as raw numbers: brightness and gain to the top, the
longest exposure the driver will take, backlight compensation on, and sharpness
cut back from 250 to 109. Heavy sharpening amplifies sensor noise in the dark,
which is why the ONN night preset sits at 3 of 7 rather than near maximum.
Set sharpness back to 250 in the night table if you prefer the old look.

`night-mono-sharp-webcam.pl` is the same thing without colour. Colour noise is
most of what makes a dark frame look muddy, so dropping saturation to 0 trades
colour for a cleaner, apparently brighter picture.

Every preset uses a cold white balance (manual 2800). Note that
`white_balance_temperature` sets the colour temperature the camera ASSUMES the
light to be, not the look of the picture: a low value tells the camera the light
is warm, so it compensates with blue and the result looks cold. Change `COLD_WB`
at the top of `webcam-preset.pl` to adjust it.


## Automatic light adjustment (new)

The schedule above is still what picks the preset. On top of it, the scheduler
now measures the picture the camera is actually producing, every 5 seconds, and
corrects whatever the preset set so the result is neither too bright nor too
dark. A cloudy afternoon, a security light coming on at 2am, snow glare at
noon - none of that is on a clock, so none of it can be handled by one.

It is a correction and not a replacement. Every preset stays exactly as it is,
including its white balance, focus and exposure mode; the correction moves five
light controls - gain, brightness, contrast, saturation and backlight
compensation - away from the preset's own values by a trim of -5 to +5 steps.
Gain carries most of it, because it is the control that actually amplifies
signal. Brightness moves least, since on these webcams it is a black level lift
rather than exposure. Saturation comes *down* as the trim goes up, so there is
colour day and night, with less of it at night where most of the colour left is
noise. Each step is a fraction of the control's own range, read from
`v4l2-ctl -L`, so the same code suits cameras with different ranges.

When a preset fires, or you move a control by hand, the loop notices that the
settings are not what it last wrote and re-learns them as its new baseline,
with the trim back at zero. Nothing has to tell it a preset ran.

### What it measures

Average grey level, plus two clipping figures: how much of the frame has gone
to pure white and how much to pure black. The mean cannot see either problem on
its own - a frame that is half blown-out floodlight and half pitch black
averages to a respectable middle grey while showing nothing at all. Either
clipping figure can override the mean. When both are out at once, which is what
a security light over black tarmac looks like, it holds where it is and says
so, rather than chasing a picture the sensor cannot hold.

It takes the median of three samples, needs two consecutive samples to agree
before it moves, and waits two samples after each change, so passing headlights
do not drag the picture dark for the next minute.

### Setting it up

The camera cannot be opened for this: V4L2 allows only one program to stream,
and the recording software holds the device. So the still comes from that
software instead. Set `WEBCAM_SNAPSHOT` to one of:

* a directory - the newest `.jpg` in it is measured, which is what a "save
  snapshots to folder" module produces
* a single file - for software that overwrites the same still each time
* an `http://` URL - a snapshot URL from the recording software's web server

```
sudo apt install imagemagick
export WEBCAM_SNAPSHOT=$HOME/webcam-snapshots
export WEBCAM_TARGET=100        # target grey level out of 255, optional
```

With no snapshot set, nothing is corrected and the presets stand as they always
did. ImageMagick does the measuring; without it the correction stays idle and
the schedule keeps working.
