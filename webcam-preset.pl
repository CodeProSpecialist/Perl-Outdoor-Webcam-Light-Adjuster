#!/usr/bin/perl
use warnings;
use strict;

# Shared webcam preset engine.
#
#   ./webcam-preset.pl night|night-mono|golden-am|day|bright-sun|golden-pm [/dev/videoN]
#
# Why this exists: these scripts used to hard-code one camera's numbers. The
# older webcam uses the pre-5.10 kernel control names (exposure_auto,
# exposure_absolute, focus_auto) on 0-255 ranges, while the Walmart ONN webcam
# uses the current names (auto_exposure, exposure_time_absolute) on much
# smaller ranges. The same number means a completely different brightness on
# each. So this reads the control list from the camera that is actually
# plugged in, picks the matching value table, and clamps every value to the
# range that camera reports.
#
# Night brightness comes from a long exposure, not from the brightness
# control. brightness and gain saturate quickly; exposure is what collects
# more light. The camera is left in aperture priority with the dynamic frame
# rate allowed, so it lengthens its own exposure as the light drops rather
# than being pinned to one value chosen at the moment the preset ran. See
# $AE_MODE below for why that beats asking for a long manual exposure.

my $preset = shift(@ARGV) || '';
my $device = shift(@ARGV) || $ENV{WEBCAM_DEVICE} || '/dev/video0';

$preset =~ s/-/_/g;
$preset = lc($preset);

my %VALID = map { $_ => 1 } qw(night night_mono golden_am day bright_sun golden_pm);
unless ($VALID{$preset}) {
    print STDERR "usage: $0 night|night-mono|golden-am|day|bright-sun|golden-pm [/dev/videoN]\n";
    exit 2;
}

# ---- Read the camera's real control list ----
# Lines look like:
#   brightness 0x00980900 (int) : min=0 max=255 step=1 default=128 value=128
sub read_controls {
    my %ctl;
    my @out = `v4l2-ctl -d $device -L 2>/dev/null`;
    for my $line (@out) {
        next unless $line =~ /^\s*(\w+)\s+0x[0-9a-f]+\s+\((?:int|bool|menu|intmenu)\)/i;
        my $name = $1;
        my ($min) = $line =~ /min=(-?\d+)/;
        my ($max) = $line =~ /max=(-?\d+)/;
        # bool controls report no min/max
        ($min, $max) = (0, 1) unless defined $min && defined $max;
        $ctl{$name} = { min => $min, max => $max };
    }
    return %ctl;
}

my %ctl = read_controls();
unless (%ctl) {
    print STDERR "No controls found on $device. Is the camera plugged in?\n";
    exit 1;
}

# ---- Which control set does this camera use? ----
my $modern = exists $ctl{exposure_time_absolute} ? 1 : 0;
my $exp_ctrl    = $modern ? 'exposure_time_absolute'       : 'exposure_absolute';
my $ae_ctrl     = $modern ? 'auto_exposure'                : 'exposure_auto';
my $aepri_ctrl  = $modern ? 'exposure_dynamic_framerate'   : 'exposure_auto_priority';
my $focus_auto  = $modern ? 'focus_automatic_continuous'   : 'focus_auto';
my $wb_auto     = $modern ? 'white_balance_automatic'      : 'white_balance_temperature_auto';

# Exposure mode, used by every preset on both cameras.
#
# Aperture priority (3) rather than manual (1), with the dynamic frame rate
# allowed. The kernel documents EXPOSURE_AUTO_PRIORITY as only having any
# effect while auto exposure is AUTO or APERTURE_PRIORITY - in manual mode it
# does nothing at all - and what it does is let the driver drop the frame rate
# so that a longer exposure fits. In manual mode the exposure can never exceed
# the frame interval, so asking for a long one just got it clamped.
#
# Together these let the camera lengthen its own exposure past the frame
# interval as the light drops, and keep adjusting through the night, instead of
# being pinned to one value chosen when the preset ran.
#
# Set $AE_MODE back to 1 to return to manual, in which case the exposure
# numbers in the tables below are sent and the search for the longest one the
# driver accepts is used again. Both paths are kept working.
my $AE_MODE        = 3;
my $DYN_FRAMERATE  = 1;

# Cold white balance on the presets that ask for it.
#
# white_balance_temperature sets the colour temperature the camera ASSUMES the
# light to be, not the look of the picture. A low value tells the camera the
# light is warm, so it compensates with blue and the picture comes out cold.
# 2800 is the coldest-looking setting most webcams accept; anything lower is
# clamped to the camera's own minimum.
#
# The rows below carry auto_wb => 1 where automatic white balance is wanted
# instead: Day and Golden AM, which are the camera's own defaults, and Golden
# PM, where the light swings from white through orange to dusk inside the hour
# the preset covers. Pinning that to 2800 was wrong twice over - no single
# temperature is right for more than a few minutes of it, and telling the
# camera to expect warm light makes it compensate with blue, cancelling the
# colour of the evening the preset exists to capture.
my $COLD_WB = 2800;

# ---- Value tables ----
# legacy: the numbers already tuned for the older camera, kept as they were.
# modern: the numbers tuned for the ONN webcam.
# Anything the camera does not have is skipped; everything is clamped.
my %LEGACY = (
    # Night was retuned to match the ONN settings, mapped onto this camera's
    # 0-255 ranges rather than copied as raw numbers: brightness and gain to
    # the top, the longest exposure the driver will take, backlight
    # compensation on, and sharpness cut back. Heavy sharpening amplifies
    # sensor noise in the dark, which is why the ONN night preset sits at 3 of
    # 7 rather than near maximum; 109 of 255 is the same proportion. Set
    # sharpness back to 250 here if you prefer the old look.
    night => {
        sharpness => 36, brightness => 140, contrast => 199, saturation => 30,
        gain => 255, exposure => 2047, aepri => 1,
        backlight_compensation => 0, zoom_absolute => 1,
    },
    # Colour noise is most of what makes a dark frame look muddy, so this
    # trades colour for a cleaner, apparently brighter picture.
    night_mono => {
        sharpness => 36, brightness => 140, contrast => 199, saturation => 0,
        gain => 255, exposure => 2047, aepri => 1,
        backlight_compensation => 0, zoom_absolute => 1,
    },
    # backlight_compensation used to be left out of the daylight rows entirely,
    # which meant it was never sent and so kept whatever the last preset set.
    # Coming off night that is 255, which washes out a daylight picture badly,
    # and because the night preset is the one that runs every evening it was
    # the value that stuck. It is always sent now.
    # Day and Golden AM are the camera's own default light settings, taken from
    # the Defaults preset in the ONN settings GUI and scaled onto this camera's
    # 0-255 ranges the same way the night row was: sharpness 3 of 7 -> 109,
    # brightness mid-range -> 128, contrast 32 of 95 -> 86, saturation 64 of
    # 120 -> 136. Both rows are deliberately identical.
    golden_am => {
        sharpness => 109, brightness => 128, contrast => 86, saturation => 136,
        gain => 0, exposure => 60, aepri => 1,
        backlight_compensation => 6, zoom_absolute => 0, auto_wb => 1,
    },
    day => {
        sharpness => 109, brightness => 128, contrast => 86, saturation => 136,
        gain => 0, exposure => 60, aepri => 1,
        backlight_compensation => 6, zoom_absolute => 0, auto_wb => 1,
    },
    bright_sun => {
        sharpness => 250, brightness => 153, contrast => 32, saturation => 32,
        gain => 0, exposure => 4, aepri => 0,
        backlight_compensation => 0, zoom_absolute => 1,
    },
    golden_pm => {
        sharpness => 250, brightness => 153, contrast => 32, saturation => 32,
        gain => 104, exposure => 50, aepri => 0,
        backlight_compensation => 16, zoom_absolute => 1, auto_wb => 1,
    },
);

my %MODERN = (
    # Night brightness and contrast were retuned after measuring a real night
    # frame from this camera. brightness on these webcams is a black level
    # lift, not exposure: it collects no extra light, it only raises the floor.
    # Set near maximum, as it was here, the darkest part of the frame sat at 97
    # of 255 and the whole scene was squeezed into about 45 levels - grey fog
    # with the subject invisible in it. Brightness is now well down and
    # contrast well up, so the range is actually used, and the light comes from
    # the aperture priority exposure instead. backlight_compensation is off at
    # night for the same reason: it lifts shadows, which is more of the fog.
    # Retuned again against a second night frame, with the viewer left at 30
    # fps. At 30 fps the driver caps the exposure near 33 ms, so gain has to
    # stay at 100 and the sensor noise that comes with it cannot be removed by
    # any control here - only a longer exposure would do that. What the
    # controls can still fix is measured on that frame: the 1st percentile sat
    # at 41 of 255, so the sky never reached black and the whole scene was
    # veiled grey. brightness is down to 6 to put the floor back on black,
    # contrast eased to 50 now that the floor is right, saturation down to 14
    # because chroma noise at gain 100 was casting the tarmac cyan-green, and
    # sharpness down to 1 because sharpening at this noise level crisps the
    # grain rather than the subject. Measured after: black point 1 of 255,
    # noise down by a third, and the car at 60 ft reads as a car.
    night => {
        sharpness => 1, brightness => 6, contrast => 50, saturation => 14,
        gain => 100, exposure => 5000, aepri => 0,
        backlight_compensation => 0, zoom_absolute => 0,
    },
    night_mono => {
        sharpness => 1, brightness => 6, contrast => 50, saturation => 0,
        gain => 100, exposure => 5000, aepri => 0,
        backlight_compensation => 0, zoom_absolute => 0,
    },
    # Day and Golden AM are the camera's own default light settings, copied
    # from the Defaults preset in the ONN settings GUI rather than tuned.
    # Both rows are deliberately identical.
    golden_am => {
        sharpness => 3, brightness => 0, contrast => 32, saturation => 64,
        gain => 0, exposure => 157, aepri => 1,
        backlight_compensation => 6, zoom_absolute => 0, auto_wb => 1,
    },
    day => {
        sharpness => 3, brightness => 0, contrast => 32, saturation => 64,
        gain => 0, exposure => 157, aepri => 1,
        backlight_compensation => 6, zoom_absolute => 0, auto_wb => 1,
    },
    bright_sun => {
        sharpness => 7, brightness => -30, contrast => 40, saturation => 50,
        gain => 0, exposure => 2, aepri => 0,
        backlight_compensation => 0, zoom_absolute => 0,
    },
    golden_pm => {
        sharpness => 5, brightness => 8, contrast => 28, saturation => 70,
        gain => 35, exposure => 250, aepri => 0,
        backlight_compensation => 10, zoom_absolute => 0, auto_wb => 1,
    },
);

my $vals = $modern ? $MODERN{$preset} : $LEGACY{$preset};

# ---- Applying ----
sub clamp {
    my ($name, $v) = @_;
    return undef unless exists $ctl{$name};
    my $c = $ctl{$name};
    return $c->{min} if $v < $c->{min};
    return $c->{max} if $v > $c->{max};
    return $v;
}

sub set_ctrl {
    my ($name, $v) = @_;
    return 0 unless defined $name && defined $v;
    my $cv = clamp($name, $v);
    return 0 unless defined $cv;        # camera does not have this control
    system("v4l2-ctl -d $device --set-ctrl $name=$cv 2>/dev/null");
    printf("  %-30s %s%s\n", $name, $cv, ($cv != $v ? " (asked $v, clamped)" : ''));
    return 1;
}

sub get_ctrl {
    my ($name) = @_;
    return undef unless exists $ctl{$name};
    my $out = `v4l2-ctl -d $device --get-ctrl $name 2>/dev/null`;
    return ($out =~ /:\s*(-?\d+)/) ? $1 : undef;
}

# Does the driver actually keep this exposure, or does it clamp it?
sub exposure_sticks {
    my ($try) = @_;
    system("v4l2-ctl -d $device --set-ctrl $exp_ctrl=$try 2>/dev/null");
    my $got = get_ctrl($exp_ctrl);
    return (defined $got && $got >= $try * 0.9) ? $got : undef;
}

# Ask for the longest exposure the driver will actually take.
#
# The kernel documents exposure as limited by the frame interval, and the
# driver clamps anything longer without saying so, so the only way to find the
# limit is to ask and read back. This used to try a fixed ladder of fractions
# of what was wanted - 100%, 80%, 60%, 50%, 40%, 30%, 20%, 10% - and keep the
# first one that stuck. That gives away a lot of light, because the real limit
# almost never lands on one of eight fixed steps. Measured against a driver
# that would accept 626: the ladder settled on 500, a fifth of the available
# light thrown away. On the legacy camera with a limit of 333 it settled on
# 204, giving away nearly 40%.
#
# So: try what was asked for, and if that is clamped, binary search for the
# largest value the driver will keep. That costs a handful more calls and
# finds the limit to within a couple of percent instead of within 20.
sub set_long_exposure {
    my ($wanted) = @_;
    my $max = exists $ctl{$exp_ctrl} ? $ctl{$exp_ctrl}{max} : $wanted;
    my $min = exists $ctl{$exp_ctrl} ? $ctl{$exp_ctrl}{min} : 1;
    $min = 1 if $min < 1;
    $wanted = $max if $wanted > $max;

    # The easy case: the driver takes the whole thing.
    my $got = exposure_sticks($wanted);
    if (defined $got) {
        printf("  %-30s %s\n", $exp_ctrl, $got);
        return $got;
    }

    # Clamped. $hi is known to fail, $lo is the longest known to work.
    my ($lo, $hi) = ($min, $wanted);
    my $best = exposure_sticks($lo);
    unless (defined $best) {
        # Even the shortest exposure reads back wrong. Nothing to search.
        my $cur = get_ctrl($exp_ctrl);
        printf("  %-30s %s (driver clamped)\n", $exp_ctrl, defined $cur ? $cur : '?');
        return $cur;
    }

    # Stop once the remaining gap is under 2%, which is far below anything
    # visible, rather than burning calls narrowing it to the last unit.
    my $rounds = 0;
    while ($hi - $lo > 1 && $hi - $lo > $lo * 0.02 && $rounds++ < 16) {
        my $mid = int(($lo + $hi) / 2);
        last if $mid <= $lo || $mid >= $hi;
        my $ok = exposure_sticks($mid);
        if (defined $ok) { ($lo, $best) = ($mid, $ok); }
        else             { $hi = $mid; }
    }

    # Leave the camera on the best value found, since the search may have
    # ended on a failed attempt.
    my $final = exposure_sticks($lo);
    $best = $final if defined $final;
    printf("  %-30s %s (driver clamped from %s)\n", $exp_ctrl, $best, $wanted);
    return $best;
}

printf("%s preset on %s (%s control names)\n",
    $preset, $device, $modern ? 'current' : 'legacy');

# Manual exposure first: on both APIs the exposure value is ignored while
# auto exposure is on, and the driver needs a moment to switch over.
set_ctrl($ae_ctrl, $AE_MODE);
sleep(1);
# Always on, on every preset, rather than the per-preset aepri value that used
# to be sent here. It is what lets the driver trade frame rate for exposure.
set_ctrl($aepri_ctrl, $DYN_FRAMERATE);

set_ctrl('sharpness',              $vals->{sharpness});
set_ctrl('brightness',             $vals->{brightness});
set_ctrl('contrast',               $vals->{contrast});
set_ctrl('saturation',             $vals->{saturation});
set_ctrl('gain',                   $vals->{gain});
set_ctrl('backlight_compensation', $vals->{backlight_compensation})
    if defined $vals->{backlight_compensation};

# Focus is set manually so the camera does not hunt in the dark.
# Continuous autofocus, always, on every preset. Nothing here ever leaves the
# camera in manual focus.
#
# It is switched off and straight back on rather than simply set to 1, because
# the light this preset just changed is what the autofocus has to work with:
# the camera does not always re-run its search on its own, and the first
# seconds after a preset would otherwise come out soft. The pause is there so
# the driver sees the control actually change state - without it the two
# writes can land in the same instant and nothing is re-triggered.
set_ctrl($focus_auto, 0);
select(undef, undef, undef, 0.33);
set_ctrl($focus_auto, 1);
set_ctrl('zoom_absolute',  $vals->{zoom_absolute});

# White balance. Automatic where the preset asks for it, and also when this
# camera has no temperature control at all, because otherwise it would sit in
# manual at whatever value happened to be set. Everything else gets the cold
# setting. Automatic is always sent explicitly rather than left alone, since
# the previous preset may have switched it off.
if ($vals->{auto_wb} || !exists $ctl{'white_balance_temperature'}) {
    set_ctrl($wb_auto, 1);
} else {
    set_ctrl($wb_auto, 0);
    set_ctrl('white_balance_temperature', $COLD_WB);
}

# Exposure last, once the frame settings are in place.
#
# In aperture priority the camera sets its own exposure and the manual control
# goes inactive, so there is nothing to send and nothing to search for. Read
# back what it settled on instead, so the output still says what the camera is
# actually doing.
if ($AE_MODE == 1) {
    if ($preset eq 'night' || $preset eq 'night_mono') {
        set_long_exposure($vals->{exposure});
    } else {
        set_ctrl($exp_ctrl, $vals->{exposure});
    }
} else {
    sleep(1);                      # let the auto exposure settle before reading
    my $got = get_ctrl($exp_ctrl);
    printf("  %-30s %s (chosen by the camera, aperture priority)\n",
        $exp_ctrl, defined $got ? $got : '?');
}

exit 0;
