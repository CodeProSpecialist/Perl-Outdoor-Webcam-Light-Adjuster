package WebcamRecord;

# The recorder: one ffmpeg per camera, up to four, and one janitor across all
# of them.
#
# This is the piece that makes the webcam program do what a security recorder
# does - keep the video. Each camera gets one ffmpeg of its own holding that
# camera, because a camera is one device and everything else in this program
# wants a frame from it:
#
#   * the archive itself - 1280x720 at 30fps, cut into segments on disk,
#   * a still a minute into the snapshot folder, which is what the light meter,
#     the enhancer and the brain already read and train from,
#   * and a preview frame ten times a second, which the live window draws.
#
# One ffmpeg with three outputs off one input gives all three without ever
# opening a camera twice.
#
# The preview is a PPM rather than a JPEG, already scaled to the size the pane
# draws it at. Both are for Perl/Tk's benefit: Tk::Photo reads PPM with
# nothing added to it where a JPEG needs Tk::JPEG, and Tk::Photo can only
# scale by whole-number subsampling - so ffmpeg does the scaling, being both
# better at it and already running.
#
# IMPORTANT: only one program at a time can stream a USB camera. Nothing else
# may be capturing these devices when the recorder starts, or it will fail to
# open the camera and say so.
#
# Disk: the archive loops. Two limits hold it and the janitor deletes
# oldest-first until both are satisfied - the archive's own size cap (250 GB
# by default, or 100 or 50) and a floor of free space on the filesystem (25
# GB). Neither touches the segment being written, or the clips folder.

use warnings;
use strict;

use File::Basename ();
use File::Path ();
use POSIX ();
use Time::Local ();

our $VERSION = '1.00';

# ---- where everything lives ----
#
# No user name is written into any of these: the environment answers for
# whoever is running the program, which is what makes this work the same from
# a terminal and from cron.

sub home_dir {
    return $ENV{HOME} if $ENV{HOME} && -d $ENV{HOME};
    my @pw = getpwuid($<);
    return $pw[7] if @pw && $pw[7];
    return '.';
}

our $HOME         = home_dir();
our $ARCHIVE_DIR  = $ENV{WEBCAM_ARCHIVE}   || "$HOME/Videos/webcam-archive";
our $CLIPS_DIR    = $ENV{WEBCAM_CLIPS}     || "$HOME/Videos/webcam-clips";
our $SNAPSHOT_DIR = $ENV{WEBCAM_SNAPSHOTS} || "$HOME/Pictures/webcam-sample-images";
our $STATE_DIR    = $ENV{WEBCAM_STATE}     || "$HOME/.cache/webcam";
our $CONF_DIR     = "$HOME/.config/webcam";
# Its own file rather than the Python program's recorder.conf: same folders,
# same archive layout, different format, and two programs writing one
# another's conf would be a fine way to lose both.
our $CONF_FILE    = "$CONF_DIR/recorder.cfg";

our $DEVICE       = $ENV{WEBCAM_DEVICE} || '/dev/video0';
our $MAX_CAMERAS  = 4;
our @ARCHIVE_CAPS = (50, 100, 250);

our $SEGMENT_NAME = '%Y-%m-%d_%H-%M-%S.mp4';
our $SEGMENT_RE   = qr/^(\d{4})-(\d\d)-(\d\d)_(\d\d)-(\d\d)-(\d\d)\.mp4$/;

our %DEFAULTS = (
    cameras             => $DEVICE,   # comma separated, in order
    width               => 1280,
    height              => 720,
    fps                 => 30,
    segment_seconds     => 300,       # five minutes a file
    keep_free_gb        => 25,
    max_archive_gb      => 250,
    archive_dir         => $ARCHIVE_DIR,
    encoder             => 'copy',    # the default, and the reason the
                                      # recorder is cheap: 'copy' writes the
                                      # camera's own mjpeg frames straight to
                                      # disk, so nothing is encoded at all.
                                      # 'h264' re-encodes to about a quarter
                                      # the disk and costs a core per camera.
    crf                 => 23,
    still_every_seconds => 60,
    preview_fps         => 4,         # four a second reads as live to an eye
                                      # watching a driveway, and each frame
                                      # skipped is a decode and an encode not
                                      # paid for
    preview_width       => 640,       # what the panes draw at; the archive
    preview_height      => 360,       # always keeps the full size
    defaults_version    => 2,         # bumped when a default changes in a
                                      # way that should reach a conf file
                                      # already on disk
);

# ---- the settings file ----
#
# key=value, one per line. Not JSON: JSON::PP is core, but writing it by hand
# is how a conf file ends up unreadable to the next person with a text editor,
# and nothing here needs nesting.

sub read_settings {
    my %settings = %DEFAULTS;
    my $seen_file = 0;
    my $seen_version = 0;
    if (open my $fh, '<', $CONF_FILE) {
        $seen_file = 1;
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*(?:#|$)/;
            my ($key, $value) = $line =~ /^\s*([a-z_]+)\s*=\s*(.*?)\s*$/;
            next if !defined $key || !exists $settings{$key};
            $seen_version = int($value || 0) if $key eq 'defaults_version';
            $settings{$key} = $value;
        }
        close $fh;
    }
    # The cheap-recording defaults arrived after this conf format did, so a
    # conf written before them still says h264 and a ten-a-second preview -
    # the expensive combination those defaults exist to avoid. A conf from
    # before that change is brought forward once, and marked, so a later
    # deliberate choice of h264 is left alone.
    if ($seen_file && $seen_version < 2) {
        $settings{$_} = $DEFAULTS{$_}
            for qw(encoder preview_fps preview_width defaults_version);
    }
    $settings{cameras} = join ',', cameras_of(\%settings);
    return \%settings;
}

sub write_settings {
    my ($changes) = @_;
    my $settings = read_settings();
    for my $key (keys %$changes) {
        next if !exists $DEFAULTS{$key};
        $settings->{$key} = $changes->{$key};
    }
    $settings->{cameras} = join ',', cameras_of($settings);
    File::Path::make_path($CONF_DIR);
    if (open my $fh, '>', $CONF_FILE) {
        print {$fh} "# webcam recorder settings - safe to edit by hand\n";
        print {$fh} "$_=$settings->{$_}\n" for sort keys %$settings;
        close $fh;
    }
    else {
        warn "recorder settings not saved: $!\n";
    }
    return $settings;
}

# A sane list of one to four device paths, whatever was in the file.
# Duplicates are dropped rather than accepted: two ffmpegs on one device is
# the "resource busy" failure, and it is better to refuse it here than to show
# it failing in the window.
sub cameras_of {
    my ($settings) = @_;
    my $raw = $settings->{cameras};
    $raw = (ref $raw eq 'ARRAY') ? join(',', @$raw)
                                 : (defined $raw ? $raw : '');
    my (@found, %seen);
    for my $device (split /\s*,\s*/, $raw) {
        next if !length $device || $seen{$device}++;
        push @found, $device;
    }
    @found = ($DEVICE) if !@found;
    @found = @found[0 .. $MAX_CAMERAS - 1] if @found > $MAX_CAMERAS;
    return @found;
}

# Where camera $index (1-based) writes. One camera writes into the archive
# root, so an archive recorded before this existed is still exactly where it
# was; add a second and everything moves into cam1..cam4 folders, with the
# scan treating loose files in the root as camera 1.
sub camera_folder {
    my ($settings, $index) = @_;
    my @cameras = cameras_of($settings);
    return $settings->{archive_dir} if @cameras <= 1 && $index == 1;
    return $settings->{archive_dir} . '/cam' . int($index);
}

sub preview_file { return $STATE_DIR . '/preview-cam' . int($_[0]) . '.ppm'; }

sub ensure_dirs {
    my ($settings) = @_;
    $settings ||= read_settings();
    my @folders = ($settings->{archive_dir}, $CLIPS_DIR, $SNAPSHOT_DIR,
                   $STATE_DIR, $CONF_DIR);
    my @cameras = cameras_of($settings);
    push @folders, camera_folder($settings, $_) for 1 .. scalar @cameras;
    for my $folder (@folders) {
        next if -d $folder;
        File::Path::make_path($folder) or warn "cannot create $folder: $!\n";
    }
    return;
}

# ---- what the cameras can actually do ----

sub _run {
    my (@args) = @_;
    my $pid = open my $fh, '-|';
    return '' if !defined $pid;
    if (!$pid) {
        open STDERR, '>&', \*STDOUT;
        exec { $args[0] } @args or exit 127;
    }
    local $/;
    my $text = <$fh>;
    close $fh;
    return defined $text ? $text : '';
}

# Every /dev/video* that reports a capture format, with its name. A USB webcam
# shows up as two or three /dev/video nodes and only the first hands over
# frames; the others are metadata nodes that look identical until you try to
# stream them. Anything listing no capture format is left out, so the pickers
# only offer nodes that can be recorded.
sub list_devices {
    my @found;
    if (opendir my $dh, '/dev') {
        for my $name (sort grep { /^video/ } readdir $dh) {
            my $path = "/dev/$name";
            my $formats = _run('v4l2-ctl', '-d', $path, '--list-formats');
            next if $formats !~ /\[0\]|Pixel Format/;
            my $label = $path;
            my $info  = _run('v4l2-ctl', '-d', $path, '--info');
            if ($info =~ /Card type\s*:\s*(.+)/) {
                my $card = $1;
                $card =~ s/\s+$//;
                $label = "$path  -  $card";
            }
            push @found, { device => $path, label => $label };
        }
        closedir $dh;
    }
    @found = ({ device => $DEVICE, label => $DEVICE }) if !@found;
    return \@found;
}

# Which input format to ask for. An ONN-class webcam gives 1280x720 at 30fps
# over MJPEG and only 640x480 or so at 30fps over raw YUYV - ask for raw at
# 720p and the driver quietly drops to 10 or 5 frames a second. So MJPEG is
# asked for first whenever the camera lists it at the wanted size.
sub probe_input {
    my ($device, $width, $height) = @_;
    my $listing = _run('v4l2-ctl', '-d', $device, '--list-formats-ext');
    return 'mjpeg' if !length $listing;
    my $wants = $width . 'x' . $height;
    my ($mjpeg, $raw) = (0, 0);
    my @blocks = split /\[\d+\]:\s*'/, $listing;
    shift @blocks;
    for my $block (@blocks) {
        my $fourcc = lc substr $block, 0, 4;
        next if index($block, $wants) < 0;
        $mjpeg = 1 if $fourcc eq 'mjpg' || $fourcc eq 'jpeg';
        $raw   = 1 if $fourcc eq 'yuyv' || $fourcc eq 'nv12' || $fourcc eq 'yu12';
    }
    return 'mjpeg' if $mjpeg;
    return 'yuyv422' if $raw;
    return 'mjpeg';
}

# ffmpeg's image2 muxer can write to a temporary name and rename into place,
# which is the difference between the window reading a finished frame and half
# of one. Older builds lack the option, so it is used only when listed.
our $ATOMIC;
sub _image2_atomic {
    if (!defined $ATOMIC) {
        $ATOMIC = (_run('ffmpeg', '-hide_banner', '-h', 'muxer=image2')
                   =~ /atomic_writing/) ? 1 : 0;
    }
    return $ATOMIC ? ('-atomic_writing', '1') : ();
}

# ---- the command ----
#
# One input, up to three outputs. The segment muxer does the cutting, with
# -strftime so each file is named for the moment it starts - which lets the
# index read a start time off a name without opening the file, and makes a
# date search cheap.

sub build_command {
    my ($settings, $record, $index) = @_;
    $index ||= 1;
    my @cameras = cameras_of($settings);
    $index = 1 if $index < 1;
    $index = scalar @cameras if $index > @cameras;
    my $device = $cameras[$index - 1];
    my ($width, $height, $fps) =
        (int $settings->{width}, int $settings->{height}, int $settings->{fps});
    my $input_format = probe_input($device, $width, $height);

    my @cmd = (
        'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-use_wallclock_as_timestamps', '1',
        '-f', 'v4l2',
        '-input_format', $input_format,
        '-framerate', $fps,
        '-video_size', $width . 'x' . $height,
        '-i', $device,
    );

    if ($record) {
        my $folder = camera_folder($settings, $index);
        File::Path::make_path($folder) if !-d $folder;
        # A raw-only camera cannot be copied - there is nothing in the
        # stream worth keeping as-is - so it is encoded even when copy was
        # asked for. In that case ultrafast, because the point of asking for
        # copy was to not spend a core on this.
        my $preset = $settings->{encoder} eq 'copy' ? 'ultrafast' : 'veryfast';
        my @video = ($settings->{encoder} eq 'copy' && $input_format eq 'mjpeg')
            ? ('-c:v', 'copy')
            : ('-c:v', 'libx264', '-preset', $preset,
               '-crf', int($settings->{crf}), '-pix_fmt', 'yuv420p',
               '-g', $fps * 2);
        push @cmd, '-map', '0:v', @video, '-an',
            '-f', 'segment',
            '-segment_time', int($settings->{segment_seconds}),
            '-segment_format', 'mp4',
            '-reset_timestamps', '1',
            '-strftime', '1',
            $folder . '/' . $SEGMENT_NAME;

        # A still a minute into the folder the light meter and the brain
        # already read. This is what keeps automatic light adjustment and the
        # enhancer working while the camera is held open.
        #
        # Camera 1 only. The brain is trained on one camera's view of one
        # scene, and mixing four views into one corpus would teach it the
        # average of four scenes - which corrects none of them.
        my $every = int($settings->{still_every_seconds});
        $every = 5 if $every < 5;
        my $stills = $index == 1 ? $SNAPSHOT_DIR
                                 : $SNAPSHOT_DIR . '/cam' . $index;
        File::Path::make_path($stills) if !-d $stills;
        push @cmd, '-map', '0:v', '-vf', 'fps=1/' . $every,
            '-q:v', '3', '-strftime', '1', '-f', 'image2',
            _image2_atomic(),
            $stills . '/webcam-%Y%m%d-%H%M%S.jpg';
    }

    # The preview: PPM, already scaled, overwritten in place.
    File::Path::make_path($STATE_DIR) if !-d $STATE_DIR;
    my $pw = int($settings->{preview_width}  || 640);
    my $ph = int($settings->{preview_height} || 360);
    push @cmd, '-map', '0:v',
        '-vf', 'fps=' . int($settings->{preview_fps} || 4)
               . ',scale=' . $pw . ':' . $ph,
        '-update', '1', '-f', 'image2', _image2_atomic(),
        preview_file($index);
    return \@cmd;
}

# ---- the disk ----

# df rather than Filesys::DF, which is not core: one fork, parsed once, and
# nothing to install.
sub free_gb {
    my ($path) = @_;
    return 0 if !defined $path;
    my $out = _run('df', '-kP', $path);
    for my $line (split /\n/, $out) {
        next if $line !~ /^\S+\s+\d+\s+\d+\s+(\d+)\s/;
        return $1 / (1024 * 1024);
    }
    return 0;
}

# Every segment in the archive, oldest first. The start time comes off the
# name, which is why -strftime is worth having: a thousand files sort by date
# without a thousand ffprobe calls.
sub segments {
    my ($folder) = @_;
    $folder ||= read_settings()->{archive_dir};
    my @found;
    my @stack = ($folder);
    while (my $dir = shift @stack) {
        opendir my $dh, $dir or next;
        for my $name (readdir $dh) {
            next if $name eq '.' || $name eq '..';
            my $path = $dir . '/' . $name;
            if (-d $path) { push @stack, $path; next; }
            next if $name !~ $SEGMENT_RE;
            my $started = start_from_name($name);
            next if !defined $started;
            my $size = -s $path;
            next if !defined $size;
            push @found, { path => $path, started => $started, size => $size };
        }
        closedir $dh;
    }
    @found = sort { $a->{started} <=> $b->{started} } @found;
    return \@found;
}

sub start_from_name {
    my ($name) = @_;
    my @parts = File::Basename::basename($name) =~ $SEGMENT_RE;
    return undef if !@parts;
    return eval {
        Time::Local::timelocal($parts[5], $parts[4], $parts[3],
                               $parts[2], $parts[1] - 1, $parts[0]);
    };
}

sub archive_size_gb {
    my ($folder) = @_;
    my $total = 0;
    $total += $_->{size} for @{ segments($folder) };
    return $total / (1024 ** 3);
}

# Recycle the oldest segments until both disk limits are satisfied. This is
# what makes the archive a loop rather than something that grows until the
# disk is gone. Deleting stops at the newest segment whatever the limits say,
# because ffmpeg is still writing that one. Nothing outside the archive folder
# is ever touched, which is why exported clips are written somewhere else.
sub free_space {
    my ($settings, $verbose) = @_;
    $settings ||= read_settings();
    my $folder    = $settings->{archive_dir};
    my $want_free = $settings->{keep_free_gb}   + 0;
    my $cap       = $settings->{max_archive_gb} + 0;
    return (0, 0) if !-d $folder;

    my @rows = @{ segments($folder) };
    my ($removed, $freed) = (0, 0);
    my $reason_for = sub {
        my $held = 0;
        $held += $_->{size} for @rows;
        $held /= (1024 ** 3);
        return sprintf('archive is %.1f GB, over its %d GB cap', $held, $cap)
            if $cap > 0 && $held > $cap;
        my $free = free_gb($folder);
        return sprintf('only %.1f GB free, under the %d GB floor',
                       $free, $want_free)
            if $free < $want_free;
        return '';
    };

    while (@rows) {
        my $reason = $reason_for->();
        last if !length $reason;
        if (@rows <= 1) {
            warn "archive janitor: $reason, and nothing old enough to delete "
                 . "in $folder - the disk needs attention, or lower the "
                 . "free-space floor\n";
            last;
        }
        my $row = shift @rows;
        if (!unlink $row->{path}) {
            warn "archive janitor could not delete $row->{path}: $!\n";
            next;
        }
        $removed++;
        $freed += $row->{size} / (1024 ** 3);
        print "deleted $row->{path}\n" if $verbose;
    }

    # Tidy away a camera folder left empty because that camera was removed.
    # The path is built into a variable and checked first, because a path
    # assembled inline is one typo away from naming something else entirely.
    if (length $folder && opendir my $dh, $folder) {
        for my $name (readdir $dh) {
            next if $name !~ /^cam\d+$/;
            my $spent = $folder . '/' . $name;
            next if !-d $spent;
            rmdir $spent;           # fails harmlessly when not empty
        }
        closedir $dh;
    }
    warn sprintf("archive janitor recycled %d segment(s), %.1f GB, to stay "
                 . "under a %d GB archive with %d GB free\n",
                 $removed, $freed, $cap, $want_free) if $removed;
    return ($removed, $freed);
}

# ---- the recorders ----
#
# One child per camera, started with fork and exec rather than through a
# shell: a device path with anything odd in it then cannot turn into shell
# words, and the pid that comes back is ffmpeg's own rather than a shell's,
# which is what makes stopping it work.
#
# Stopping is INT and then, only if it will not go, KILL: ffmpeg finishes the
# mp4 it is writing when asked politely, where a KILL leaves the last segment
# with no moov atom and it will not play.

sub new {
    my ($class, %args) = @_;
    return bless {
        settings     => $args{settings} || read_settings(),
        children     => {},   # index -> { pid, device, error, pipe, retry }
        recording    => 0,
        last_janitor => 0,
    }, $class;
}

sub cameras { my ($self) = @_; return cameras_of($self->{settings}); }

sub start {
    my ($self, $record) = @_;
    $self->stop;
    $self->{settings} = read_settings();
    ensure_dirs($self->{settings});
    free_space($self->{settings}) if $record;
    $self->{recording} = $record ? 1 : 0;
    my @cameras = $self->cameras;
    $self->_spawn($_) for 1 .. scalar @cameras;
    return $self->is_running;
}

sub _spawn {
    my ($self, $index) = @_;
    my $cmd = build_command($self->{settings}, $self->{recording}, $index);
    my @cameras = $self->cameras;

    # The error pipe is read by the window a line at a time, so that
    # "Device or resource busy" reaches the pane showing nothing rather than
    # scrolling past in a terminal nobody is watching.
    my ($reader, $writer);
    if (!pipe $reader, $writer) {
        warn "cannot make a pipe for camera $index: $!\n";
        return;
    }
    my $pid = fork;
    if (!defined $pid) {
        warn "cannot fork for camera $index: $!\n";
        close $reader;
        close $writer;
        return;
    }
    if (!$pid) {
        close $reader;
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', '/dev/null';
        open STDERR, '>&', $writer;
        POSIX::setsid();
        exec { $cmd->[0] } @$cmd;
        exit 127;
    }
    close $writer;
    _nonblock($reader);
    $self->{children}{$index} = {
        pid     => $pid,
        device  => $cameras[$index - 1],
        started => time,
        error   => '',
        pipe    => $reader,
        retry   => 0,
        delay   => 3,
    };
    return;
}

# A blocking read on that pipe would freeze the window, and the window is the
# only thing reading it. So the handle is non-blocking and read on the timer.
sub _nonblock {
    my ($fh) = @_;
    my $flags = fcntl($fh, POSIX::F_GETFL(), 0) or return 0;
    fcntl($fh, POSIX::F_SETFL(), $flags | POSIX::O_NONBLOCK()) or return 0;
    return 1;
}

sub stop {
    my ($self) = @_;
    for my $index (sort keys %{ $self->{children} }) {
        my $child = $self->{children}{$index} or next;
        kill 'INT', $child->{pid} if $child->{pid};
    }
    # A moment to close their files properly, then insist.
    for (1 .. 40) {
        my $alive = 0;
        for my $index (keys %{ $self->{children} }) {
            my $pid = $self->{children}{$index}{pid} or next;
            $alive++ if waitpid($pid, POSIX::WNOHANG()) == 0 && kill 0, $pid;
        }
        last if !$alive;
        select undef, undef, undef, 0.2;
    }
    for my $index (keys %{ $self->{children} }) {
        my $child = $self->{children}{$index} or next;
        if ($child->{pid}) {
            kill 'KILL', $child->{pid} if kill 0, $child->{pid};
            waitpid $child->{pid}, 0;
        }
        close $child->{pipe} if $child->{pipe};
    }
    $self->{children} = {};
    return;
}

# Called on a timer by the window. Three jobs: read what the children have
# said, restart any that have died, and run the janitor once a minute.
#
# The restart matters more than it looks: a USB camera that is unplugged, or
# re-enumerated by the kernel, or grabbed by something else takes its ffmpeg
# down with it, and a recorder that stays down until somebody notices is not a
# recorder.
sub poll {
    my ($self) = @_;

    for my $index (sort keys %{ $self->{children} }) {
        my $child = $self->{children}{$index} or next;

        if (my $fh = $child->{pipe}) {
            my $buffer = '';
            my $chunk  = '';
            while (sysread($fh, $chunk, 4096)) { $buffer .= $chunk; }
            for my $line (split /\n/, $buffer) {
                $line =~ s/^\s+//;
                $line =~ s/\s+$//;
                next if !length $line;
                $line .= '  <- another program is holding this camera; close '
                       . 'it, or pick a different device'
                    if $line =~ /Device or resource busy|Permission denied/;
                $child->{error} = $line;
                warn "recorder camera $index: $line\n";
            }
        }

        next if !$child->{pid};
        next if waitpid($child->{pid}, POSIX::WNOHANG()) == 0;
        # It has exited. Count down on the timer, then start it again.
        $child->{pid} = 0;
        $child->{retry} ||= $child->{delay} || 3;
        warn "camera $index stopped; restarting in $child->{retry}s\n";
    }

    for my $index (sort keys %{ $self->{children} }) {
        my $child = $self->{children}{$index} or next;
        next if $child->{pid};
        if ($child->{retry} > 0) {
            $child->{retry}--;
            next;
        }
        my $delay = ($child->{delay} || 3) * 2;
        $delay = 60 if $delay > 60;
        close $child->{pipe} if $child->{pipe};
        $self->_spawn($index);
        $self->{children}{$index}{delay} = $delay if $self->{children}{$index};
    }

    if ($self->{recording} && time - ($self->{last_janitor} || 0) >= 60) {
        $self->{last_janitor} = time;
        free_space($self->{settings});
    }
    return;
}

sub is_running {
    my ($self) = @_;
    for my $index (keys %{ $self->{children} }) {
        my $pid = $self->{children}{$index}{pid} or next;
        return 1 if kill 0, $pid;
    }
    return 0;
}

# The whole set as one hash of facts, for the disk readout and the panes.
sub status {
    my ($self) = @_;
    my $settings = $self->{settings};
    my $folder   = $settings->{archive_dir};
    my $held     = segments($folder);
    my $bytes    = 0;
    $bytes += $_->{size} for @$held;
    my @cameras  = $self->cameras;

    my @per_camera;
    my $live = 0;
    for my $index (1 .. scalar @cameras) {
        my $child = $self->{children}{$index} || {};
        my $running = ($child->{pid} && kill 0, $child->{pid}) ? 1 : 0;
        $live += $running;
        my $mine = segments(camera_folder($settings, $index));
        my $my_bytes = 0;
        $my_bytes += $_->{size} for @$mine;
        push @per_camera, {
            index     => $index,
            device    => $cameras[$index - 1],
            running   => $running,
            recording => ($running && $self->{recording}) ? 1 : 0,
            segments  => scalar @$mine,
            gigabytes => $my_bytes / (1024 ** 3),
            error     => $child->{error} || '',
            retry_in  => $child->{retry} || 0,
            preview   => preview_file($index),
            uptime    => $child->{started} ? time - $child->{started} : 0,
        };
    }

    return {
        running        => $self->is_running,
        recording      => ($self->is_running && $self->{recording}) ? 1 : 0,
        cameras        => scalar @cameras,
        live           => $live,
        segments       => scalar @$held,
        archive_gb     => $bytes / (1024 ** 3),
        free_gb        => free_gb($folder),
        keep_free_gb   => $settings->{keep_free_gb} + 0,
        max_archive_gb => $settings->{max_archive_gb} + 0,
        size           => $settings->{width} . 'x' . $settings->{height},
        fps            => $settings->{fps},
        oldest         => @$held ? File::Basename::basename($held->[0]{path}) : '',
        per_camera     => \@per_camera,
    };
}

1;
