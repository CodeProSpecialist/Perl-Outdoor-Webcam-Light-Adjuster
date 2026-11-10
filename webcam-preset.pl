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
# Night brightness comes from a long manual exposure, not from the brightness
# control. brightness and gain saturate quickly; exposure is what collects
# more light. The night preset asks for a long exposure, reads it back, and
# steps down until the driver accepts one, because the driver silently clamps
# any exposure that does not fit inside the current frame interval.

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

# On both APIs the manual setting for auto exposure is 1.
my $AE_MANUAL = 1;

# Cold white balance on every preset.
#
# white_balance_temperature sets the colour temperature the camera ASSUMES the
# light to be, not the look of the picture. A low value tells the camera the
# light is warm, so it compensates with blue and the picture comes out cold.
# 2800 is the coldest-looking setting most webcams accept; anything lower is
# clamped to the camera's own minimum.
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
        sharpness => 109, brightness => 255, contrast => 54, saturation => 64,
        gain => 255, exposure => 2047, aepri => 1, focus => 51,
        backlight_compensation => 255, zoom_absolute => 1,
    },
    # Colour noise is most of what makes a dark frame look muddy, so this
    # trades colour for a cleaner, apparently brighter picture.
    night_mono => {
        sharpness => 72, brightness => 255, contrast => 67, saturation => 0,
        gain => 255, exposure => 2047, aepri => 1, focus => 51,
        backlight_compensation => 255, zoom_absolute => 1,
    },
    # These four used to leave backlight_compensation out entirely, which meant
    # it was never sent and so kept whatever the last preset set. Coming off
    # night that is 255, which washes out a daylight picture badly, and because
    # the night preset is the one that runs every evening it was the value that
    # stuck. The numbers below are the modern table's values scaled onto this
    # camera's 0-255 range, the same way the rest of this table was derived.
    golden_am => {
        sharpness => 250, brightness => 170, contrast => 32, saturation => 32,
        gain => 150, exposure => 200, aepri => 0, focus => 0,
        backlight_compensation => 16, zoom_absolute => 1,
    },
    day => {
        sharpness => 250, brightness => 153, contrast => 32, saturation => 32,
        gain => 104, exposure => 4, aepri => 0, focus => 0,
        backlight_compensation => 6, zoom_absolute => 1,
    },
    bright_sun => {
        sharpness => 250, brightness => 153, contrast => 32, saturation => 32,
        gain => 0, exposure => 4, aepri => 0, focus => 0,
        backlight_compensation => 0, zoom_absolute => 1,
    },
    golden_pm => {
        sharpness => 250, brightness => 153, contrast => 32, saturation => 32,
        gain => 104, exposure => 50, aepri => 0, focus => 0,
        backlight_compensation => 16, zoom_absolute => 1,
    },
);

my %MODERN = (
    night => {
        sharpness => 3, brightness => 64, contrast => 20, saturation => 30,
        gain => 100, exposure => 5000, aepri => 0, focus => 51,
        backlight_compensation => 12, zoom_absolute => 0,
    },
    night_mono => {
        sharpness => 2, brightness => 64, contrast => 25, saturation => 0,
        gain => 100, exposure => 5000, aepri => 0, focus => 51,
        backlight_compensation => 12, zoom_absolute => 0,
    },
    golden_am => {        sharpness => 5, brightness => 8, contrast => 28, saturation => 70,
        gain => 45, exposure => 350, aepri => 0, focus => 50,
        backlight_compensation => 10, zoom_absolute => 0,
    },
    day => {
        sharpness => 5, brightness => 0, contrast => 32, saturation => 64,
        gain => 20, exposure => 80, aepri => 0, focus => 50,
        backlight_compensation => 4, zoom_absolute => 0,
    },
    bright_sun => {
        sharpness => 7, brightness => -30, contrast => 40, saturation => 50,
        gain => 0, exposure => 2, aepri => 0, focus => 50,
        backlight_compensation => 0, zoom_absolute => 0,
    },
    golden_pm => {
        sharpness => 5, brightness => 8, contrast => 28, saturation => 70,
        gain => 35, exposure => 250, aepri => 0, focus => 50,
        backlight_compensation => 10, zoom_absolute => 0,
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
set_ctrl($ae_ctrl, $AE_MANUAL);
sleep(1);
set_ctrl($aepri_ctrl, $vals->{aepri});

set_ctrl('sharpness',              $vals->{sharpness});
set_ctrl('brightness',             $vals->{brightness});
set_ctrl('contrast',               $vals->{contrast});
set_ctrl('saturation',             $vals->{saturation});
set_ctrl('gain',                   $vals->{gain});
set_ctrl('backlight_compensation', $vals->{backlight_compensation})
    if defined $vals->{backlight_compensation};

# Focus is set manually so the camera does not hunt in the dark.
set_ctrl($focus_auto, 0);
set_ctrl('focus_absolute', $vals->{focus});
set_ctrl('zoom_absolute',  $vals->{zoom_absolute});

# Cold white balance on every preset. Automatic is only left on when this
# camera has no temperature control, because otherwise it would sit in manual
# at whatever value happened to be set.
if (exists $ctl{'white_balance_temperature'}) {
    set_ctrl($wb_auto, 0);
    set_ctrl('white_balance_temperature', $COLD_WB);
} else {
    set_ctrl($wb_auto, 1);
}

# Exposure last, once the frame settings are in place.
if ($preset eq 'night' || $preset eq 'night_mono') {
    set_long_exposure($vals->{exposure});
} else {
    set_ctrl($exp_ctrl, $vals->{exposure});
}

exit 0;
