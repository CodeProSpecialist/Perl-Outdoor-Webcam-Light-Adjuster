package WebcamArchive;

# The archive: an index of every recorded segment, and clips cut out of it.
#
# Two jobs.
#
# The index. A month of five-minute segments is eight thousand files, and
# answering "what was on camera last Tuesday between 9 and 11 at night" by
# walking eight thousand files and ffprobing each one takes long enough to
# feel broken. So every segment is written once into a tab-separated index -
# start time from its name, duration from one ffprobe, size from the
# filesystem - and searches run against that. Re-scanning is cheap because a
# segment already in the index is skipped unless its size has changed.
#
# A plain TSV file rather than SQLite, deliberately: DBD::SQLite is not core
# perl and this program installs nothing it can avoid installing. A few
# thousand rows read into memory is a few milliseconds, and the index can be
# opened in a text editor when something looks wrong.
#
# The clips. "Download this bit of the archive" almost never lines up with the
# segment boundaries, and the bit wanted usually spans two or three files. So
# a clip is cut by absolute wall-clock time, not by file: the index finds
# every segment of that camera overlapping the wanted span, each is trimmed to
# its overlapping part, and the pieces are concatenated into one video. Where
# the span sits inside a single segment it is a stream copy, which is instant
# and lossless.

use warnings;
use strict;

use File::Basename ();
use File::Path ();
use File::Temp ();
use POSIX ();
use Time::Local ();

use WebcamRecord ();

our $VERSION = '1.00';

our $INDEX_FILE = $WebcamRecord::CONF_DIR . '/archive-index.tsv';
our @COLUMNS = qw(path name day clock started duration ended size camera note);

# What a clip can be exported as. mp4 first and by default: it plays in every
# browser, every phone, Windows, a TV stick and anything that opens a video at
# all, and it is what the archive already holds, so writing it costs nothing
# but the copy.
our @EXPORT_FORMATS = (
    { key => 'mp4',          ext => '.mp4',
      text => 'MP4 - no re-encode, instant, plays everywhere' },
    { key => 'mp4-reencode', ext => '.mp4',
      text => 'MP4 - re-encoded, exact trim, slower' },
    { key => 'mkv',          ext => '.mkv',
      text => 'MKV - no re-encode, survives a bad segment' },
    { key => 'avi',          ext => '.avi',
      text => 'AVI - no re-encode, for older players' },
);

sub format_for {
    my ($label) = @_;
    $label = '' if !defined $label;
    for my $format (@EXPORT_FORMATS) {
        return ($format->{key}, $format->{ext})
            if $label eq $format->{key} || $label eq $format->{text};
    }
    return ('mp4', '.mp4');
}

# ---- the index file ----

sub read_index {
    my %rows;
    open my $fh, '<', $INDEX_FILE or return \%rows;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        my @fields = split /\t/, $line, scalar @COLUMNS;
        next if @fields < 8;
        my %row;
        @row{@COLUMNS} = @fields;
        $row{camera} = 1       if !defined $row{camera} || !length $row{camera};
        $row{note}   = ''      if !defined $row{note};
        $row{$_} += 0 for qw(started duration ended size camera);
        $rows{ $row{path} } = \%row;
    }
    close $fh;
    return \%rows;
}

# Written whole, through a temporary file and a rename: a half-written index is
# worse than no index, and a rename is the one filesystem operation that
# cannot leave one.
sub write_index {
    my ($rows) = @_;
    File::Path::make_path($WebcamRecord::CONF_DIR);
    my $temp = $INDEX_FILE . '.tmp';
    open my $fh, '>', $temp or do {
        warn "archive index not saved: $!\n";
        return 0;
    };
    print {$fh} '# ' . join("\t", @COLUMNS) . "\n";
    for my $path (sort { $rows->{$a}{started} <=> $rows->{$b}{started} }
                  keys %$rows) {
        my $row = $rows->{$path};
        my @out = map { my $v = $row->{$_}; defined $v ? $v : '' } @COLUMNS;
        s/[\t\n]/ /g for @out;
        print {$fh} join("\t", @out), "\n";
    }
    close $fh;
    rename $temp, $INDEX_FILE or do {
        warn "archive index not renamed into place: $!\n";
        return 0;
    };
    return 1;
}

# Which camera a segment came from, read off its folder. Segments sitting
# loose in the archive root are camera 1 - that is where a single camera
# writes, and where every segment recorded before there were several cameras
# still lives.
sub camera_of {
    my ($path) = @_;
    my $folder = File::Basename::basename(File::Basename::dirname($path));
    return $folder =~ /^cam(\d+)$/ ? int($1) : 1;
}

# Seconds, from ffprobe. Zero when the file is still being written or broken -
# a zero-duration row is kept rather than dropped, so the segment still shows
# in a listing and gets its duration on the next scan.
sub probe_duration {
    my ($path) = @_;
    my $out = WebcamRecord::_run(
        'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
        '-of', 'default=nw=1:nk=1', $path);
    my ($seconds) = $out =~ /([\d.]+)/;
    return $seconds ? $seconds + 0 : 0;
}

# Bring the index up to date with what is on disk: new files added, files
# whose size has changed (the newest segment, while it grows) re-probed, and
# rows whose file has gone - recycled by the janitor - dropped.
sub scan {
    my (%args) = @_;
    my $folder  = $args{folder} || WebcamRecord::read_settings()->{archive_dir};
    my $rows    = read_index();
    my $found   = WebcamRecord::segments($folder);
    my %seen;
    my ($added, $updated) = (0, 0);

    for my $segment (@$found) {
        my $path = $segment->{path};
        $seen{$path} = 1;
        my $was = $rows->{$path};
        next if $was && $was->{size} == $segment->{size}
                && $was->{duration} > 0 && !$args{reprobe};
        my $duration = probe_duration($path);
        my @when = localtime $segment->{started};
        my $row = {
            path     => $path,
            name     => File::Basename::basename($path),
            day      => POSIX::strftime('%Y-%m-%d', @when),
            clock    => POSIX::strftime('%H:%M:%S', @when),
            started  => $segment->{started},
            duration => $duration,
            ended    => $segment->{started} + $duration,
            size     => $segment->{size},
            camera   => camera_of($path),
            note     => ($was && defined $was->{note}) ? $was->{note} : '',
        };
        $rows->{$path} = $row;
        $was ? $updated++ : $added++;
        printf "%s %s %ds %.0f MB\n", ($was ? 'updated' : 'added  '),
               $row->{name}, $duration, $segment->{size} / 1e6
            if $args{verbose};
    }

    my @gone = grep { !$seen{$_} } keys %$rows;
    delete $rows->{$_} for @gone;
    write_index($rows);
    printf "%d added, %d updated, %d gone\n", $added, $updated, scalar @gone
        if $args{verbose};
    return { added => $added, updated => $updated, removed => scalar @gone };
}

# ---- searching ----
#
# Date range and time-of-day range are separate on purpose, because the
# question is usually "between nine and eleven at night, across the last week"
# rather than one continuous span - and a time-of-day range that wraps
# midnight (22:00 to 02:00) is handled as the two pieces it really is.

sub search {
    my (%args) = @_;
    my $rows = read_index();
    my @out;

    for my $path (keys %$rows) {
        my $row = $rows->{$path};
        next if $args{day_from}  && $row->{day}   lt $args{day_from};
        next if $args{day_to}    && $row->{day}   gt $args{day_to};
        next if $args{camera}    && $row->{camera} != $args{camera};
        next if $args{min_seconds} && $row->{duration} < $args{min_seconds};

        if ($args{time_from} && $args{time_to}) {
            if ($args{time_from} le $args{time_to}) {
                next if $row->{clock} lt $args{time_from}
                     || $row->{clock} gt $args{time_to};
            }
            else {
                # Wraps midnight: it is the two pieces, not one range.
                next if $row->{clock} lt $args{time_from}
                     && $row->{clock} gt $args{time_to};
            }
        }
        elsif ($args{time_from}) {
            next if $row->{clock} lt $args{time_from};
        }
        elsif ($args{time_to}) {
            next if $row->{clock} gt $args{time_to};
        }

        # Back from now, in seconds: anything overlapping the span counts, so
        # the segment being written when the thing happened is included rather
        # than missed by a few seconds.
        if ($args{since}) {
            my $cutoff = time - $args{since};
            next if $row->{ended} < $cutoff || $row->{started} > time;
        }

        if (defined $args{text} && length $args{text}) {
            my $needle = lc $args{text};
            next if index(lc $row->{name}, $needle) < 0
                 && index(lc $row->{note}, $needle) < 0
                 && index(lc $row->{path}, $needle) < 0;
        }
        push @out, $row;
    }

    my $newest_first = exists $args{newest_first} ? $args{newest_first} : 1;
    @out = $newest_first
         ? sort { $b->{started} <=> $a->{started} } @out
         : sort { $a->{started} <=> $b->{started} } @out;
    my $limit = $args{limit} || 5000;
    @out = @out[0 .. $limit - 1] if @out > $limit;
    return \@out;
}

# Every segment of one camera covering any part of a wall-clock span.
#
# One camera, because a clip is one view: joining two cameras' segments by
# time would cut between views every few minutes, which is not footage anybody
# can watch. The duration test keeps the segment currently being written out of
# a clip: its mp4 has no index yet and trimming it produces nothing playable.
sub overlapping {
    my ($start, $end, $camera) = @_;
    $camera ||= 1;
    my $rows = read_index();
    my @out = grep {
        $_->{duration} > 0 && $_->{camera} == $camera
            && $_->{ended} > $start && $_->{started} < $end
    } values %$rows;
    return [ sort { $a->{started} <=> $b->{started} } @out ];
}

sub set_note {
    my ($path, $note) = @_;
    my $rows = read_index();
    return 0 if !$rows->{$path};
    $note = '' if !defined $note;
    $note =~ s/[\t\n]/ /g;
    $rows->{$path}{note} = $note;
    return write_index($rows);
}

sub stats {
    my $rows = read_index();
    my (%days, %cameras);
    my ($bytes, $seconds, $first, $last) = (0, 0, 0, 0);
    for my $row (values %$rows) {
        $bytes   += $row->{size};
        $seconds += $row->{duration};
        $days{ $row->{day} }        = 1;
        $cameras{ $row->{camera} }++;
        $first = $row->{started} if !$first || $row->{started} < $first;
        $last  = $row->{ended}   if $row->{ended} > $last;
    }
    return {
        segments   => scalar keys %$rows,
        gigabytes  => $bytes / (1024 ** 3),
        hours      => $seconds / 3600,
        days       => scalar keys %days,
        cameras    => \%cameras,
        first      => $first ? POSIX::strftime('%Y-%m-%d %H:%M:%S',
                                               localtime $first) : '',
        last       => $last  ? POSIX::strftime('%Y-%m-%d %H:%M:%S',
                                               localtime $last) : '',
    };
}

# ---- times typed in by hand ----

# "2026-11-12 21:35:00", "21:35" for today, or a unix number.
sub parse_when {
    my ($text) = @_;
    $text = '' if !defined $text;
    $text =~ s/^\s+|\s+$//g;
    return $text + 0 if $text =~ /^\d{6,}$/;

    if (my @p = $text =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d))?$/) {
        return Time::Local::timelocal($p[5] || 0, $p[4], $p[3],
                                      $p[2], $p[1] - 1, $p[0]);
    }
    if (my @p = $text =~ /^(\d{4})-(\d\d)-(\d\d)$/) {
        return Time::Local::timelocal(0, 0, 0, $p[2], $p[1] - 1, $p[0]);
    }
    if (my @p = $text =~ /^(\d\d?):(\d\d)(?::(\d\d))?$/) {
        my @now = localtime;
        return Time::Local::timelocal($p[2] || 0, $p[1], $p[0],
                                      $now[3], $now[4], $now[5] + 1900);
    }
    die "cannot read a time out of '$text'\n";
}

# HH:MM typed in becomes HH:MM:SS, because the column holds seconds and a
# string compare of '21:00' against '21:00:00' is not equal.
sub hhmm {
    my ($text) = @_;
    return undef if !defined $text || !length $text;
    my @parts = split /:/, $text;
    push @parts, 0 while @parts < 3;
    return sprintf '%02d:%02d:%02d', $parts[0] || 0, $parts[1] || 0,
                   $parts[2] || 0;
}

# ---- cutting a clip out ----

# What to hand ffmpeg for each export. Everything but mp4-reencode is a
# straight copy - the container changes, the video does not.
sub _codec {
    my ($export) = @_;
    return ('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
            '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an')
        if $export eq 'mp4-reencode';
    return ('-c', 'copy');
}

sub _ffmpeg {
    my (@args) = @_;
    my $out = WebcamRecord::_run('ffmpeg', '-nostdin', '-hide_banner',
                                 '-loglevel', 'error', '-y', @args);
    return 1 if $? == 0;
    $out =~ s/\s+$//;
    warn "ffmpeg: " . substr($out, 0, 400) . "\n" if length $out;
    return 0;
}

# One video covering start..end, cut from however many segments it spans.
#
# Four exports, and the difference between them is worth knowing:
#
# mp4, mkv and avi copy the recorded h264 through untouched, so they take a
# second whatever the clip's length and lose nothing at all. The cost is that
# a copy can only start on a keyframe, so the clip can open up to two seconds
# before the time asked for - with the recorder's two-second keyframe spacing,
# never more than that.
#
# mp4-reencode re-encodes, which starts on the exact frame asked for and costs
# roughly real time to write. Worth it when the moment matters, or when a
# copied clip opened on a frozen picture.
sub clip {
    my (%args) = @_;
    my $start  = $args{start};
    my $end    = $args{end};
    my $camera = $args{camera} || 1;
    my $export = $args{export} || 'mp4';
    my $say    = $args{progress} || sub { };
    die "the clip ends before it starts\n" if $end <= $start;

    my $rows = overlapping($start, $end, $camera);
    die "camera $camera has nothing recorded over that time - try Rescan, "
        . "widen the span, or pick the camera that was watching\n"
        if !@$rows;

    File::Path::make_path($WebcamRecord::CLIPS_DIR);
    my $out = $args{out};
    if (!$out) {
        my (undef, $ext) = format_for($export);
        $out = sprintf '%s/clip-cam%d-%s-to-%s%s',
               $WebcamRecord::CLIPS_DIR, $camera,
               POSIX::strftime('%Y%m%d-%H%M%S', localtime $start),
               POSIX::strftime('%H%M%S', localtime $end), $ext;
    }

    if (@$rows == 1) {
        my $row    = $rows->[0];
        my $offset = $start - $row->{started};
        $offset = 0 if $offset < 0;
        my $length = (($end < $row->{ended}) ? $end : $row->{ended})
                   - (($start > $row->{started}) ? $start : $row->{started});
        $say->("trimming $row->{name}"
               . ($export eq 'mp4-reencode' ? ' and re-encoding' : ''));
        die "ffmpeg could not write the clip - see the error log\n"
            if !_ffmpeg('-ss', sprintf('%.3f', $offset), '-i', $row->{path},
                        '-t', sprintf('%.3f', $length), _codec($export),
                        '-avoid_negative_ts', 'make_zero', $out);
        return $out;
    }

    my $work = File::Temp::tempdir('webcam-clip-XXXXXX', TMPDIR => 1,
                                   CLEANUP => 1);
    my @pieces;
    my $number = 0;
    for my $row (@$rows) {
        $number++;
        my $piece_start = ($start > $row->{started}) ? $start : $row->{started};
        my $piece_end   = ($end   < $row->{ended})   ? $end   : $row->{ended};
        my $length      = $piece_end - $piece_start;
        next if $length <= 0.05;
        # The pieces are always copied, however the clip is exported:
        # re-encoding each piece and then joining them would encode the same
        # frames twice and show a seam at every join. Any re-encode happens
        # once, at the join below.
        my $piece = sprintf '%s/part%03d.mp4', $work, $number;
        $say->("trimming $row->{name} ($number of " . scalar(@$rows) . ')');
        push @pieces, $piece
            if _ffmpeg('-ss', sprintf('%.3f', $piece_start - $row->{started}),
                       '-i', $row->{path}, '-t', sprintf('%.3f', $length),
                       '-c', 'copy', '-avoid_negative_ts', 'make_zero',
                       $piece);
    }
    die "nothing could be trimmed out of those segments\n" if !@pieces;

    if (@pieces == 1 && $export ne 'mp4-reencode') {
        rename $pieces[0], $out or die "cannot move the clip into place: $!\n";
        return $out;
    }

    my $listing = "$work/parts.txt";
    open my $fh, '>', $listing or die "cannot write the join list: $!\n";
    print {$fh} "file '$_'\n" for @pieces;
    close $fh;
    $say->('joining ' . scalar(@pieces) . ' pieces'
           . ($export eq 'mp4-reencode' ? ' and re-encoding' : ''));
    die "the pieces were cut but would not join - see the error log\n"
        if !_ffmpeg('-f', 'concat', '-safe', '0', '-i', $listing,
                    _codec($export), $out);
    return $out;
}

# ---- playback helpers ----
#
# Perl/Tk has no video widget and this program installs nothing it can avoid
# installing, so playback is ffmpeg decoding to PPM frames and Tk::Photo
# drawing them. Two ways in, for the two things the window needs.

# One frame, at an offset into a segment, written as a PPM the window can
# read. This is what the scrub bar uses: seeking is a fresh one-frame ffmpeg,
# which at -ss before -i is near instant however far into the file it is.
sub frame_at {
    my (%args) = @_;
    my $out = $args{out} || "$WebcamRecord::STATE_DIR/scrub.ppm";
    File::Path::make_path($WebcamRecord::STATE_DIR);
    my $scale = 'scale=' . int($args{width} || 640) . ':'
              . int($args{height} || 360);
    return _ffmpeg('-ss', sprintf('%.3f', $args{offset} || 0),
                   '-i', $args{path}, '-frames:v', '1', '-vf', $scale,
                   '-f', 'image2', $out) ? $out : undef;
}

# The command for smooth playback: PPM frames written over one file, already
# scaled, at the speed they were recorded.
#
# One file overwritten rather than frames down a pipe, because that is exactly
# what the live preview already does - so playback draws through the same code
# path as the camera does, and there is no PPM pipe to parse frame by frame in
# Perl. The window reads the file on its timer; ffmpeg replaces it underneath.
#
# -re is what paces it. Without it ffmpeg decodes as fast as the disk allows
# and an hour of footage would go past in twenty seconds; with it the frames
# are replaced at the rate they were recorded, which is what "play" means.
# `rate` is how much footage runs per second of clock: 1 is normal, 1/6 is six
# times slow motion, 60 is a minute of footage a second.
#
# -readrate is what does it, and it has to be -readrate rather than the more
# obvious -re: -re reads the input at its native rate, so it can slow a stream
# down to real time but can never run one faster, and fast forward is exactly
# asking for faster. -readrate takes the multiplier. Nothing here uses setpts,
# because the output is one file being overwritten rather than a stream with a
# clock - what paces the writes is the rate the input is read at, and
# timestamps on an overwritten file mean nothing at all.
#
# The fps filter then caps how many of those frames get written. At the slow
# end none is needed: a 30fps recording read at a sixth of normal speed is
# already only five frames a second. At the fast end it is everything - a
# minute of footage a second is 1800 frames a second, which no screen draws
# and no eye reads - so fps is set to draw_fps/rate, which works out to one
# frame every few seconds of footage, and the frames in between are never
# decoded.
our $NO_READRATE = '';
sub _has_readrate {
    return 1 if $NO_READRATE eq 'yes';
    return 0 if $NO_READRATE eq 'no';
    my $ok = (WebcamRecord::_run('ffmpeg', '-hide_banner', '-h', 'full')
              =~ /readrate/) ? 1 : 0;
    $NO_READRATE = $ok ? 'yes' : 'no';
    return $ok;
}

sub play_command {
    my (%args) = @_;
    my $rate     = $args{rate} || 1;
    my $draw_fps = $args{fps}  || 15;
    my $src_fps  = $args{src_fps} || 30;

    # Without -readrate the only pacing available is -re, which cannot go
    # faster than real time. Slow motion and normal speed still work; fast
    # forward is held at normal speed and the window says so rather than
    # quietly running an hour of footage past in a blur.
    my @pace = _has_readrate() ? ('-readrate', sprintf('%.6f', $rate))
                               : ('-re');
    my @filter;
    if ($rate > 1.01) {
        my $cap = $draw_fps / $rate;
        push @filter, sprintf('fps=%.6f', $cap) if $cap < $src_fps;
    }
    push @filter, 'scale=' . int($args{width} || 640) . ':'
                . int($args{height} || 360);

    return [
        'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
        @pace, '-ss', sprintf('%.3f', $args{offset} || 0),
        '-i', $args{path},
        '-an', '-vf', join(',', @filter),
        '-update', '1', '-f', 'image2', WebcamRecord::_image2_atomic(),
        ($args{out} || "$WebcamRecord::STATE_DIR/playback.ppm"),
    ];
}

# True when this ffmpeg cannot be asked to read faster than real time, so the
# window can say that fast forward is unavailable rather than looking broken.
sub fast_forward_available { return _has_readrate() ? 1 : 0; }

1;
