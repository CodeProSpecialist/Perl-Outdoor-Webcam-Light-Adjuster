#!/usr/bin/perl
use warnings;
use strict;

# The main window: live video first, with the settings page behind it.
#
# This is the front door of the program now. Three pages across the top:
#
#   Live      the video, up to four cameras at once. Start and stop recording,
#             pick the devices, see the disk.
#   Archive   the index: search by date, by time of day or by one click back
#             from now, play a segment with a seek bar, and cut a clip out.
#   Settings  the window that used to be the whole program - every camera
#             control, the presets, the light meter, the brain, the lock
#             panel - running inside this one's Settings tab.
#
# The video is drawn from the frame each recorder writes ten times a second
# rather than by opening the cameras here. That is the point of the
# arrangement: one process holds each camera and everything else reads what it
# publishes, so the preview, the stills the brain trains on, and the recording
# never fight over a device.
#
# It opens recording. A security recorder that waits to be told to record has
# already missed whatever happened while it waited, and the loop cap is what
# makes that safe: recording from the moment it opens can only ever use the
# archive's own cap, and the oldest footage is recycled rather than the disk
# filling up.
#
#     perl webcam-gui.pl
#
# The settings page still runs on its own: perl webcam-settings-page.pl opens
# it in a window of its own, exactly as it did when it was the whole program.

# First run: check the modules this script needs are installed, and offer to
# install the apt packages that provide them if they are not. This has to
# happen in BEGIN, before the `use` lines below: `use` is a compile-time step,
# so by the time ordinary code could check anything the script has already
# died with "Can't locate ... in @INC". That error names @INC and never names
# the apt package, which is the whole problem.
BEGIN {
    require File::Basename;
    require Cwd;

    my @dirs = (
        File::Basename::dirname(Cwd::abs_path(__FILE__)),
        ($ENV{HOME} ? ($ENV{HOME}) : ()),
        '.',
    );
    for my $dir (@dirs) {
        next if !-r "$dir/WebcamBootstrap.pm";
        unshift @INC, $dir;
        require WebcamBootstrap;
        WebcamBootstrap::ensure(qw(Tk));
        last;
    }
    # The modules of this program sit beside this file, wherever it is run
    # from - these scripts get copied to ~ and run from either place.
    unshift @INC, File::Basename::dirname(Cwd::abs_path(__FILE__));
}

use File::Basename ();
use File::Path ();
use POSIX ();
use Cwd ();

use Tk;
use Tk::NoteBook;

use WebcamRecord ();
use WebcamArchive ();

# ---- what the panes look like for a given number of cameras ----
#
# Laid out by how many cameras there are rather than always being a 2x2 grid
# with holes in it: one camera gets the whole width, two sit side by side,
# three or four fill the quarters. Four 720p previews redrawn ten times a
# second is real work, so the panes get smaller as they get more numerous -
# the archive keeps the full 1280x720 either way, this is only what is drawn.
my %LAYOUT = (
    1 => { across => 1, width => 960, height => 540 },
    2 => { across => 2, width => 640, height => 360 },
    3 => { across => 2, width => 480, height => 270 },
    4 => { across => 2, width => 480, height => 270 },
);

my $PREVIEW_MS = 100;      # the panes redraw ten times a second
my $STATUS_MS  = 2000;
my $PLAYBACK   = "$WebcamRecord::STATE_DIR/playback.ppm";
my $SCRUB      = "$WebcamRecord::STATE_DIR/scrub.ppm";

# How the archive plays back. Label, the rate footage runs at in seconds of
# video per second of clock, and how many frames a second to draw.
#
# The slow end reads as "frames per second": a 30fps recording drawn at 5
# frames a second is six times slow motion, which is the speed to watch
# somebody's hands at. The fast end reads as "minutes per second": at 1
# min/sec an hour of a still driveway goes past in a minute, which is the
# speed to find the one moment something moved at.
my @SPEEDS = (
    [ '5 fps - slow motion',       5 / 30,  5 ],
    [ '10 fps - slow motion',     10 / 30, 10 ],
    [ '15 fps - half speed',      15 / 30, 15 ],
    [ '20 fps',                   20 / 30, 20 ],
    [ '30 fps - normal speed',          1, 30 ],
    [ 'Fast forward - 1 min/sec',      60, 15 ],
    [ 'Fast forward - 2 min/sec',     120, 15 ],
);
my $SPEED_DEFAULT = 4;      # 30 fps, normal speed

my @SPANS = (
    ['1 min',    60], ['5 min',   300], ['10 min',   600], ['30 min',  1800],
    ['1 hour', 3600], ['5 hours', 5 * 3600],
    ['12 hours', 12 * 3600], ['24 hours', 24 * 3600],
);

WebcamRecord::ensure_dirs();
my $settings = WebcamRecord::read_settings();
my $recorder = WebcamRecord->new(settings => $settings);
my $devices  = WebcamRecord::list_devices();

my $mw = MainWindow->new;
$mw->title('Webcam - live video, archive and settings');
# No fixed size: one camera is a one-pane window, not a four-pane window with
# three holes in it, so the window follows what build_panes actually built.
# fit_window does that once the widgets know how big they are.

my $book = $mw->NoteBook()->pack(-fill => 'both', -expand => 1);
my $live_page     = $book->add('live',     -label => '  Live video  ');
my $archive_page  = $book->add('archive',  -label => '  Archive  ');
my $settings_page = $book->add('settings', -label => '  Settings  ');

# ======================================================================
# the live page
# ======================================================================

# Declared here because closures further down close over them and a closure
# compiles where it is written: a variable first declared below its own use is
# a compile-time error under strict, not a runtime surprise.
my $span_label;
my $container;

my @panes;
my $pane_holder = $live_page->Frame->pack(-side => 'top', -fill => 'both',
                                          -expand => 1, -pady => 4);

my $resize_note = $live_page->Label(-text => '', -foreground => '#664400',
                                    -font => 'Helvetica 9', -anchor => 'w',
                                    -justify => 'left', -wraplength => 900)
                            ->pack(-side => 'top', -fill => 'x', -padx => 8);

my $state_row = $live_page->Frame->pack(-side => 'top', -fill => 'x', -padx => 6);
my $state_dot = $state_row->Label(-text => ' ', -background => '#555555',
                                  -width => 2)->pack(-side => 'left');
my $state_text = $state_row->Label(-text => 'starting...',
                                   -font => 'Helvetica 11 bold')
                           ->pack(-side => 'left', -padx => 4);
my $rate_text = $state_row->Label(-text => '', -foreground => '#445566',
                                  -font => 'Helvetica 9')
                          ->pack(-side => 'right');

my $button_row = $live_page->Frame->pack(-side => 'top', -fill => 'x',
                                         -padx => 6, -pady => 3);
$button_row->Button(-text => 'Start Recording', -width => 16,
                    -background => '#cc3333', -foreground => 'white',
                    -command => sub { apply_settings(); $recorder->start(1) })
           ->pack(-side => 'left', -padx => 2);
$button_row->Button(-text => 'Free space now', -width => 15,
                    -command => \&on_janitor)
           ->pack(-side => 'left', -padx => 12);
$button_row->Button(-text => 'Open archive folder', -width => 18,
                    -command => \&on_open_folder)
           ->pack(-side => 'left', -padx => 2);
# Detach the video into a window of its own - the phone-style pop-out.
# Camera 1 by default; each pane also has its own button in its title bar.
$button_row->Button(-text => 'Pop out video', -width => 14,
                    -command => sub { pop_out(1) })
           ->pack(-side => 'left', -padx => 12);

# ---- the cameras ----
#
# Four slots, each a tick and a device. The device pickers are here rather
# than buried in the settings page because they are the one thing that has to
# be right before anything else works, and because a USB camera comes back as
# a different /dev/video number often enough to matter.
my $cam_box = $live_page->LabelFrame(
    -label => "Cameras (up to $WebcamRecord::MAX_CAMERAS)", -padx => 6,
    -pady => 3)->pack(-side => 'top', -fill => 'x', -padx => 6, -pady => 3);

my @slots;
{
    my @cameras = WebcamRecord::cameras_of($settings);
    for my $number (1 .. $WebcamRecord::MAX_CAMERAS) {
        my $slot = {
            on     => ($number <= scalar @cameras) ? 1 : 0,
            device => ($number <= scalar @cameras) ? $cameras[$number - 1] : '',
        };
        my $tick = $cam_box->Checkbutton(
            -text => "Camera $number", -variable => \$slot->{on},
            -anchor => 'w', -width => 10);
        $tick->grid(-row => $number - 1, -column => 0, -sticky => 'w');
        # Camera 1 cannot be turned off: it is what every preset, the light
        # meter and the brain mean by "the camera".
        if ($number == 1) {
            $slot->{on} = 1;
            $tick->configure(-state => 'disabled');
        }
        my $picker = $cam_box->Optionmenu(
            -options => [ map { [ $_->{label} => $_->{device} ] } @$devices ],
            -variable => \$slot->{device}, -width => 44);
        $picker->grid(-row => $number - 1, -column => 1, -sticky => 'w',
                      -padx => 4, -pady => 1);
        $slot->{picker} = $picker;
        push @slots, $slot;
    }
    $cam_box->Button(-text => 'Rescan devices', -command => \&on_rescan_devices)
            ->grid(-row => 0, -column => 2, -padx => 6);
    $cam_box->Button(-text => 'Apply cameras', -width => 14,
                     -command => \&apply_settings)
            ->grid(-row => 1, -column => 2, -padx => 6);
    $cam_box->Label(
        -text => "Each camera needs its own device - two recorders on one\n"
               . "device is the \"busy\" failure. Every camera records at the\n"
               . "same size and rate, into its own cam1..cam4 folder.",
        -justify => 'left', -foreground => '#445566', -font => 'Helvetica 8')
            ->grid(-row => 2, -column => 2, -rowspan => 2, -sticky => 'w',
                   -padx => 6);
}

# ---- what gets recorded ----
my $rec_box = $live_page->LabelFrame(-label => 'Recording', -padx => 6,
                                     -pady => 3)
    ->pack(-side => 'top', -fill => 'x', -padx => 6, -pady => 3);

my $size_var    = "$settings->{width}x$settings->{height}";
my $fps_var     = $settings->{fps};
my $segment_var = int($settings->{segment_seconds} / 60) || 5;
my $cap_var     = $settings->{max_archive_gb} . ' GB';
my $free_var    = $settings->{keep_free_gb};
my $encoder_var = $settings->{encoder};

$rec_box->Label(-text => 'Size')->grid(-row => 0, -column => 0, -sticky => 'e');
$rec_box->Optionmenu(-options => [qw(1280x720 1920x1080 800x600 640x480)],
                     -variable => \$size_var, -width => 11)
        ->grid(-row => 0, -column => 1, -sticky => 'w', -padx => 4);
$rec_box->Label(-text => 'Frames/sec')->grid(-row => 0, -column => 2,
                                             -sticky => 'e');
$rec_box->Spinbox(-from => 1, -to => 60, -width => 5,
                  -textvariable => \$fps_var)
        ->grid(-row => 0, -column => 3, -sticky => 'w', -padx => 4);
$rec_box->Label(-text => 'Segment (min)')->grid(-row => 0, -column => 4,
                                                -sticky => 'e');
$rec_box->Spinbox(-from => 1, -to => 60, -width => 5,
                  -textvariable => \$segment_var)
        ->grid(-row => 0, -column => 5, -sticky => 'w', -padx => 4);

$rec_box->Label(-text => 'Loop record at')->grid(-row => 1, -column => 0,
                                                 -sticky => 'e');
$rec_box->Optionmenu(
    -options => [ map { "$_ GB" } @WebcamRecord::ARCHIVE_CAPS ],
    -variable => \$cap_var, -width => 8)
        ->grid(-row => 1, -column => 1, -sticky => 'w', -padx => 4);
$rec_box->Label(-text => 'Keep free (GB)')->grid(-row => 1, -column => 2,
                                                 -sticky => 'e');
$rec_box->Spinbox(-from => 1, -to => 2000, -width => 7,
                  -textvariable => \$free_var)
        ->grid(-row => 1, -column => 3, -sticky => 'w', -padx => 4);
$rec_box->Label(-text => 'Video')->grid(-row => 1, -column => 4, -sticky => 'e');
$rec_box->Optionmenu(
    -options => [ [ 'copy  (no CPU, ~4x disk)  - default'     => 'copy' ],
                  [ 'h264  (small files, a core per camera)' => 'h264' ] ],
    -variable => \$encoder_var, -width => 30)
        ->grid(-row => 1, -column => 5, -sticky => 'w', -padx => 4);
$rec_box->Button(-text => 'Apply', -width => 10, -command => \&apply_settings)
        ->grid(-row => 1, -column => 6, -padx => 6);

$live_page->Label(
    -text => 'Only one program can stream a camera at a time, so nothing else '
           . 'may be capturing these devices while this runs. If a pane stays '
           . 'dark and says the device is busy, that is what it means. Camera '
           . 'controls and presets keep working while recording.',
    -foreground => '#664400', -justify => 'left', -anchor => 'w',
    -wraplength => 940, -font => 'Helvetica 8')
    ->pack(-side => 'top', -fill => 'x', -padx => 8);

my $disk_label = $live_page->Label(-text => '', -foreground => '#003366',
                                   -anchor => 'w', -font => 'Helvetica 10')
    ->pack(-side => 'top', -fill => 'x', -padx => 8, -pady => 2);

# ---- the panes ----

sub build_panes {
    my ($count) = @_;
    for my $old (@panes) {
        eval { $old->{pop}{window}->destroy; 1 } if $old->{pop};
    }
    $_->{holder}->destroy for grep { $_->{holder} } @panes;
    @panes = ();
    $count = 1 if $count < 1;
    $count = $WebcamRecord::MAX_CAMERAS if $count > $WebcamRecord::MAX_CAMERAS;
    my $shape = $LAYOUT{$count};

    for my $number (1 .. $count) {
        my $holder = $pane_holder->Frame(-borderwidth => 1,
                                         -relief => 'sunken');
        $holder->grid(-row => int(($number - 1) / $shape->{across}),
                      -column => ($number - 1) % $shape->{across},
                      -padx => 3, -pady => 3, -sticky => 'nsew');
        # Every row and column pulls its share of the window, so the panes
        # grow with it instead of sitting at their starting size in a field
        # of grey.
        $pane_holder->gridRowconfigure(
            int(($number - 1) / $shape->{across}), -weight => 1);
        $pane_holder->gridColumnconfigure(
            ($number - 1) % $shape->{across}, -weight => 1);
        my $head = $holder->Frame->pack(-side => 'top', -fill => 'x');
        my $dot = $head->Label(-text => ' ', -background => '#555555',
                               -width => 2)->pack(-side => 'left');
        my $title = $head->Label(-text => "Camera $number",
                                 -font => 'Helvetica 9 bold')
                         ->pack(-side => 'left', -padx => 4);
        $head->Button(-text => 'Pop out', -font => 'Helvetica 8',
                      -padx => 4, -pady => 0,
                      -command => sub { pop_out($number) })
             ->pack(-side => 'right', -padx => 4);
        my $canvas = $holder->Canvas(
            -width => $shape->{width}, -height => $shape->{height},
            -background => '#101014', -highlightthickness => 0)
            ->pack(-side => 'top', -fill => 'both', -expand => 1);
        # One Photo per pane, read into over and over rather than a new Photo
        # every tenth of a second: a Photo that is replaced has to be deleted
        # or it stays in Tk's image table, and ten a second adds up fast.
        my $photo = $mw->Photo(-width => $shape->{width},
                               -height => $shape->{height});
        my $image_id = $canvas->createImage(
            $shape->{width} / 2, $shape->{height} / 2, -image => $photo);
        my $text_id = $canvas->createText(
            $shape->{width} / 2, $shape->{height} / 2,
            -fill => '#99aabb', -justify => 'center',
            -width => $shape->{width} - 40,
            -text => 'waiting for the first frame...');
        # The REC mark, top left, over the picture: the one piece of state
        # worth reading from across a room, and the convention every camera
        # has used for forty years. Created hidden and shown only while this
        # camera is really recording, so a dark pane with a red dot on it can
        # never happen - that would be the most misleading thing this window
        # could do.
        my $rec_dot = $canvas->createOval(12, 12, 26, 26,
            -fill => '#dd1111', -outline => '#ffffff', -state => 'hidden');
        my $rec_text = $canvas->createText(34, 19, -anchor => 'w',
            -text => 'REC', -fill => '#ffffff',
            -font => 'Helvetica 11 bold', -state => 'hidden');
        my $pane = {
            rec_dot => $rec_dot, rec_text => $rec_text,
            index => $number, holder => $holder, canvas => $canvas,
            photo => $photo, image => $image_id, text => $text_id,
            dot => $dot, title => $title, mtime => 0, pop => undef,
            width => $shape->{width}, height => $shape->{height},
        };
        $canvas->Tk::bind('<Configure>',
            [ sub { on_pane_resize($pane, $_[1], $_[2]) },
              Tk::Ev('w'), Tk::Ev('h') ]);
        push @panes, $pane;
    }

    fit_window();

    # The previews are scaled by ffmpeg, so the panes' size is part of the
    # recorder's settings rather than something Tk does afterwards: Tk::Photo
    # can only scale by whole-number subsampling, which at these sizes would
    # mean either half size or nothing.
    WebcamRecord::write_settings({
        preview_width  => $shape->{width},
        preview_height => $shape->{height},
    });
    $settings = WebcamRecord::read_settings();
    return;
}

# ---- panes that follow the window, and the pop-out ----

# Tk::Photo can only scale an image by whole-number subsampling, so a pane
# bigger than the preview cannot be filled by stretching what arrived - which
# is why this program has always had ffmpeg make the preview at exactly the
# pane's size. Resizing the window therefore means telling the recorder a new
# preview size, and that restarts ffmpeg: it is debounced by a second and a
# half and ignores small changes, so one drag of the window edge costs one
# restart rather than one per pixel.
my $resize_pending;
my ($want_w, $want_h) = (0, 0);
my $pending_preview;        # [w, h] wanted, held back while recording

sub on_pane_resize {
    my ($pane, $width, $height) = @_;
    return if !defined $width || $width < 20 || $height < 20;
    $pane->{width}  = $width;
    $pane->{height} = $height;
    my $canvas = $pane->{canvas};
    eval {
        $canvas->coords($pane->{image}, $width / 2, $height / 2);
        $canvas->coords($pane->{text},  $width / 2, $height / 2);
        $canvas->itemconfigure($pane->{text},
            -width => ($width > 120 ? $width - 40 : 80));
        1;
    };
    return if $pane->{pop};        # a pop-out window drives its own size

    my $current_w = int($settings->{preview_width}  || 640);
    my $current_h = int($settings->{preview_height} || 360);
    return if abs($width - $current_w) < 48 && abs($height - $current_h) < 48;
    ($want_w, $want_h) = ($width, $height);
    $mw->afterCancel($resize_pending) if $resize_pending;
    $resize_pending = $mw->after(1500, \&apply_preview_size);
    return;
}

sub apply_preview_size {
    $resize_pending = undef;
    return if $want_w < 160 || $want_h < 90;

    # Never restart ffmpeg while it is recording. A restart ends the segment
    # being written and loses the second or so it takes the camera to come
    # back, and a security recorder must not lose footage because somebody
    # dragged the window edge. The wanted size is remembered instead and
    # taken up at the next restart the user asks for anyway - Apply, or
    # Start Recording - which is also the only moment a gap is expected.
    # Until then the picture stays at its old size, centred in the pane.
    if ($recorder->{recording}) {
        $pending_preview = [ $want_w, $want_h ];
        $resize_note->configure(-text => sprintf(
            'Window resized. The video fills the new size at the next Apply '
          . 'or Start Recording - not now, because resizing the picture '
          . 'restarts the camera and would break the recording in progress. '
          . '(wanted: %dx%d)', $want_w, $want_h));
        return;
    }

    $pending_preview = undef;
    $resize_note->configure(-text => '');
    WebcamRecord::write_settings({
        preview_width  => $want_w,
        preview_height => $want_h,
    });
    $settings = WebcamRecord::read_settings();
    $recorder->{settings} = $settings;
    # The new size only reaches the picture when ffmpeg is restarted with it,
    # and here that restart costs nothing: nothing is being kept.
    $recorder->start($recorder->{recording}) if $recorder->is_running;
    return;
}

# Detach one camera into a window of its own: the phone-style pop-out. A
# small always-on-top window that can be dragged anywhere, resized, or left
# over another program while the main window does something else. The pane it
# came from says where the video went and offers it back; closing the pop-out
# docks it again, so the video can never end up nowhere.
sub pop_out {
    my ($index) = @_;
    my ($pane) = grep { $_->{index} == $index } @panes;
    return if !$pane;
    if ($pane->{pop}) {
        eval { $pane->{pop}{window}->deiconify; $pane->{pop}{window}->raise; 1 }
            or $pane->{pop} = undef;
        return if $pane->{pop};
    }

    my $window = $mw->Toplevel;
    $window->title("Camera $index - live video");
    $window->geometry('640x400');
    $window->minsize(240, 180);
    eval { $window->attributes(-topmost => 1); 1 };

    my $canvas = $window->Canvas(-background => '#101014',
                                 -highlightthickness => 0)
                        ->pack(-side => 'top', -fill => 'both', -expand => 1);
    my $photo = $mw->Photo(-width => 640, -height => 360);
    my $image_id = $canvas->createImage(320, 180, -image => $photo);
    my $text_id  = $canvas->createText(320, 180, -fill => '#99aabb',
        -justify => 'center', -width => 560,
        -text => 'waiting for the first frame...');
    my $rec_dot = $canvas->createOval(12, 12, 26, 26, -fill => '#dd1111',
        -outline => '#ffffff', -state => 'hidden');
    my $rec_text = $canvas->createText(34, 19, -anchor => 'w', -text => 'REC',
        -fill => '#ffffff', -font => 'Helvetica 11 bold', -state => 'hidden');

    my $bar = $window->Frame->pack(-side => 'bottom', -fill => 'x');
    my $on_top = 1;
    $bar->Checkbutton(-text => 'Always on top', -variable => \$on_top,
                      -command => sub {
                          eval { $window->attributes(-topmost => $on_top); 1 };
                      })->pack(-side => 'left', -padx => 6);
    $bar->Button(-text => 'Pop in', -width => 10,
                 -command => sub { pop_in($index) })
        ->pack(-side => 'right', -padx => 6, -pady => 2);

    my $pop = {
        window => $window, canvas => $canvas, photo => $photo,
        image => $image_id, text => $text_id, rec_dot => $rec_dot,
        rec_text => $rec_text, width => 640, height => 360,
    };
    $canvas->Tk::bind('<Configure>',
        [ sub {
              my (undef, $w, $h) = @_;
              return if !defined $w || $w < 20 || $h < 20;
              $pop->{width} = $w; $pop->{height} = $h;
              eval {
                  $canvas->coords($image_id, $w / 2, $h / 2);
                  $canvas->coords($text_id,  $w / 2, $h / 2);
                  1;
              };
          }, Tk::Ev('w'), Tk::Ev('h') ]);
    $canvas->Tk::bind('<Double-Button-1>', sub { pop_in($index) });
    $window->protocol('WM_DELETE_WINDOW', sub { pop_in($index) });

    $pane->{pop}   = $pop;
    $pane->{mtime} = 0;
    $pane->{canvas}->itemconfigure($pane->{text},
        -text => "Camera $index is playing in its own window.\n"
               . 'Close that window, or press Pop in, to bring it back here.');
    return;
}

sub pop_in {
    my ($index) = @_;
    my ($pane) = grep { $_->{index} == $index } @panes;
    return if !$pane || !$pane->{pop};
    eval { $pane->{pop}{photo}->delete; 1 };
    eval { $pane->{pop}{window}->destroy; 1 };
    $pane->{pop}   = undef;
    $pane->{mtime} = 0;            # the next frame redraws the pane
    eval {
        $pane->{canvas}->itemconfigure($pane->{text},
            -text => 'waiting for the next frame...');
        1;
    };
    return;
}

# Make the window the size the panes actually need, so adding or removing a
# camera resizes it rather than leaving empty space or cutting a pane off.
sub fit_window {
    $mw->update;
    my $width  = $live_page->reqwidth;
    my $height = $live_page->reqheight;
    $width  = 1020 if $width  < 1020;
    my $max_w = int($mw->screenwidth  * 0.98);
    my $max_h = int($mw->screenheight * 0.94);
    $width  = $max_w if $width  > $max_w;
    $height = $max_h if $height > $max_h;
    $mw->minsize(($width < 1020 ? $width : 1020),
                 ($height < 700 ? $height : 700));
    $mw->geometry($width . 'x' . $height);
    return;
}

# ---- settings off the page ----

sub apply_settings {
    my (@cameras, %seen);
    for my $slot (@slots) {
        next if !$slot->{on};
        my $device = $slot->{device};
        next if !defined $device || !length $device || $seen{$device}++;
        push @cameras, $device;
    }
    @cameras = ($WebcamRecord::DEVICE) if !@cameras;

    my ($width, $height) = $size_var =~ /^(\d+)x(\d+)$/
                         ? ($1, $2) : (1280, 720);
    my ($cap) = $cap_var =~ /(\d+)/;

    my $before = scalar WebcamRecord::cameras_of($settings);
    # A resize held back while recording rides along with this restart, which
    # is the gap the user has already asked for by pressing the button.
    my %held = $pending_preview
             ? (preview_width  => $pending_preview->[0],
                preview_height => $pending_preview->[1]) : ();
    $pending_preview = undef;
    $resize_note->configure(-text => '');
    WebcamRecord::write_settings({
        %held,
        cameras         => join(',', @cameras),
        width           => $width,
        height          => $height,
        fps             => int($fps_var) || 30,
        segment_seconds => (int($segment_var) || 5) * 60,
        keep_free_gb    => $free_var + 0,
        max_archive_gb  => ($cap || 250) + 0,
        encoder         => ($encoder_var eq 'copy' ? 'copy' : 'h264'),
    });
    $settings = WebcamRecord::read_settings();
    $recorder->{settings} = $settings;

    build_panes(scalar @cameras) if scalar @cameras != $before;
    $recorder->start($recorder->{recording}) if $recorder->is_running;
    return;
}

sub on_rescan_devices {
    $devices = WebcamRecord::list_devices();
    for my $slot (@slots) {
        $slot->{picker}->configure(
            -options => [ map { [ $_->{label} => $_->{device} ] } @$devices ]);
    }
    return;
}

# ---- the archive folder, and the state that has to agree with it ----
#
# ~/.cache/webcam holds the recorder pid, the status files and the preview
# PPMs, and those still name segments the archive folder used to hold. Delete
# an archive by hand and the recorder keeps writing against state that no
# longer matches the disk, which shows up as a camera that will not record.
# So opening the folder says so, and offers the one repair that fixes it.
sub on_open_folder {
    run_detached('xdg-open', $settings->{archive_dir});
    show_archive_notice();
    return;
}

sub show_archive_notice {
    my $window = $mw->Toplevel(-title => 'Archive folder');
    my $frame  = $window->Frame(-padx => 12, -pady => 12)
                        ->pack(-fill => 'both', -expand => 1);

    $frame->Label(-text => $settings->{archive_dir},
                  -font => 'Helvetica 9 bold',
                  -anchor => 'w', -justify => 'left')->pack(-fill => 'x');
    $frame->Label(
        -text => 'If the archive file is deleted, then the files in '
               . '~/.cache/webcam related to that archive need to also be '
               . 'deleted and the program needs to be restarted to begin '
               . 'recording onto a new archive.',
        -wraplength => 430, -justify => 'left', -anchor => 'w',
        -pady => 8)->pack(-fill => 'x');

    $frame->Button(
        -text => 'Delete Archive files to fix camera not recording errors',
        -command => sub { on_clear_state($window) })->pack(-fill => 'x',
                                                           -pady => 4);
    $frame->Button(-text => 'Close', -width => 10,
                   -command => sub { $window->destroy })->pack(-pady => 2);
    return;
}

# Empty $STATE_DIR. Nothing in there is recorded video - it is the pid file,
# the status files and the preview PPMs, all of which the recorder writes
# again on its next start. The recorder is stopped first so that it is not
# holding a pid file that is about to disappear.
sub on_clear_state {
    my ($window) = @_;
    my $state = $WebcamRecord::STATE_DIR;

    my $answer = $mw->messageBox(
        -title => 'Delete archive state files', -type => 'YesNo',
        -icon => 'question',
        -message => "Delete the recorder state files in $state?\n\n"
                  . 'No recorded video is touched. Recording stops, and the '
                  . 'program needs restarting afterwards to begin a new '
                  . 'archive.');
    return if lc($answer) ne 'yes';

    eval { $recorder->stop; 1 };          # already stopped is fine

    my (@failed, $removed);
    $removed = 0;
    if (opendir my $dir, $state) {
        my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $dir;
        closedir $dir;
        for my $name (@names) {
            my $path = "$state/$name";
            my $ok = eval {
                if (-d $path && !-l $path) { File::Path::remove_tree($path) }
                else                       { unlink $path or die "$!\n" }
                1;
            };
            if ($ok) { $removed++ }
            else     { push @failed, "$name: $@" }
        }
    }
    else {
        $mw->messageBox(-title => 'Delete archive state files', -type => 'OK',
                        -icon => 'info', -message => "$state\n\n$!");
        return;
    }

    $state_text->configure(-text => 'state cleared - restart the program');
    $state_dot->configure(-background => '#555555');
    $window->destroy if $window;

    my $note = "$removed item(s) deleted from $state.\n\n"
             . 'Now close and restart the program to begin recording onto a '
             . 'new archive.';
    $note .= "\n\nCould not delete:\n" . join('', @failed) if @failed;
    $mw->messageBox(-title => 'Delete archive state files', -type => 'OK',
                    -icon => 'info', -message => $note);
    return;
}

sub on_janitor {
    my ($removed, $freed) = WebcamRecord::free_space($settings, 0);
    $mw->messageBox(
        -title => 'Free space', -type => 'OK', -icon => 'info',
        -message => $removed
            ? sprintf("%d segment(s) recycled, %.1f GB freed.", $removed, $freed)
            : 'Nothing needed recycling - the archive is inside both the loop '
              . 'cap and the free-space floor.');
    return;
}

# ---- drawing ----

# Read a PPM into a pane's Photo, if there is a new one. A half-written file
# makes read() die, which is caught and skipped rather than reported: the next
# frame is a tenth of a second away, and the recorder writes atomically where
# ffmpeg supports it.
sub draw_into {
    my ($pane, $path) = @_;
    return 0 if !-f $path;
    my $mtime = (stat $path)[9];
    return 0 if !$mtime || $mtime <= $pane->{mtime};
    # A popped-out camera is drawn in its own window instead of its pane -
    # one read either way, never both.
    my $target = $pane->{pop} || $pane;
    my $ok = eval { $target->{photo}->read($path, -shrink => 1); 1 };
    return 0 if !$ok;
    $pane->{mtime} = $mtime;
    eval { $target->{canvas}->itemconfigure($target->{text}, -text => ''); 1 };
    return 1;
}

my $frames_drawn = 0;
my $counted_at   = time;
my $shown_fps    = 0;

sub draw_tick {
    for my $pane (@panes) {
        $frames_drawn++
            if draw_into($pane, WebcamRecord::preview_file($pane->{index}));
    }
    if (time - $counted_at >= 2) {
        $shown_fps  = $frames_drawn / (time - $counted_at);
        $frames_drawn = 0;
        $counted_at = time;
    }
    $mw->after($PREVIEW_MS, \&draw_tick);
    return;
}

sub status_tick {
    $recorder->poll;
    my $status = $recorder->status;
    my %by_index = map { $_->{index} => $_ } @{ $status->{per_camera} };

    for my $pane (@panes) {
        my $row   = $by_index{ $pane->{index} } || {};
        my $stale = !$pane->{mtime} || (time - $pane->{mtime} > 5);
        $pane->{dot}->configure(-background =>
            ($row->{recording} && !$stale) ? '#cc2222'
          : ($row->{running}   && !$stale) ? '#2277cc'
          :                                  '#555555');
        # Recording AND a picture arriving: either alone is not recording.
        my $marked = ($row->{recording} && !$stale) ? 'normal' : 'hidden';
        for my $target ($pane, $pane->{pop}) {
            next if !$target;
            eval {
                $target->{canvas}->itemconfigure($target->{$_},
                    -state => $marked) for qw(rec_dot rec_text);
                1;
            };
        }
        $pane->{title}->configure(-text => sprintf('Camera %d%s%s',
            $pane->{index},
            ($row->{device} ? "  $row->{device}" : ''),
            ($row->{gigabytes} ? sprintf('  %.1f GB', $row->{gigabytes}) : '')));
        my $shown = $pane->{pop} || $pane;
        if ($stale && $row->{error}) {
            $shown->{canvas}->itemconfigure($shown->{text},
                -text => substr($row->{error}, 0, 300));
        }
        elsif ($stale && $row->{retry_in}) {
            $shown->{canvas}->itemconfigure($shown->{text},
                -text => "camera lost - retrying in $row->{retry_in}s");
        }
    }

    if ($status->{recording}) {
        $state_dot->configure(-background => '#cc2222');
        $state_text->configure(-text => sprintf(
            'RECORDING  %d of %d camera(s)  %s @ %sfps',
            $status->{live}, $status->{cameras}, $status->{size},
            $status->{fps}));
    }
    elsif ($status->{running}) {
        $state_dot->configure(-background => '#2277cc');
        $state_text->configure(
            -text => 'preview only - nothing is being kept');
    }
    else {
        $state_dot->configure(-background => '#555555');
        $state_text->configure(-text => 'stopped');
    }
    $rate_text->configure(-text => sprintf('drawing %.0f fps total', $shown_fps));

    my $cap  = $status->{max_archive_gb} || 250;
    my $held = $status->{archive_gb};
    $disk_label->configure(
        -text => sprintf(
            'archive %.1f of %d GB (%.0f%% of the loop) in %d segments   -   '
            . '%.1f GB free on disk, floor %d GB%s',
            $held, $cap, ($cap ? $held / $cap * 100 : 0), $status->{segments},
            $status->{free_gb}, $status->{keep_free_gb},
            ($status->{oldest} ? "   -   oldest kept: $status->{oldest}" : '')),
        -foreground => ($status->{free_gb} < $status->{keep_free_gb} * 0.6)
                       ? '#aa0000' : '#003366');
    $mw->after($STATUS_MS, \&status_tick);
    return;
}

# ======================================================================
# the archive page
# ======================================================================

my $find_box = $archive_page->LabelFrame(-label => 'Archive index search',
                                         -padx => 6, -pady => 3)
    ->pack(-side => 'top', -fill => 'x', -padx => 6, -pady => 3);

my %find = (day_from => POSIX::strftime('%Y-%m-%d', localtime),
            day_to   => POSIX::strftime('%Y-%m-%d', localtime),
            time_from => '', time_to => '', text => '', min_secs => '',
            camera => 'All cameras');

$find_box->Label(-text => 'Date from')->grid(-row => 0, -column => 0, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{day_from}, -width => 12)
         ->grid(-row => 0, -column => 1, -padx => 3);
$find_box->Label(-text => 'to')->grid(-row => 0, -column => 2, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{day_to}, -width => 12)
         ->grid(-row => 0, -column => 3, -padx => 3);
$find_box->Label(-text => 'Time from')->grid(-row => 0, -column => 4, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{time_from}, -width => 9)
         ->grid(-row => 0, -column => 5, -padx => 3);
$find_box->Label(-text => 'to')->grid(-row => 0, -column => 6, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{time_to}, -width => 9)
         ->grid(-row => 0, -column => 7, -padx => 3);

$find_box->Label(-text => 'Text / note')->grid(-row => 1, -column => 0, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{text}, -width => 26)
         ->grid(-row => 1, -column => 1, -columnspan => 3, -sticky => 'w', -padx => 3);
$find_box->Label(-text => 'At least (sec)')->grid(-row => 1, -column => 4, -sticky => 'e');
$find_box->Entry(-textvariable => \$find{min_secs}, -width => 9)
         ->grid(-row => 1, -column => 5, -padx => 3);
$find_box->Label(-text => 'Camera')->grid(-row => 1, -column => 6, -sticky => 'e');
$find_box->Optionmenu(
    -options => [ 'All cameras',
                  map { "Camera $_" } 1 .. $WebcamRecord::MAX_CAMERAS ],
    -variable => \$find{camera}, -width => 11)
         ->grid(-row => 1, -column => 7, -padx => 3);

$find_box->Button(-text => 'Search', -width => 10, -command => \&on_search)
         ->grid(-row => 0, -column => 8, -padx => 6);
$find_box->Button(-text => 'Everything', -width => 10,
                  -command => sub { show_rows(WebcamArchive::search(
                      camera => picked_camera(), limit => 5000)) })
         ->grid(-row => 1, -column => 8, -padx => 6);
$find_box->Button(-text => 'Rescan disk', -width => 11, -command => \&on_rescan)
         ->grid(-row => 0, -column => 9, -padx => 3);
$find_box->Button(-text => 'Clear filters', -width => 11,
                  -command => sub {
                      $find{$_} = '' for qw(day_from day_to time_from time_to
                                            text min_secs);
                      $span_label->configure(-text => '') if $span_label;
                  })
         ->grid(-row => 1, -column => 9, -padx => 3);

# The spans worth one click. "The last ten minutes" is how an archive actually
# gets searched - something happened, and it happened recently - and typing
# two dates and two times to ask that is three clicks too many. Each button
# fills the boxes above as well as searching, so the span can then be nudged
# by hand.
my $span_box = $archive_page->LabelFrame(-label => 'Back from now', -padx => 6,
                                         -pady => 2)
    ->pack(-side => 'top', -fill => 'x', -padx => 6);
for my $span (@SPANS) {
    my ($label, $seconds) = @$span;
    $span_box->Button(-text => $label, -width => 8,
                      -command => sub { on_span($seconds, $label) })
             ->pack(-side => 'left', -padx => 2);
}

my $summary_label = $archive_page->Label(
    -text => '', -anchor => 'w', -foreground => '#003366',
    -font => 'Helvetica 10')->pack(-side => 'top', -fill => 'x', -padx => 8);
$span_label = $archive_page->Label(
    -text => '', -anchor => 'w', -foreground => '#445566',
    -font => 'Helvetica 8')->pack(-side => 'top', -fill => 'x', -padx => 8);
my $found_label = $archive_page->Label(
    -text => '', -anchor => 'w', -foreground => '#003366',
    -font => 'Helvetica 8')->pack(-side => 'top', -fill => 'x', -padx => 8);

my $split = $archive_page->Frame->pack(-side => 'top', -fill => 'both',
                                       -expand => 1, -padx => 6, -pady => 3);

# A Listbox of formatted lines rather than a multi-column widget: Tk::HList is
# not in every perl-tk, and a fixed-width font lines the columns up just as
# well without anything to install.
my $left = $split->Frame->pack(-side => 'left', -fill => 'both');
my $list_scroll = $left->Scrollbar(-orient => 'vertical', -width => 16);
my $listbox = $left->Listbox(-height => 20, -width => 52,
                             -font => 'Courier 9', -exportselection => 0,
                             -yscrollcommand => ['set' => $list_scroll]);
$list_scroll->configure(-command => ['yview' => $listbox]);
$listbox->pack(-side => 'left', -fill => 'both', -expand => 1);
$list_scroll->pack(-side => 'right', -fill => 'y');
$listbox->bind('<<ListboxSelect>>', \&on_pick);
$listbox->bind('<Double-1>', \&on_play);

my $right = $split->Frame->pack(-side => 'left', -fill => 'both',
                                -expand => 1, -padx => 6);
my $play_canvas = $right->Canvas(-width => 640, -height => 360,
                                 -background => '#101014',
                                 -highlightthickness => 0)->pack(-side => 'top');
my $play_photo = $mw->Photo(-width => 640, -height => 360);
my $play_image = $play_canvas->createImage(320, 180, -image => $play_photo);
my $play_text  = $play_canvas->createText(320, 180, -fill => '#99aabb',
                                          -text => 'pick a segment on the left');
my %player = (pane => { photo => $play_photo, canvas => $play_canvas,
                        text => $play_text, mtime => 0 },
              row => undef, offset => 0, playing => 0, pid => 0, started => 0);

my $scrub_var = 0;
my $scrub = $right->Scale(-orient => 'horizontal', -from => 0, -to => 100,
                          -showvalue => 0, -variable => \$scrub_var,
                          -command => \&on_scrub)
    ->pack(-side => 'top', -fill => 'x', -pady => 2);

my $play_row = $right->Frame->pack(-side => 'top', -fill => 'x');
$play_row->Button(-text => 'Play', -width => 8, -command => \&on_play)
         ->pack(-side => 'left', -padx => 2);
$play_row->Button(-text => 'Pause', -width => 8, -command => \&on_pause)
         ->pack(-side => 'left', -padx => 2);
$play_row->Button(-text => '-10s', -width => 6,
                  -command => sub { nudge(-10) })->pack(-side => 'left', -padx => 2);
$play_row->Button(-text => '+10s', -width => 6,
                  -command => sub { nudge(10) })->pack(-side => 'left', -padx => 2);
$play_row->Label(-text => 'Speed')->pack(-side => 'left', -padx => [12, 2]);
my $speed_var = $SPEEDS[$SPEED_DEFAULT][0];
$play_row->Optionmenu(-options => [ map { $_->[0] } @SPEEDS ],
                      -variable => \$speed_var, -width => 22,
                      -command => \&on_speed)->pack(-side => 'left');

my $at_label = $play_row->Label(-text => '', -foreground => '#445566',
                                -font => 'Helvetica 9')->pack(-side => 'right');

# ---- cutting a clip out ----
my $clip_box = $right->LabelFrame(-label => 'Download a clip of the archive',
                                  -padx => 6, -pady => 3)
    ->pack(-side => 'top', -fill => 'x', -pady => 4);
my %clip = (from => '', to => '',
            format => $WebcamArchive::EXPORT_FORMATS[0]{text});

$clip_box->Label(-text => 'From')->grid(-row => 0, -column => 0, -sticky => 'e');
$clip_box->Entry(-textvariable => \$clip{from}, -width => 20)
         ->grid(-row => 0, -column => 1, -padx => 3);
$clip_box->Label(-text => 'To')->grid(-row => 0, -column => 2, -sticky => 'e');
$clip_box->Entry(-textvariable => \$clip{to}, -width => 20)
         ->grid(-row => 0, -column => 3, -padx => 3);
$clip_box->Button(-text => 'Save clip...', -width => 12,
                  -background => '#225599', -foreground => 'white',
                  -command => \&on_export)
         ->grid(-row => 0, -column => 4, -rowspan => 2, -padx => 8);
$clip_box->Button(-text => 'Use this segment', -command => \&fill_clip_times)
         ->grid(-row => 1, -column => 0, -sticky => 'w', -pady => 2);
$clip_box->Button(-text => 'Mark start here',
                  -command => sub { mark_clip('from') })
         ->grid(-row => 1, -column => 1, -pady => 2);
$clip_box->Button(-text => 'Mark end here',
                  -command => sub { mark_clip('to') })
         ->grid(-row => 1, -column => 2, -pady => 2);
$clip_box->Label(-text => 'Export as')->grid(-row => 2, -column => 0, -sticky => 'e');
$clip_box->Optionmenu(
    -options => [ map { $_->{text} } @WebcamArchive::EXPORT_FORMATS ],
    -variable => \$clip{format}, -width => 42)
         ->grid(-row => 2, -column => 1, -columnspan => 3, -sticky => 'w');
my $clip_cam_label = $clip_box->Label(-text => '', -foreground => '#445566',
                                      -font => 'Helvetica 8')
    ->grid(-row => 2, -column => 4, -sticky => 'w');
$clip_box->Label(
    -text => 'A clip may span as many segments as it needs - the pieces are '
           . "trimmed and joined\nwithout re-encoding, so it is quick and "
           . 'loses nothing. Times are "YYYY-MM-DD HH:MM:SS".',
    -justify => 'left', -foreground => '#445566', -font => 'Helvetica 8')
         ->grid(-row => 3, -column => 0, -columnspan => 5, -sticky => 'w');
my $clip_state = $clip_box->Label(-text => '', -foreground => '#003366',
                                  -font => 'Helvetica 8')
    ->grid(-row => 4, -column => 0, -columnspan => 5, -sticky => 'w');

# ---- archive behaviour ----

my @rows;

sub picked_camera {
    return $find{camera} =~ /Camera (\d+)/ ? int($1) : undef;
}

sub hhmmss {
    my ($seconds) = @_;
    $seconds = 0 if !$seconds || $seconds < 0;
    $seconds = int $seconds;
    return sprintf '%d:%02d:%02d', int($seconds / 3600),
                   int(($seconds % 3600) / 60), $seconds % 60;
}

sub on_rescan {
    $summary_label->configure(-text => 'scanning the archive folder...');
    $mw->update;
    my $result = WebcamArchive::scan();
    my $info   = WebcamArchive::stats();
    my $per_cam = join '  ', map { "cam$_: $info->{cameras}{$_}" }
                             sort keys %{ $info->{cameras} };
    $summary_label->configure(-text => sprintf(
        'index holds %d segments, %.1f hours, %.2f GB across %d day(s)%s%s',
        $info->{segments}, $info->{hours}, $info->{gigabytes}, $info->{days},
        ($per_cam ? "   -   $per_cam" : ''),
        ($info->{first} ? "   -   $info->{first} to $info->{last}" : '')));
    $found_label->configure(-text => sprintf(
        'rescan: %d new, %d updated, %d gone from disk',
        $result->{added}, $result->{updated}, $result->{removed}));
    on_span(3600, '1 hour');
    return;
}

sub on_search {
    show_rows(WebcamArchive::search(
        day_from    => $find{day_from},
        day_to      => $find{day_to},
        time_from   => WebcamArchive::hhmm($find{time_from}),
        time_to     => WebcamArchive::hhmm($find{time_to}),
        text        => $find{text},
        min_seconds => ($find{min_secs} || 0) + 0,
        camera      => picked_camera(),
    ));
    return;
}

# Everything recorded in the last N seconds. Filtered on the real start and
# end times rather than on the date and time-of-day columns, because a span of
# hours crosses midnight and a time-of-day filter cannot say "the last five
# hours" across one.
sub on_span {
    my ($seconds, $label) = @_;
    my $now    = time;
    my $cutoff = $now - $seconds;
    $find{day_from}  = POSIX::strftime('%Y-%m-%d', localtime $cutoff);
    $find{day_to}    = POSIX::strftime('%Y-%m-%d', localtime $now);
    $find{time_from} = POSIX::strftime('%H:%M:%S', localtime $cutoff);
    $find{time_to}   = POSIX::strftime('%H:%M:%S', localtime $now);
    $span_label->configure(-text => sprintf('showing the last %s:  %s  to  %s',
        ($label || hhmmss($seconds)),
        POSIX::strftime('%a %H:%M:%S', localtime $cutoff),
        POSIX::strftime('%H:%M:%S', localtime $now)));
    show_rows(WebcamArchive::search(since => $seconds,
                                    camera => picked_camera(), limit => 20000));
    return;
}

sub show_rows {
    my ($found) = @_;
    @rows = @$found;
    $listbox->delete(0, 'end');
    for my $row (@rows) {
        $listbox->insert('end', sprintf('cam%d  %s %s  %7s %6.0f MB %s',
            $row->{camera}, $row->{day}, $row->{clock},
            hhmmss($row->{duration}), $row->{size} / 1e6, $row->{note}));
    }
    $found_label->configure(
        -text => @rows ? scalar(@rows) . ' segment(s) listed'
                       : 'nothing in the index matched that search',
        -foreground => @rows ? '#003366' : '#aa0000');
    return;
}

sub selected_row {
    my @picked = $listbox->curselection;
    return undef if !@picked;
    return $rows[ $picked[0] ];
}

sub on_pick {
    my $row = selected_row() or return;
    on_pause();
    $player{row}    = $row;
    $player{offset} = 0;
    $scrub->configure(-to => ($row->{duration} > 1 ? $row->{duration} : 1));
    $scrub_var = 0;
    show_frame(0);
    fill_clip_times();
    return;
}

# One frame at an offset, for the scrub bar. Seeking is a fresh one-frame
# ffmpeg, which at -ss before -i is near instant however far into the file it
# is - so dragging the bar feels like dragging a video, with nothing kept open.
sub show_frame {
    my ($offset) = @_;
    my $row = $player{row} or return;
    my $path = WebcamArchive::frame_at(path => $row->{path}, offset => $offset,
                                       out => $SCRUB, width => 640,
                                       height => 360);
    return if !$path;
    $player{pane}{mtime} = 0;
    draw_into($player{pane}, $path);
    $player{offset} = $offset;
    update_at_label($offset);
    return;
}

sub update_at_label {
    my ($offset) = @_;
    my $row = $player{row} or return;
    my ($rate) = speed_now();
    $at_label->configure(-text => sprintf('%s of %s   %s%s',
        hhmmss($offset), hhmmss($row->{duration}),
        POSIX::strftime('%H:%M:%S', localtime($row->{started} + $offset)),
        (($player{playing} && $rate != 1) ? sprintf('   x%g', $rate) : '')));
    return;
}

sub on_scrub {
    my ($value) = @_;
    return if !$player{row} || $player{playing};
    show_frame($value + 0);
    return;
}

# The chosen speed as (rate, draw fps), falling back to normal.
sub speed_now {
    for my $speed (@SPEEDS) {
        return ($speed->[1], $speed->[2]) if $speed->[0] eq $speed_var;
    }
    return ($SPEEDS[$SPEED_DEFAULT][1], $SPEEDS[$SPEED_DEFAULT][2]);
}

# Changing speed mid-play keeps the position: the playhead stays where it is
# and only the rate it moves at changes, which is what makes slowing down at
# the interesting moment useful.
sub on_speed {
    return if !$player{playing};
    on_pause();
    on_play();
    return;
}

sub on_play {
    my $row = $player{row} || selected_row() or return;
    $player{row} = $row;
    on_pause();
    my ($rate, $draw_fps) = speed_now();
    if ($rate > 1 && !WebcamArchive::fast_forward_available()) {
        $clip_state->configure(
            -text => 'this ffmpeg is too old to read faster than real time, '
                   . 'so fast forward plays at normal speed');
        $rate = 1;
    }
    my $cmd = WebcamArchive::play_command(
        path => $row->{path}, offset => $player{offset},
        rate => $rate, fps => $draw_fps, src_fps => ($settings->{fps} || 30),
        width => 640, height => 360, out => $PLAYBACK);
    unlink $PLAYBACK;
    my $pid = fork;
    return if !defined $pid;
    if (!$pid) {
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        POSIX::setsid();
        exec { $cmd->[0] } @$cmd;
        exit 127;
    }
    $player{pid}     = $pid;
    $player{playing} = 1;
    $player{started} = time;
    $player{from}    = $player{offset};
    $player{rate}    = $rate;
    $player{pane}{mtime} = 0;
    play_tick();
    return;
}

sub on_pause {
    if ($player{pid}) {
        kill 'TERM', $player{pid};
        waitpid $player{pid}, 0;
        $player{pid} = 0;
    }
    $player{playing} = 0;
    return;
}

# Playback draws through the same path as the live panes: ffmpeg is replacing
# one file at the recorded rate and this reads it. Where it has got to is
# worked out from the clock rather than from the frames, because -re paces the
# frames by the clock in the first place.
sub play_tick {
    return if !$player{playing};
    draw_into($player{pane}, $PLAYBACK);
    my $row = $player{row};
    if ($row) {
        # Where it has got to is the clock times the rate, not a frame count:
        # -re paces the frames by the stretched timestamps in the first place,
        # so the clock is the one thing that already knows.
        my $at = $player{from}
               + (time - $player{started}) * ($player{rate} || 1);
        if ($at >= $row->{duration}) {
            on_pause();
            $player{offset} = $row->{duration};
            update_at_label($row->{duration});
            return;
        }
        $player{offset} = $at;
        $scrub_var = $at;
        update_at_label($at);
    }
    $mw->after(66, \&play_tick);
    return;
}

sub nudge {
    my ($seconds) = @_;
    my $row = $player{row} or return;
    my $was_playing = $player{playing};
    on_pause();
    my $at = $player{offset} + $seconds;
    $at = 0 if $at < 0;
    $at = $row->{duration} - 1 if $at > $row->{duration} - 1;
    $at = 0 if $at < 0;
    $player{offset} = $at;
    $scrub_var = $at;
    $was_playing ? on_play() : show_frame($at);
    return;
}

sub stamp_of {
    my ($when) = @_;
    return POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime $when);
}

sub fill_clip_times {
    my $row = $player{row} or return;
    $clip{from} = stamp_of($row->{started});
    $clip{to}   = stamp_of($row->{ended});
    $clip_cam_label->configure(-text => "from camera $row->{camera}");
    return;
}

sub mark_clip {
    my ($which) = @_;
    my $row = $player{row} or return;
    $clip{$which} = stamp_of($row->{started} + $player{offset});
    return;
}

sub on_export {
    my $row = $player{row};
    # A clip comes from one camera: whichever the selected segment belongs to,
    # since that is the view being watched when the span was marked.
    my $camera = $row ? $row->{camera} : 1;
    my ($start, $end);
    my $ok = eval {
        $start = WebcamArchive::parse_when($clip{from});
        $end   = WebcamArchive::parse_when($clip{to});
        1;
    };
    if (!$ok || $end <= $start) {
        $mw->messageBox(-title => 'Clip', -type => 'OK', -icon => 'error',
            -message => $ok ? 'The end time is not after the start time.'
                            : "$@");
        return;
    }

    my ($export, $extension) = WebcamArchive::format_for($clip{format});
    File::Path::make_path($WebcamRecord::CLIPS_DIR);
    my $suggested = sprintf 'clip-cam%d-%s-to-%s%s', $camera,
                    POSIX::strftime('%Y%m%d-%H%M%S', localtime $start),
                    POSIX::strftime('%H%M%S', localtime $end), $extension;
    my $out = $mw->getSaveFile(
        -title => 'Save clip', -initialdir => $WebcamRecord::CLIPS_DIR,
        -initialfile => $suggested, -defaultextension => $extension,
        -filetypes => [ ['MP4 video', '.mp4'], ['Matroska video', '.mkv'],
                        ['AVI video', '.avi'], ['All files', '*'] ]);
    return if !$out;
    # The chosen format wins over whatever the save dialog left on the name:
    # picking MKV and ending up with a file called .mp4 holding matroska would
    # be a file that will not open on half of what opens mp4.
    $out =~ s/\.[^.\/]*$//;
    $out .= $extension;

    $clip_state->configure(-text => 'cutting...');
    $mw->update;
    my $path = eval {
        WebcamArchive::clip(
            start => $start, end => $end, camera => $camera, out => $out,
            export => $export,
            progress => sub {
                $clip_state->configure(-text => $_[0]);
                $mw->update;
            });
    };
    if (!$path) {
        my $problem = $@ || 'the clip could not be written';
        $problem =~ s/\s+$//;
        $clip_state->configure(-text => "clip failed: $problem");
        return;
    }
    $clip_state->configure(-text => sprintf('saved %s (%.0f MB) - %s long',
        File::Basename::basename($path), (-s $path) / 1e6,
        hhmmss($end - $start)));
    return;
}

# ======================================================================
# the settings page
# ======================================================================
#
# The settings window is webcam-settings-page.pl, a script with its own
# MainWindow rather than something that can be packed into a frame here. X11
# can still put it in this tab: a Frame asked for with -container holds
# another program's top-level window, and that program creates its window with
# -use => the container's id. So the settings page really is the old window,
# running as its own process, drawn inside this tab.
#
# Some window managers refuse the embed, and some refuse it only sometimes, so
# nothing here depends on it working: if the child is not up a few seconds
# later, the tab offers to open it as an ordinary separate window instead,
# which always works.

my $settings_child = 0;
my $settings_tried = 0;
my $settings_note;

sub gui_script {
    my $here = File::Basename::dirname(Cwd::abs_path(__FILE__));
    for my $folder ($here, ($ENV{HOME} || ()), '.') {
        my $path = "$folder/webcam-settings-page.pl";
        return $path if -f $path;
    }
    return undef;
}

sub open_settings {
    my ($separate) = @_;
    my $script = gui_script();
    if (!$script) {
        $settings_note->configure(
            -text => 'webcam-settings-page.pl is not next to this file, in '
                   . '$HOME, or in the working directory, so the settings '
                   . 'page cannot be opened.');
        return;
    }
    my @cmd = ($^X, $script);
    push @cmd, '--embed', $container->id if !$separate;
    my $pid = fork;
    return if !defined $pid;
    if (!$pid) {
        exec { $cmd[0] } @cmd;
        exit 127;
    }
    $settings_child = $pid;
    return;
}

$container = $settings_page->Frame(-container => 1)
    ->pack(-fill => 'both', -expand => 1);
$settings_note = $settings_page->Label(
    -text => 'opening the settings page...', -foreground => '#445566',
    -wraplength => 700, -justify => 'left', -font => 'Helvetica 9')
    ->pack(-side => 'bottom', -fill => 'x', -padx => 8, -pady => 2);
$settings_page->Button(
    -text => 'Open settings in its own window',
    -command => sub { open_settings(1) })->pack(-side => 'bottom', -pady => 2);

# Built when the tab is first opened rather than at startup: the settings
# window reads every control off the camera, probes the brain and starts the
# scheduler's terminal, which is a second or two that should not sit in front
# of the video.
$book->pageconfigure('settings', -raisecmd => sub {
    return if $settings_tried;
    $settings_tried = 1;
    open_settings(0);
    $mw->after(4000, sub {
        if ($settings_child && waitpid($settings_child, POSIX::WNOHANG()) != 0) {
            $settings_child = 0;
            $settings_note->configure(
                -text => 'This window manager would not draw the settings '
                       . 'page inside the tab. Use the button below to open '
                       . 'it as its own window - everything in it works the '
                       . 'same either way.');
        }
        else {
            $settings_note->configure(-text => '');
        }
    });
});

# ======================================================================
# away it goes
# ======================================================================

build_panes(scalar WebcamRecord::cameras_of($settings));
on_rescan();

# Open recording, on every enabled camera. See the note at the top of the file
# for why this is the default rather than preview.
$mw->after(400, sub { $recorder->start(1) if !$recorder->is_running });
$mw->after($PREVIEW_MS, \&draw_tick);
$mw->after(700, \&status_tick);

# Take the children with us: the recorders, the playback ffmpeg, and the
# settings window if it is running inside the tab.
$mw->protocol('WM_DELETE_WINDOW', sub {
    on_pause();
    $recorder->stop;
    if ($settings_child) {
        kill 'TERM', $settings_child;
        waitpid $settings_child, 0;
    }
    $mw->destroy;
});

MainLoop;
