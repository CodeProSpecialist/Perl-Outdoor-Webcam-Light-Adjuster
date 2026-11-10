# Perl Outdoor Webcam Light Adjuster

Automatically adjusts an outdoor USB webcam's settings in Ubuntu Linux, 24.04
and 26.04: it
switches between tuned presets on today's real sunrise and sunset times, and
corrects whichever preset is in force by measuring the picture the camera is
actually producing. Written for a 1080p HD USB webcam, and it drives two
different control families, so it suits an older webcam and a current one.

<!-- SCREENSHOT: run it, screenshot the terminal, and save it as
     docs/screenshot-terminal.png, then delete this comment and the one
     around the image line below.

       mkdir -p docs
       perl perl-webcam-day-night-command.pl          # let it print a few cycles
       import -window $(xdotool getactivewindow) docs/screenshot-terminal.png

     (import is ImageMagick; the Ubuntu screenshot tool saved to the same path
     works just as well.)
-->
<!-- ![The scheduler running](docs/screenshot-terminal.png) -->

## Install

Most of the Perl modules are packaged, which is much quicker than building them:

```
sudo apt-get -y install libdatetime-perl libdatetime-event-sunrise-perl
```

`Time::Piece` and `Time::Seconds` come with Perl itself, and
`DateTime::Duration` comes with `DateTime`. For anything apt does not have, or
on an older release, cpan builds them - one at a time, and some take close to
an hour depending on the machine and the connection:

```
cpan
install DateTime
install DateTime::Duration
install DateTime::Event::Sunrise
install Time::Piece
install Time::Seconds
```

Then the system packages:

```
sudo apt-get -y install v4l-utils perl-tk imagemagick ffmpeg curl
```

`imagemagick` measures the picture for the automatic light adjustment and
`ffmpeg` takes the snapshots. Without them the schedule still runs; only the
correction stays idle, and it says which one is missing.

On Ubuntu 26.04 the `imagemagick` package installs ImageMagick 7, whose command
is `magick`; 24.04 and earlier install version 6, whose command is `convert`.
Either is accepted - the command name is worked out at startup, because getting
this wrong does not produce an error, it just measures nothing.

## Run

```
perl perl-webcam-day-night-command.pl
```

And, in another terminal, the Tk control window that pairs with it:

```
perl Webcam-settings.pl
```

The scripts resolve each other next to the file being run, then in `$HOME`,
then in the working directory, so they work both from the repository and copied
into the home directory, and under cron either way. Each preset runs in a child
process, so a preset's own `exit()` cannot take the scheduler down with it - it
used to, which meant the scheduler died at the first preset of the day and
never reached night at all.

## The control window

```
perl webcam-GUI.pl
```

A window with the same presets, the same engine and the same automatic light
adjustment as the scheduler. Both can run at once: neither opens the video
stream, they only set controls, and each re-reads the other's work rather than
fighting over it - press a preset here and the light meter notices within five
seconds and re-learns it as its baseline.

It builds itself from the camera. Every control on the window comes from
`v4l2-ctl -L` at startup, with the range the camera reported, which is the only
way one window serves both the older webcam on 0-255 ranges and the current
ones where brightness runs -64 to 64. Integer and menu controls get a slider
over the camera's own range, booleans get a checkbox, and a control the camera
has that this program has never heard of still appears rather than being
quietly dropped. Nothing is sent that the camera did not confirm it has.

The window scrolls - a camera with every control the kernel defines makes a
taller column than most screens have room for - with a scrollbar on the right,
one along the bottom, the wheel, Page Up and Page Down, Home and End.

There is no preview, deliberately: a V4L2 camera lets one program stream at a
time and the recording software has it. Judge the picture in whatever is
recording it.

`Webcam-settings.pl`, the older and much simpler button window, is still here
and still works.

## The schedule

Presets switch on offsets from today's real sunrise and sunset:

| Time          | Preset         |
|---------------|----------------|
| sunrise − 7   | golden morning |
| sunrise + 26  | day            |
| sunrise + 122 | bright sun     |
| sunset − 39   | day again      |
| sunset − 10   | golden evening |
| sunset + 14   | night          |
| sunset + 30   | night again    |

Night is applied twice because a camera does not always take the settings on
the first attempt. Edit the minute offsets in
`perl-webcam-day-night-command.pl`.

Today's times are refreshed at 04:46, which is before the earliest sunrise of
the year, so the new times are always in place before the morning's first
change. The lookup tries the internet first, then the times saved in
`~/.webcam-sun-times.conf`, then a local calculation; if all three fail,
yesterday's times stay in use rather than being wiped.

## Camera settings engine

The per-preset scripts hold no numbers of their own. They all call
`webcam-preset.pl`, which reads the control list from whichever camera is
plugged in and picks the matching values:

* The older webcam uses the pre-5.10 kernel control names (`exposure_auto`,
  `exposure_absolute`, `focus_auto`) on 0-255 ranges.
* The Walmart ONN webcam uses the current names (`auto_exposure`,
  `exposure_time_absolute`) on much smaller ranges.

The same number means a different brightness on each, so the engine keeps one
value table per family, clamps every value to the range the camera reports, and
skips controls a camera does not have. It prints `(asked 175, clamped)` when it
has to clamp.

Run a preset directly:

```
./webcam-preset.pl night
./webcam-preset.pl night-mono
./webcam-preset.pl golden-am
./webcam-preset.pl day
./webcam-preset.pl bright-sun
./webcam-preset.pl golden-pm
```

Set `WEBCAM_DEVICE`, or pass a second argument, for a camera other than
`/dev/video0`. The wrapper scripts - `night-sharp-webcam.pl` and the rest - are
kept so existing habits and the scheduler keep working; each is the same as one
`webcam-preset.pl` call.

## Night tuning and white balance

Night brightness comes from a long exposure rather than the brightness control,
which saturates. The night preset asks for a long exposure, reads it back, and
steps down until the driver accepts one, because the driver silently clamps any
exposure that will not fit inside the current frame interval.

Night was retuned to match the ONN settings, mapped onto the older camera's
0-255 ranges rather than copied as raw numbers: brightness and gain to the top,
the longest exposure the driver will take, backlight compensation on, and
sharpness cut back from 250 to 109.

`night-mono-sharp-webcam.pl` is the same thing without colour. Colour noise is
most of what makes a dark frame look muddy, so dropping saturation to 0 trades
colour for a cleaner, apparently brighter picture.

Every preset that asks for it uses a cold white balance of 2800. Note that
`white_balance_temperature` sets the colour temperature the camera **assumes**
the light to be, not the look of the picture: a low value tells the camera the
light is warm, so it compensates with blue and the result looks cold. Change
`$COLD_WB` at the top of `webcam-preset.pl` to adjust it. Day, golden morning
and golden evening use automatic white balance instead - the evening light
swings from white through orange to dusk inside the hour that preset covers, so
no single temperature is right for more than a few minutes of it.

## Automatic light adjustment (24/7)

The schedule above still picks the preset. On top of it, the scheduler measures
the picture the camera is actually producing, every 5 seconds, and corrects
whatever the preset set so the result is neither too bright nor too dark. A
cloudy afternoon, a security light coming on at 2am, snow glare at noon - none
of that is on a clock, so none of it can be handled by one.

It is a correction and not a replacement. Every preset stays exactly as it is,
including its white balance, focus and exposure mode. The correction moves five
light controls away from the preset's own values by a trim of −5 to +5 steps:

* **gain** carries most of it, being the control that actually amplifies signal
* **brightness** moves least, since on these webcams it is a black level lift
  rather than exposure
* **contrast** rises with the trim to keep the range spread out
* **saturation** comes *down* as the trim goes up, so there is colour day and
  night, with less of it at night where most of what is left is noise
* **backlight compensation** rises with the trim

When a preset fires, or a control is moved by hand, the loop notices the
settings are not what it last wrote and re-learns them as its new baseline,
with the trim back at zero. Nothing has to tell it a preset ran. The comparison
allows two units of slack, because a driver may round a value to its own step
size - without it, a value that came back as 99 after 100 was sent would look
like an outside change, the baseline would be re-learnt with the trim already
inside it, and the next correction would trim again from there: a ratchet that
walks the picture off in one direction.

### What it measures

Average grey level, plus two clipping figures: how much of the frame has gone
to pure white and how much to pure black. The mean cannot see either problem on
its own - a frame that is half blown-out floodlight and half pitch black
averages to a respectable middle grey while showing nothing at all. Either
figure can override the mean; the limits are 2% blown white and 30% crushed
black, against a target grey level of 100 of 255. When both are out at once,
which is what a security light over black tarmac looks like, it holds where it
is and says so, rather than chasing a picture the sensor cannot hold.

It takes the median of three samples, needs two consecutive samples to agree
before it moves, and waits two samples after each change, so passing headlights
do not drag the picture dark for the next minute.

A status line goes to the terminal as it works:

```
light meter: trim +2, mean 91 of target 100, white 0.0%, black 14% - picture is where it should be
```

### Sharpness

Sharpness is set outright rather than trimmed, and it overrides whatever the
preset asked for: full sharpness in daylight and through the golden hours,
eased to 80-90% of the control's range at night.

What decides night from day is gain rather than the clock. Gain is the only
control that amplifies sensor noise along with the signal, so a camera near the
top of its gain range is working in the dark whatever the time - and the golden
hour presets, which sit under half the gain range, come out at full sharpness.
Sharpening is contrast enhancement at the pixel level and it sharpens noise as
happily as it sharpens the edge of a number plate, which is the only reason to
ease off at all.

### Focus

Continuous autofocus is on at all times, and nothing in these programs ever
leaves the camera in manual focus. Every preset ends by switching autofocus off
and straight back on, and so does every correction the light meter makes.

That toggle is the point of it. Changing gain, brightness or contrast changes
what the autofocus is looking at, and the camera does not always re-run its
search on its own - so the first seconds after a light change come out soft and
out of focus, which on a recording is exactly the part you want sharp. Setting
the control to 1 when it is already 1 does nothing; turning it off and back on
starts a fresh search. There is a third of a second between the two writes,
because the driver has to see the control actually change state - land both in
the same instant and nothing is re-triggered.

The preset tables used to carry a fixed focus distance, applied with autofocus
off. That column is gone and `focus_absolute` is no longer set.

### Control ranges

At startup the camera is asked what its controls can actually do
(`v4l2-ctl -L`) and those ranges are what get used, because a trim step is a
fraction of a control's range: assume 0-64 for a contrast control that really
runs 0-95 and every correction lands a third short. Anything the camera does
not answer for falls back to the ranges these programs were already using - the
ONN set for a modern camera, the 0-255 set for the older one - so an unanswered
control still gets a sensible step instead of being dropped. A line at startup
says which ranges came from the camera and which were assumed:

```
light meter: modern camera, ranges read from the camera for backlight_compensation, brightness, contrast, gain, saturation, sharpness
```

### Setting up the snapshot

The camera cannot be opened for this: V4L2 allows only one program to stream,
and the recording software holds the device. So the still comes from that
software instead. Set `WEBCAM_SNAPSHOT` to one of:

* a **directory** - the newest `.jpg` in it is measured, which is what a "save
  snapshots to folder" module produces; anything older than ten minutes is
  ignored
* a **single file** - for software that overwrites the same still each time
* an **`http://` URL** - a snapshot URL from the recording software's web server

```
sudo apt install imagemagick
export WEBCAM_SNAPSHOT=$HOME/webcam-snapshots
export WEBCAM_TARGET=100        # target grey level out of 255, optional
export WEBCAM_DEVICE=/dev/video0
```

The default folder is
`~/Pictures/onn-webcam/program-snapshots-for-auto-adjust-picture` under
whoever's home directory the program is running as - no user name is written
into any of this. `$HOME` is used when it is set, and the password database
when it is not, which is the case under some cron and systemd setups.

**Taking the snapshots.** That one folder is created at startup if it is not
already there, parent folders and all. Nothing else is ever created.
If the recording software is writing stills into it, those are what get
measured. If it is not - an empty folder on the first run - a frame is grabbed
here instead with ffmpeg. That only works while the camera is free: a V4L2
camera lets one program stream at a time, so if the recording software has the
device the grab fails with a busy error, reported once rather than every five
seconds all night.

**Only the last 30 are kept.** Each new snapshot prunes the folder back to the
newest 30, oldest deleted first, and the same happens once at startup. Every
`.jpg` in the folder counts, whoever wrote it.

With no snapshot available, nothing is corrected and the presets stand as they
always did.

## Files

| File | What it is |
|------|------------|
| `perl-webcam-day-night-command.pl` | the scheduler, and the light meter loop |
| `webcam-preset.pl` | the settings engine: reads the camera, applies a preset |
| `webcam-GUI.pl` | the control window: every camera control, presets, light meter |
| `Webcam-settings.pl` | the older, simpler button window |
| `night-sharp-webcam.pl` | wrapper: night |
| `night-mono-sharp-webcam.pl` | wrapper: night without colour |
| `post-sunrise-sharp-webcam.pl` | wrapper: golden morning |
| `day-sharp-webcam.pl` | wrapper: day |
| `bright-sun-sharp-webcam.pl` | wrapper: bright sun |
| `pre-sunset-sharp-webcam.pl` | wrapper: golden evening |
| `~/.webcam-sun-times.conf` | the last sunrise and sunset times, for offline use |
