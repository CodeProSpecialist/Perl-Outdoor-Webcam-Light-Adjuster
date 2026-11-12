package WebcamEnhance;

# Night image enhancement: frame averaging, CLAHE, and an auto correct.
#
# This is the part of the picture that no camera control can reach.
#
# The presets and the light meter work the camera itself - gain, exposure,
# brightness - and that is the right place to start, because a control change
# adds real signal to the sensor's own output. But a small sensor behind a slow
# lens at 55 to 75 feet in the dark runs out of photons long before it runs out
# of gain, and past that point every further step of gain amplifies noise and
# nothing else. What is left to do has to be done to the picture afterwards.
#
# Three things are done here, in this order, because each makes the next work
# better:
#
#   1. Frame averaging. The snapshots in the picture folder are consecutive
#      stills of the same scene, so averaging the newest few cancels sensor
#      noise while leaving the scene alone - noise falls as the square root of
#      the number of frames, so eight frames is about two and a half times less
#      noise, which at high gain is the largest single improvement available.
#      Anything that moved during the stack blurs, which is the price, and for
#      a parked vehicle it costs nothing.
#
#   2. CLAHE - contrast-limited adaptive histogram equalization. Ordinary
#      contrast stretching works on the whole frame at once, so a security
#      light in one corner sets the scale for everything and the dark half
#      stays dark. CLAHE works on small tiles and limits how far each one may
#      stretch, which pulls detail out of the shadows without blowing the
#      bright parts.
#
#   3. An auto correct, which lifts what is left in a way that keeps the
#      scene's own light and shade rather than flattening it.
#
# What this does NOT do, and cannot: it does not change what the recording
# software records. The recorder holds the camera and owns the video; these are
# corrected copies of the stills, written to an `enhanced` folder beside them
# in the same picture folder. That is the honest limit of working from
# snapshots. The presets and the light meter remain the only things that affect
# the recording itself.
#
# Which tools do the work:
#
#   * ImageMagick does all three on its own, and is all that is needed. On
#     ImageMagick 7 - Ubuntu 26.04 - the CLAHE is the real operator. On
#     ImageMagick 6 there is no -clahe at all and a global contrast stretch
#     stands in for it, which is weaker on exactly the scenes that need it
#     most; the status line says when that is what happened.
#
#   * If webcam_enhance.py from the Python version of these scripts is sitting
#     next to this file or in the home directory, it is used instead. That one
#     can do the same work through OpenCV, which is faster and gives a true
#     per-tile CLAHE, and it can run a trained ML model when there is one. The
#     two share one settings file, so a box ticked in either window means the
#     same thing to both.
#
# Both switches live in ~/.webcam-enhance.conf so that the window and the
# scheduler agree about them - tick the box in the window and the scheduler
# running under cron picks it up on its next pass.

use strict;
use warnings;

our $VERSION = '1.00';

# ---- where things are ----

# os.path.expanduser's equivalent: $HOME when it is set, and the password
# database when it is not, which is what happens under some cron and systemd
# setups. No user name is written into any of this.
sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME};
    my @pw = getpwuid($<);
    return $pw[7] if @pw > 7 && defined $pw[7];
    return '.';
}

our $CONF_FILE = $ENV{WEBCAM_ENHANCE_CONF} || home_dir() . '/.webcam-enhance.conf';

# The same two key names the Python version writes, so one file serves both.
our $KEY_NIGHT   = 'night_clahe_ml';
our $KEY_ALL_DAY = 'all_day_clahe_ml';
# Find the car or the person and aim a second, stronger correction at them.
# Independent of the two above: it only does anything on a frame that is being
# corrected at all, because the detector needs the correction to see.
our $KEY_DETECT  = 'detect_and_boost';

# Where the brain's training frames come from. Two switches, because the two
# sources are not the same kind of thing and a camera that is held by the
# recorder can only offer the first of them.
#
#   train_from_pictures - train on the snapshot folder, which is what the
#       light meter has been filling all along: real frames of the real scene
#       in the real light, which is the whole reason this brain beats a general
#       one. This is the one to leave on.
#
#   train_from_camera - grab a short burst off the camera itself and train on
#       that. Only possible while the camera is free: a V4L2 device lets one
#       program stream at a time, so when the recording software holds it this
#       finds nothing and says who has it rather than failing quietly.
our $KEY_TRAIN_PICTURES = 'train_from_pictures';
our $KEY_TRAIN_CAMERA   = 'train_from_camera';

# The burst taken off the camera when training direct from it: how many frames
# and how far apart. Spread over a few seconds rather than grabbed back to
# back, because ten frames of one instant are one frame as far as training is
# concerned.
our $BURST_FRAMES   = $ENV{WEBCAM_BURST_FRAMES}  || 12;
our $BURST_SPACING  = 0.75;

# How many consecutive stills to average, and how old the oldest of them may
# be. The window matters: stills twenty minutes apart are two different scenes
# and averaging them smears one over the other. Three minutes at the
# scheduler's usual snapshot rate is a handful of frames of the same night.
our $STACK_FRAMES = $ENV{WEBCAM_STACK} || 8;
our $STACK_WINDOW = 180;

# Corrected copies kept before the oldest go, matching the 30 originals the
# light meter keeps.
our $ENH_KEEP     = 30;
our $ENH_DIR_NAME = 'enhanced';

# What counts as night. Gain is the better test and is what the light meter
# already uses - a camera near the top of its gain range is working in the dark
# whatever the clock says. The mean is the fallback for when the gain could not
# be read: the average grey level of the frame itself, out of 255.
our $NIGHT_GAIN_KNEE = 0.50;
our $NIGHT_MEAN      = 90;

# CLAHE strength. The clip limit is how far one tile may stretch its own
# contrast; past about 4 the noise comes up as fast as the detail.
our $CLAHE_CLIP  = $ENV{WEBCAM_CLAHE_CLIP} || 2.5;
our $CLAHE_TILES = 8;

# Accessors, so that a program which loads this module at run time with
# require can reach these without the compiler warning "used only once" about
# a package variable it has not seen declared yet.
sub key_night    { return $KEY_NIGHT; }
sub key_all_day  { return $KEY_ALL_DAY; }
sub key_detect   { return $KEY_DETECT; }
sub key_train_pictures { return $KEY_TRAIN_PICTURES; }
sub key_train_camera   { return $KEY_TRAIN_CAMERA; }
sub conf_file    { return $CONF_FILE; }
sub stack_depth   { return $STACK_FRAMES; }

# ---- the two switches ----

sub read_settings {
    # The picture folder is the sane default for training, so it starts on
    # rather than off: a brain trained on this camera's own frames is the
    # point of the harvest, and a conf file written before these two switches
    # existed should not silently mean "never train".
    my %on = ($KEY_NIGHT => 0, $KEY_ALL_DAY => 0, $KEY_DETECT => 0,
              $KEY_TRAIN_PICTURES => 1, $KEY_TRAIN_CAMERA => 0);
    open my $fh, '<', $CONF_FILE or return \%on;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        next unless $line =~ /^\s*(\w+)\s*=\s*(\S*)/;
        my ($key, $value) = ($1, $2);
        next unless exists $on{$key};
        $on{$key} = ($value =~ /^(1|true|True|yes|on)$/) ? 1 : 0;
    }
    close $fh;
    return \%on;
}

# Change one or both switches, leaving the other as it was. Returns true when
# the file was actually written.
sub write_settings {
    my (%args) = @_;
    my $on = read_settings();
    $on->{$KEY_NIGHT}   = $args{night}   ? 1 : 0 if exists $args{night};
    $on->{$KEY_ALL_DAY} = $args{all_day} ? 1 : 0 if exists $args{all_day};
    $on->{$KEY_DETECT}  = $args{detect}  ? 1 : 0 if exists $args{detect};
    $on->{$KEY_TRAIN_PICTURES} = $args{train_pictures} ? 1 : 0
        if exists $args{train_pictures};
    $on->{$KEY_TRAIN_CAMERA}   = $args{train_camera}   ? 1 : 0
        if exists $args{train_camera};
    open my $fh, '>', $CONF_FILE or return 0;
    print {$fh} "# Written by the webcam settings window. Two switches:\n";
    print {$fh} "#   night image CLAHE and ML auto correct\n";
    print {$fh} "#   24 hour image CLAHE and ML auto correct\n";
    print {$fh} "#   find cars and people and enhance them\n";
    print {$fh} "# And where the brain trains from:\n";
    print {$fh} "#   train the brain from the picture folder\n";
    print {$fh} "#   train the brain direct from the detected webcamera\n";
    print {$fh} "$KEY_NIGHT=$on->{$KEY_NIGHT}\n";
    print {$fh} "$KEY_ALL_DAY=$on->{$KEY_ALL_DAY}\n";
    print {$fh} "$KEY_DETECT=$on->{$KEY_DETECT}\n";
    print {$fh} "$KEY_TRAIN_PICTURES=$on->{$KEY_TRAIN_PICTURES}\n";
    print {$fh} "$KEY_TRAIN_CAMERA=$on->{$KEY_TRAIN_CAMERA}\n";
    close $fh or return 0;
    return 1;
}

# Whether to correct this pass, and why, as (boolean, reason).
#
# The 24 hour switch wins outright. The night switch asks the gain how dark it
# is, and falls back to the picture's own average when the gain could not be
# read.
sub should_enhance {
    my (%args) = @_;
    my $on = read_settings();
    return (1, '24 hour') if $on->{$KEY_ALL_DAY};
    return (0, 'off') unless $on->{$KEY_NIGHT};

    if (defined $args{gain_fraction}) {
        my $percent = sprintf('%.0f', $args{gain_fraction} * 100);
        return $args{gain_fraction} > $NIGHT_GAIN_KNEE
            ? (1, "night, gain at $percent%")
            : (0, "daylight, gain at $percent%");
    }
    if (defined $args{mean}) {
        my $mean = sprintf('%.0f', $args{mean});
        return $args{mean} < $NIGHT_MEAN
            ? (1, "night, picture averaging $mean")
            : (0, "daylight, picture averaging $mean");
    }
    return (0, 'cannot tell night from day yet');
}

# ---- the tools ----

my $MAGICK;
sub magick_cmd {
    return $MAGICK if defined $MAGICK;
    for my $try ('magick', 'convert') {
        if (system("command -v $try >/dev/null 2>&1") == 0) {
            $MAGICK = $try;
            return $MAGICK;
        }
    }
    $MAGICK = '';
    return $MAGICK;
}

# Whether this ImageMagick knows -clahe, which arrived in version 7. On
# ImageMagick 6 the operator does not exist and the command fails, so a limited
# contrast stretch stands in - less good, and still better than nothing.
my $HAS_CLAHE;
sub magick_has_clahe {
    return $HAS_CLAHE if defined $HAS_CLAHE;
    my $im = magick_cmd();
    $HAS_CLAHE = 0;
    if (length $im) {
        my $version = `$im -version 2>/dev/null` || '';
        $HAS_CLAHE = ($version =~ /ImageMagick 7/) ? 1 : 0;
    }
    return $HAS_CLAHE;
}

# The Python enhancer from the other version of these scripts, if it is about.
# Next to this file first, then the home directory, then the working directory
# - the same order the preset wrappers use, because these files get copied to ~
# and run from either place.
my $HELPER;
sub python_helper {
    return $HELPER if defined $HELPER;
    $HELPER = '';
    return $HELPER if $ENV{WEBCAM_NO_PYTHON_ENHANCER};
    my @where = ('.', home_dir());
    if ($0 =~ m{^(.*)/[^/]+$}) { unshift @where, $1; }
    for my $dir (@where) {
        my $path = "$dir/webcam_enhance.py";
        if (-f $path) {
            # Only of use if there is a python3 to run it with.
            if (system('command -v python3 >/dev/null 2>&1') == 0) {
                $HELPER = $path;
                last;
            }
        }
    }
    return $HELPER;
}

sub make_dir_path {
    my ($dir) = @_;
    return 1 if -d $dir;
    my @parts = split m{/}, $dir;
    my $path = '';
    for my $part (@parts) {
        $path .= (length $path ? '/' : '') . $part;
        next if $path eq '' || -d $path;
        mkdir $path or return 0 unless -d $path;
    }
    return -d $dir ? 1 : 0;
}

# ---- the folders ----

# The folder the originals are in. A single configured file or an http URL has
# no folder of its own, so the frame's own directory is used.
sub snap_dir {
    my ($frame, $folder) = @_;
    return $folder if defined $folder && length $folder && -d $folder;
    if (defined $frame && -f $frame && $frame =~ m{^(.*)/[^/]+$}) {
        return $1;
    }
    return undef;
}

# Where the corrected copies go: an `enhanced` folder beside the originals,
# inside the same picture folder, made if it is not there.
#
# A subfolder rather than the same folder, so that the light meter goes on
# measuring the camera's own unenhanced output. Measuring a corrected still
# would close a loop on itself - the correct lifts the picture, the meter sees a
# brighter picture and winds the gain back down, and the camera ends up darker
# than it started.
sub out_dir {
    my ($frame, $folder) = @_;
    my $base = snap_dir($frame, $folder);
    return undef unless defined $base;
    my $out = "$base/$ENH_DIR_NAME";
    return make_dir_path($out) ? $out : undef;
}

# The newest few stills, newest first, all within the time window. The frame
# handed in is always among them, so a single file still gets the rest of the
# treatment with a stack of one.
sub stack_frames {
    my ($frame, $folder) = @_;
    my $dir = snap_dir($frame, $folder);
    return (defined $frame ? ($frame) : ()) unless defined $dir;

    my @shots = grep { -f $_ } (glob("$dir/*.jpg"), glob("$dir/*.jpeg"));
    return (defined $frame ? ($frame) : ()) unless @shots;

    # Newest first.
    @shots = sort { (stat $b)[9] <=> (stat $a)[9] } @shots;
    my $newest = (stat $shots[0])[9];
    my @picked;
    for my $path (@shots) {
        last if @picked >= $STACK_FRAMES;
        next if $newest - (stat $path)[9] > $STACK_WINDOW;
        push @picked, $path;
    }
    return @picked ? @picked : ($shots[0]);
}

# Keep the newest $ENH_KEEP corrected copies and delete the rest.
sub prune {
    my ($folder) = @_;
    return 0 unless defined $folder && -d $folder;
    my @shots = grep { -f $_ } glob("$folder/*.jpg");
    return 0 if @shots <= $ENH_KEEP;
    @shots = sort { (stat $a)[9] <=> (stat $b)[9] } @shots;   # oldest first
    my $gone = 0;
    for my $path (@shots[0 .. $#shots - $ENH_KEEP]) {
        $gone++ if unlink $path;
    }
    return $gone;
}

# A name for this correction that is not already taken. The stills are half a
# minute apart so a plain timestamp is normally unique, but the button in the
# window can be pressed twice in a second and the second press should not
# quietly overwrite the first.
sub new_path {
    my ($folder) = @_;
    my @now = localtime();
    my $stamp = sprintf('enhanced-%04d%02d%02d-%02d%02d%02d',
                        $now[5] + 1900, $now[4] + 1, $now[3],
                        $now[2], $now[1], $now[0]);
    my $path = "$folder/$stamp.jpg";
    my $extra = 2;
    while (-e $path && $extra < 100) {
        $path = "$folder/$stamp-$extra.jpg";
        $extra++;
    }
    return $path;
}

# ---- the measuring ----

# The average grey level of a file, out of 255, or undef.
sub magick_mean {
    my ($path) = @_;
    my $im = magick_cmd();
    return undef unless length $im && defined $path && -f $path;
    my $out = `$im "$path" -colorspace Gray -resize 25% -format "%[fx:mean*255]" info: 2>/dev/null`;
    return ($out =~ /([\d.]+)/) ? $1 + 0 : undef;
}

# ---- the work ----

# Through the Python enhancer, when it is there. It does the same three steps
# with OpenCV and can run a trained model, so it is preferred when available.
sub enhance_with_python {
    my ($frame) = @_;
    my $helper = python_helper();
    return ('', '') unless length $helper;

    my $quoted = $frame;
    $quoted =~ s/'/'\\''/g;
    my $out = `python3 '$helper' '$quoted' 2>&1` || '';
    # Its last useful line is "wrote <path>" followed by the tiers it used.
    if ($out =~ /^wrote (\S+)\s*$/m) {
        my $path = $1;
        my ($how) = ($out =~ /^wrote \S+\s*\n\s+(.+)$/m);
        $how = 'through webcam_enhance.py' unless defined $how && length $how;
        return ($path, "$how [python]") if -f $path;
    }
    return ('', '');
}

# Through ImageMagick, which is all that is actually needed.
#
# It runs in two passes rather than one long command, because the gamma for the
# last step has to be worked out from how dark the stacked and equalized
# picture actually turned out - a fixed gamma is far too little on a frame
# averaging 10 out of 255 and far too much on one averaging 90. The first pass
# writes the stack, the mean is measured off it, and the second does the
# lifting.
sub enhance_with_magick {
    my ($out_path, @frames) = @_;
    my $im = magick_cmd();
    return ('', 'ImageMagick is not installed') unless length $im;
    return ('', 'nothing to correct') unless @frames;

    my @how;
    my $stage = "$out_path.stack.jpg";
    my $inputs = join ' ', map { my $f = $_; $f =~ s/"/\\"/g; "\"$f\"" } @frames;

    my $stack_op = '';
    if (@frames > 1) {
        # The average of the stack, which is what -evaluate-sequence mean is
        # for.
        $stack_op = '-evaluate-sequence mean';
    }
    push @how, 'stacked ' . scalar(@frames);

    my $equalize;
    if (magick_has_clahe()) {
        # Width and height as a percentage of the frame, then the bin count and
        # the clip limit.
        my $tile = int(100 / $CLAHE_TILES);
        $equalize = "-clahe ${tile}x${tile}%+128+$CLAHE_CLIP";
        push @how, 'CLAHE';
    } else {
        $equalize = '-contrast-stretch 0.5%x0.05%';
        push @how, 'contrast stretch (ImageMagick 6 has no CLAHE)';
    }

    system(qq{$im $inputs $stack_op $equalize -quality 95 "$stage" >/dev/null 2>&1});
    return ('', 'ImageMagick could not stack the snapshots')
        unless -f $stage && -s $stage;

    # The auto correct: a gamma worked out from this picture's own average,
    # aimed at 45% grey, then a sigmoidal curve that puts some contrast back
    # into the midtones the gamma flattened. -gamma above 1 brightens, and the
    # darker the frame the larger the number has to be, so this is clamped at
    # both ends rather than trusted blindly on a frame that measured almost
    # nothing.
    my $mean = magick_mean($stage);
    my $gamma;
    if (defined $mean && $mean > 0.5) {
        $gamma = log($mean / 255.0) / log(0.45);
        $gamma = 1.0 if $gamma < 1.0;
        $gamma = 4.0 if $gamma > 4.0;
    } else {
        $gamma = 2.5;
    }
    $gamma = sprintf('%.2f', $gamma);
    system(qq{$im "$stage" -gamma $gamma -sigmoidal-contrast 3,45% }
           . qq{-quality 92 "$out_path" >/dev/null 2>&1});
    push @how, "auto correct (analytic, gamma $gamma)";
    unlink $stage;

    return ('', 'ImageMagick could not write the corrected copy')
        unless -f $out_path && -s $out_path;
    return ($out_path, join(', ', @how));
}

# ---- the harvest: training the brain on THIS camera ----
#
# The frames come from this side; the training is TensorFlow, so it happens
# through train_webcam_brain.py, which ships here beside these scripts. The one
# rule that cannot be bent: only a well exposed frame can be a training target,
# because a dark night frame cannot be its own answer sheet. A dark frame is
# kept only when a well exposed frame of the same scene turns up within a
# couple of minutes to be its answer - which is what dusk, dawn and a light
# coming on provide, and why the harvest is wired to every light change.

our $LAST_PRESET_FILE = $ENV{WEBCAM_LAST_PRESET} || home_dir() . '/.webcam-last-preset';

# Record the preset just applied, so every frame harvested from now on is filed
# under the preset that produced it. Written here and read by the Python side
# too - one line, because the thing that applies a preset and the thing that
# harvests are usually two different processes.
sub note_preset {
    my ($name) = @_;
    return 0 unless defined $name && length $name;
    open my $fh, '>', $LAST_PRESET_FILE or return 0;
    print {$fh} "$name\n" . time() . "\n";
    close $fh or return 0;
    return 1;
}

sub current_preset {
    open my $fh, '<', $LAST_PRESET_FILE or return undef;
    my $name = <$fh>;
    close $fh;
    return undef unless defined $name;
    chomp $name;
    return length $name ? $name : undef;
}

# The trainer script, if it is about. Same search order as the enhancer.
my $TRAINER;
sub trainer_script {
    return $TRAINER if defined $TRAINER;
    $TRAINER = '';
    return $TRAINER if $ENV{WEBCAM_NO_PYTHON_ENHANCER};
    my @where = ('.', home_dir());
    if ($0 =~ m{^(.*)/[^/]+$}) { unshift @where, $1; }
    for my $dir (@where) {
        my $path = "$dir/train_webcam_brain.py";
        next unless -f $path;
        next unless system('command -v python3 >/dev/null 2>&1') == 0;
        $TRAINER = $path;
        last;
    }
    return $TRAINER;
}

sub shell_quote {
    my ($text) = @_;
    $text = '' unless defined $text;
    $text =~ s/'/'\\''/g;
    return "'$text'";
}

# File one still into the training set. Returns a note, or nothing.
sub harvest {
    my (%args) = @_;
    my $trainer = trainer_script();
    return undef unless length $trainer;
    return undef unless defined $args{frame} && -f $args{frame};

    my @cmd = ('python3', shell_quote($trainer), '--harvest',
               shell_quote($args{frame}));
    push @cmd, '--preset', shell_quote($args{preset}) if defined $args{preset};
    push @cmd, '--gain-fraction', sprintf('%.3f', $args{gain_fraction})
        if defined $args{gain_fraction};
    my $out = `@cmd 2>&1` || '';
    for my $line (split /\n/, $out) {
        return $line if $line =~ /^(harvested|not harvested):/;
    }
    return undef;
}

# Retrain on this camera if the harvest has enough. Returns a note.
sub self_train {
    my $trainer = trainer_script();
    return undef unless length $trainer;
    my $out = `python3 @{[ shell_quote($trainer) ]} --self-train --quiet 2>&1` || '';
    my @lines = grep { /\S/ } split /\n/, $out;
    return @lines ? $lines[-1] : undef;
}

# ---- training from a chosen source ----
#
# Two ways in, for the two switches. Both end at the same place: the trainer
# script, with a folder of frames and --force, which is the route the tile has
# always advertised for training by hand. Neither touches the model directly -
# a model is TensorFlow's to write and this is the Perl side.

# Train on a folder of stills. Returns (ok, note).
sub train_from_photos {
    my ($folder) = @_;
    my $trainer = trainer_script();
    return (0, 'train_webcam_brain.py is not here with a python3 to run it')
        unless length $trainer;
    return (0, 'no folder to train from')
        unless defined $folder && length $folder && -d $folder;

    my @shots = grep { -f $_ } (glob("$folder/*.jpg"), glob("$folder/*.jpeg"),
                                glob("$folder/*.png"));
    return (0, "no pictures in $folder yet - the light meter fills it as it runs")
        unless @shots;

    my $out = `python3 @{[ shell_quote($trainer) ]} --photos @{[ shell_quote($folder) ]} --force 2>&1` || '';
    my @lines = grep { /\S/ } split /\n/, $out;
    my $note = @lines ? $lines[-1] : 'the trainer said nothing';
    return (($? == 0 ? 1 : 0), scalar(@shots) . " pictures: $note");
}

# The shell command that trains from a folder, for a caller that wants to run
# it as a child process and watch the log rather than block on it. Training
# takes a minute or two and a minute or two inside an event loop is a frozen
# window.
sub train_from_photos_command {
    my ($folder) = @_;
    my $trainer = trainer_script();
    return '' unless length $trainer;
    return '' unless defined $folder && length $folder;
    return 'python3 ' . shell_quote($trainer)
         . ' --photos ' . shell_quote($folder) . ' --force';
}

# ---- training direct from the camera ----

# Where a burst off the camera is put. Its own folder, not the picture folder:
# the light meter measures the newest still in there and a burst of twelve
# would have it measuring frames nobody asked for.
sub camera_training_dir {
    my $dir = $ENV{WEBCAM_CAMERA_TRAINING_DIR}
           || home_dir() . '/Pictures/webcam-camera-training';
    return make_dir_path($dir) ? $dir : undef;
}

# Who holds the camera, if anyone - the same question the window asks before
# grabbing a snapshot, asked again here because the scheduler and the Python
# side call this too and neither goes through the window.
#
# This is the whole difficulty with training direct from the camera. A V4L2
# device lets one program stream at a time, and on a machine that is recording
# the recorder has it. Worse than failing would be succeeding at the wrong
# moment: if the recorder drops and re-opens its stream just as a grab lands,
# the grab wins and the recorder does not come back. So when anything else
# holds the device, nothing is sent to it.
sub camera_holder {
    my ($dev) = @_;
    return undef unless defined $dev && -e $dev;

    if (system('command -v fuser >/dev/null 2>&1') == 0) {
        my $out = `fuser -v $dev 2>&1` || '';
        my %names;
        for my $line (split /\n/, $out) {
            next unless $line =~ /^\s*\S*\s+(\d+)\s+\S+\s+(\S+)\s*$/;
            my ($pid, $name) = ($1, $2);
            next if $pid == $$;
            $names{"$name (pid $pid)"} = 1;
        }
        return join(', ', sort keys %names) if %names;
    }
    if (system('command -v lsof >/dev/null 2>&1') == 0) {
        my $out = `lsof -F cp $dev 2>/dev/null` || '';
        my ($pid, %names);
        for my $line (split /\n/, $out) {
            $pid = $1 if $line =~ /^p(\d+)/;
            if ($line =~ /^c(\S+)/ && defined $pid && $pid != $$) {
                $names{"$1 (pid $pid)"} = 1;
            }
        }
        return join(', ', sort keys %names) if %names;
    }
    return undef;
}

# Grab a short burst off the camera into the training folder.
# Returns (count, folder, note).
sub capture_training_burst {
    my ($dev, $frames) = @_;
    $dev    = '/dev/video0' unless defined $dev && length $dev;
    $frames = $BURST_FRAMES unless defined $frames && $frames > 0;

    return (0, undef, "$dev does not exist - is the camera plugged in?")
        unless -e $dev;
    return (0, undef, 'ffmpeg is not installed, so no frames can be grabbed')
        unless system('command -v ffmpeg >/dev/null 2>&1') == 0;

    my $holder = camera_holder($dev);
    return (0, undef, "$holder has $dev, so the camera cannot be grabbed from "
                    . 'while that is running - training from the picture folder '
                    . 'instead is the way round it')
        if defined $holder;

    my $dir = camera_training_dir();
    return (0, undef, 'nowhere to put the frames') unless defined $dir;

    # Everything from a previous burst goes first. A burst is a set of frames
    # of one scene in one light, and mixing tonight's with last week's is how a
    # training folder quietly becomes a folder of two different places.
    unlink $_ for grep { -f $_ } glob("$dir/*.jpg");

    my @t = localtime();
    my $stamp = sprintf('%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);

    my $got = 0;
    for my $n (1 .. $frames) {
        my $path = sprintf('%s/camera-%s-%02d.jpg', $dir, $stamp, $n);
        my $rc = system("ffmpeg -nostdin -loglevel error -f v4l2 -i $dev"
                      . " -frames:v 1 -q:v 2 -y '$path' 2>/dev/null");
        if ($rc == 0 && -s $path) {
            $got++;
        } else {
            unlink $path if -e $path;
            # The first frame failing is the camera refusing; the fifth failing
            # is a hiccup. Only the first is worth stopping for.
            last if $n == 1;
        }
        select(undef, undef, undef, $BURST_SPACING) if $n < $frames;
    }

    return (0, $dir, "ffmpeg could not grab a frame from $dev - another program "
                   . 'may have taken it, or this user may not be in the video group')
        unless $got;
    return ($got, $dir, "grabbed $got frames from $dev");
}

# Grab a burst and train on it. Returns (ok, note).
sub train_from_camera {
    my ($dev) = @_;
    my ($got, $dir, $note) = capture_training_burst($dev);
    return (0, $note) unless $got;
    my ($ok, $trained) = train_from_photos($dir);
    return ($ok, "$note; $trained");
}

# Which sources the switches have selected, as a list of (label, folder) pairs
# ready to train from. The camera one grabs its burst here, so a caller gets
# back only folders that actually have frames in them.
sub training_sources {
    my (%args) = @_;
    my $on = read_settings();
    my @sources;
    my @notes;

    if ($on->{$KEY_TRAIN_CAMERA}) {
        my ($got, $dir, $note) = capture_training_burst($args{device});
        push @notes, $note;
        push @sources, [ 'the camera', $dir ] if $got && defined $dir;
    }
    if ($on->{$KEY_TRAIN_PICTURES}) {
        my $dir = $args{folder};
        if (defined $dir && -d $dir) {
            push @sources, [ 'the picture folder', $dir ];
        } else {
            push @notes, 'no picture folder to train from';
        }
    }
    unless ($on->{$KEY_TRAIN_CAMERA} || $on->{$KEY_TRAIN_PICTURES}) {
        push @notes, 'both training switches are off, so the brain is not being trained';
    }
    return (\@sources, join('; ', @notes));
}

# What has been harvested, as the index the Python side keeps.
sub corpus_state {
    my $trainer = trainer_script();
    return undef unless length $trainer;
    my $out = `python3 @{[ shell_quote($trainer) ]} --corpus-state 2>&1` || '';
    return undef unless length $out;
    return $out;
}

# ---- brain G's details, for the window's tile ----
#
# Brain G is the trained night vision brain. It runs through webcam_enhance.py,
# because the brain is a TensorFlow model and that is the side of these two
# repositories that can load one; what this side does is find it, read what it
# says about itself, and lay that out for the window. The ImageMagick path
# needs none of it and works without any of this being present.

sub brain_dirs {
    my @where;
    push @where, $ENV{WEBCAM_BRAIN_DIR} if $ENV{WEBCAM_BRAIN_DIR};
    push @where, home_dir() . '/.webcam-models/brain_g_night_model';
    my $here = ($0 =~ m{^(.*)/[^/]+$}) ? $1 : '.';
    push @where, "$here/brain_g_night_model";
    push @where, './brain_g_night_model';
    return @where;
}

# meta.json as a hash. JSON::PP has been core since Perl 5.14, so it is there;
# if it somehow is not, the few values wanted are pulled out with a regex
# rather than giving up on the whole tile.
sub read_json {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return undef unless defined $text && length $text;

    if (eval { require JSON::PP; 1 }) {
        my $data = eval { JSON::PP->new->decode($text) };
        return $data if ref $data eq 'HASH';
    }
    my %flat;
    while ($text =~ /"(\w+)"\s*:\s*"([^"]*)"/g) { $flat{$1} = $2; }
    while ($text =~ /"(\w+)"\s*:\s*(-?[\d.]+)/g)  { $flat{$1} = $2 + 0; }
    return \%flat;
}

# The brain, if there is one: (folder, meta hashref), or an empty list.
sub brain_meta {
    for my $dir (brain_dirs()) {
        next unless -f "$dir/model.keras";
        my $meta = read_json("$dir/meta.json") || {};
        return ($dir, $meta);
    }
    return ();
}

# What has been harvested from this camera, and what happens next. The harvest
# is the part worth watching: it is what makes the brain this camera's rather
# than a general one, and it is the valuable half - a model can be deleted and
# retrained from it in a minute, the frames cannot be got back without waiting
# another day.
sub brain_harvest_text {
    my ($meta) = @_;
    $meta = {} unless ref $meta eq 'HASH';

    my $text = "TRAINING ON THIS CAMERA\n"
      . "  Every pass files a still into a training set, tagged with the preset\n"
      . "  and how hard the camera was working, and a preset or light change\n"
      . "  files one immediately. Once there is a spread across the presets and\n"
      . "  the day, it retrains on them and deletes the shipped brain. Only\n"
      . "  well-exposed frames can be training targets: a dark frame cannot be\n"
      . "  its own answer sheet, so one is kept only when a well-exposed frame of\n"
      . "  the same scene lands within a couple of minutes to be its answer -\n"
      . "  dusk, dawn, or a light coming on.\n\n";

    unless (length trainer_script()) {
        return $text
          . "  train_webcam_brain.py is not here with a python3 to run it, so\n"
          . "  nothing is being harvested and the brain cannot retrain itself.\n";
    }

    $text .= sprintf("  %-22s %s\n", 'trained from',
        $meta->{trained_from} || 'not trained yet');
    my $state = corpus_state();
    if (defined $state) {
        for my $line (split /\n/, $state) {
            next unless $line =~ /\S/;
            $text .= "  $line\n";
        }
    } else {
        $text .= "  could not read the harvest\n";
    }

    my $against = ref $meta->{against_shipped} eq 'HASH' ? $meta->{against_shipped} : undef;
    if ($against) {
        $text .= "\n  Against the shipped brain, on the same held-back frames\n"
               . "  from this camera:\n";
        $text .= sprintf("      %-20s %s dB\n", "this camera's brain",
            $against->{own_psnr_db} // '?');
        $text .= sprintf("      %-20s %s dB\n", 'the shipped brain',
            $against->{shipped_psnr_db} // '?');
        $text .= sprintf("      %-20s %s\n", 'shipped brain',
            $against->{shipped_deleted}
                ? 'deleted'
                : 'KEPT - the new one scored worse, so it was not thrown away; '
                  . 'it will retrain tomorrow');
    }

    $text .= "\n  To train it by hand on a folder of clear photos instead:\n"
           . "    python3 train_webcam_brain.py --photos <that folder> --force\n";
    return $text;
}

# (headline, text) for the tile.
sub brain_info_text {
    my ($dir, $meta) = brain_meta();
    my $helper = python_helper();

    unless (defined $dir) {
        my $looked = join("\n", map { "    $_" } brain_dirs());
        return ('no trained brain found - the analytic correct is doing the work',
                "Looked in, in this order:\n$looked\n\n"
              . "The analytic correct still runs, so the two switches above still\n"
              . "do something - it works out one gamma for the whole frame from the\n"
              . "frame's own average, rather than a gain for every pixel.\n\n"
              . brain_harvest_text({}));
    }

    my $headline = length $helper
        ? "loaded from $dir"
        : "found in $dir, but webcam_enhance.py is not here to run it";

    my $text = "WHAT IT DOES\n"
      . "  Predicts, for every pixel, how much to lift its brightness and\n"
      . "  what to do with its colour afterwards. Trained on clear photos:\n"
      . "  each one was darkened with a camera model and the brain learned\n"
      . "  its way back to the original. A per-pixel gain is why a car in\n"
      . "  shadow can be lifted hard while the light above it is left alone.\n\n";

    unless (length $helper) {
        $text .= "NOT RUNNING HERE\n"
          . "  The brain is a TensorFlow model, and this is the Perl side. To use\n"
          . "  it, put webcam_enhance.py and train_webcam_brain.py next to these\n"
          . "  scripts (they ship in this repository) and have python3 with\n"
          . "  TensorFlow installed. Until then the ImageMagick path does the\n"
          . "  work: stacking, CLAHE and the analytic correct.\n\n";
    }

    my $row = sub {
        my ($label, $value) = @_;
        $value = '?' unless defined $value && length $value;
        return sprintf("  %-22s %s\n", $label, $value);
    };

    $text .= "MODEL\n";
    $text .= $row->('architecture', $meta->{architecture});
    $text .= $row->('features per pixel', $meta->{feature_count});
    $text .= $row->('most it may lift', defined $meta->{gain_max} ? "$meta->{gain_max}x" : undef);
    $text .= $row->('foundation', 'FROZEN, hand weighted, never trained');
    if (ref $meta->{foundation_units} eq 'ARRAY') {
        $text .= "  frozen units\n";
        my $index = 0;
        for my $unit (@{ $meta->{foundation_units} }) {
            $text .= sprintf("      %d  %s\n", $index++, $unit);
        }
    }
    $text .= "\n";

    $text .= "TRAINING\n";
    $text .= $row->('pretrain samples',
        defined $meta->{pretrain_samples}
            ? "$meta->{pretrain_samples} (cap " . ($meta->{pretrain_cap} // '?') . ')'
            : undef);
    $text .= $row->('epochs run',
        defined $meta->{epochs_run}
            ? "$meta->{epochs_run} of " . ($meta->{epochs_max} // '?')
              . ', early stopping on the held-back photos'
            : undef);
    $text .= $row->('clear photos used',
        defined $meta->{photos_trained_on}
            ? "$meta->{photos_trained_on} trained on, "
              . ($meta->{photos_held_back} // '?') . ' held back'
            : undef);
    $text .= $row->('photo folder', $meta->{photo_folder});
    $text .= $row->('trained', $meta->{trained_at});
    $text .= $row->('tensorflow', $meta->{tensorflow});
    $text .= "\n";

    $text .= "HOW WELL IT DID\n";
    my ($val, $flat) = ($meta->{val_loss}, $meta->{flat_answer_val_loss});
    my $better = '';
    if (defined $val && defined $flat && $flat) {
        $better = sprintf('  (%.0f%% better than a flat answer)', 100 * (1 - $val / $flat));
    }
    $text .= $row->('val loss', defined $val ? sprintf('%.5f%s', $val, $better) : undef);
    $text .= $row->('a flat answer scores', defined $flat ? sprintf('%.5f', $flat) : undef);
    $text .= $row->('val mean error',
        defined $meta->{val_mae} ? sprintf('%.4f', $meta->{val_mae}) : undef);
    $text .= "  The photos it was scored on were held back whole, not by pixel,\n"
           . "  so no crop it trained on appears in the score.\n\n";

    my $scored = ref $meta->{evaluation} eq 'HASH' ? $meta->{evaluation} : undef;
    if ($scored && defined $scored->{brain_psnr_db}) {
        $text .= "THE FINISHED PICTURE, ON THOSE SAME HELD-BACK PHOTOS\n"
               . "  Eight degraded frames of each, run through the real pipeline\n"
               . "  and compared with the clear original. Higher is better.\n\n";
        $text .= sprintf("    %-22s%9s%8s\n", 'stage', 'PSNR dB', 'SSIM');
        for my $pair (['dark_input', 'one dark frame'],
                      ['stack_and_clahe', 'stacked + CLAHE'],
                      ['analytic', '+ analytic correct'],
                      ['brain', '+ brain G']) {
            my ($key, $label) = @$pair;
            next unless defined $scored->{"${key}_psnr_db"};
            my $sim = $scored->{"${key}_ssim"};
            $text .= sprintf("    %-22s%9.2f%8s\n", $label, $scored->{"${key}_psnr_db"},
                defined $sim ? sprintf('%.3f', $sim) : '-');
        }
        if (defined $scored->{brain_beats_analytic_db}) {
            $text .= sprintf("\n  The brain is %+.2f dB on the analytic correct, which is\n"
                           . "  what runs when there is no brain to load.\n",
                $scored->{brain_beats_analytic_db});
        }
        $text .= "\n";
    }

    $text .= "ON DISK\n";
    $text .= $row->('folder', $dir);
    my $digest = $meta->{model_sha256} || '';
    $text .= $row->('sha256', length $digest ? substr($digest, 0, 32) . '...' : 'not recorded');
    # The mode bits, not -w: root can write to a 0444 file, so -w would report a
    # read-only model as writable and the line would be wrong where it matters.
    my $mode = (stat "$dir/model.keras")[2];
    $text .= $row->('read-only', !defined $mode ? 'cannot tell'
        : ($mode & 0222) == 0 ? 'yes - locked, and inference never writes to it'
        : 'writable (a git clone comes back this way); inference still never '
          . "writes to it. To lock it: chmod 444 $dir/model.keras");
    $text .= "\n";

    $text .= brain_harvest_text($meta);

    return ($headline, $text);
}

# ---- the two calls the rest of the programs make ----

# Correct this still whatever the switches say, and return (path, how).
#
# This is what the button in the window calls. Asking for it by hand is itself
# the instruction, so the switches are not consulted - they decide what happens
# automatically, not what may be done on request.
sub enhance_now {
    my ($frame, $folder) = @_;
    return ('', 'there is no snapshot to correct')
        unless defined $frame && -f $frame;

    my $out = out_dir($frame, $folder);
    return ('', 'nowhere to write the corrected copy') unless defined $out;

    # The Python enhancer first, when it is installed: it writes into the same
    # enhanced folder and does the better job of it.
    my ($written, $how) = enhance_with_python($frame);
    if (length $written) {
        prune($out);
        return ($written, $how);
    }

    my @frames = stack_frames($frame, $folder);
    ($written, $how) = enhance_with_magick(new_path($out), @frames);
    prune($out) if length $written;
    return ($written, $how);
}

# One pass for the light meter: correct the current still when the switches say
# to, and return a status line, or nothing when there was nothing to do.
sub enhance_pass {
    my (%args) = @_;
    my ($on, $why) = should_enhance(gain_fraction => $args{gain_fraction},
                                    mean          => $args{mean});
    return (undef, $why) unless $on;

    my ($written, $how) = enhance_now($args{frame}, $args{folder});
    return ("enhance: $how", $how) unless length $written;

    my $name = $written;
    $name =~ s{^.*/}{};
    return ("enhance: $name [$why] $how", "$why - $how");
}

# One line for the window saying what is installed and what is not, so a
# missing piece shows before it is needed rather than as a silent lack of
# improvement.
sub report {
    my @parts;
    my $helper = python_helper();
    if (length $helper) {
        push @parts, 'webcam_enhance.py (OpenCV and any ML model)';
    } elsif (magick_has_clahe()) {
        push @parts, 'ImageMagick 7, real CLAHE';
    } elsif (length magick_cmd()) {
        push @parts, 'ImageMagick 6, contrast stretch instead of CLAHE';
    } else {
        push @parts, 'nothing installed - ImageMagick is needed';
    }
    push @parts, "stack of $STACK_FRAMES";
    return 'enhancement: ' . join(', ', @parts);
}

1;
