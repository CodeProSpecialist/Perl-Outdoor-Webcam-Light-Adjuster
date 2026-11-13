package WebcamBootstrap;

# First-run dependency check for the webcam programs.
#
# Every entry script calls ensure() in a BEGIN block, before its own `use`
# lines, naming the modules it needs. If they are all installed this returns
# immediately and nothing is printed. If any is missing it offers to install
# the apt packages that provide them.
#
# Why this exists: the failure without it is a compile-time "Can't locate
# DateTime.pm in @INC" followed by thirty lines of @INC paths, which says
# nothing about which apt package to install. This names the package.
#
# Three rules it follows, which are the whole reason it is safe to have a
# camera program touching apt at all:
#
#   1. It never installs without being told to. On a terminal it asks, and
#      prints the exact command first. Answer anything but yes and it exits
#      having changed nothing.
#   2. With no terminal - under cron, systemd, a pipe - it does not ask and
#      does not install. It prints the command and exits non-zero. A prompt
#      there would hang forever waiting for an answer nobody can give, and
#      the scheduler would silently never start.
#   3. It only ever installs from apt, and only the packages in the table
#      below. No cpan, no building, nothing from the network beyond apt's own
#      repositories. cpan builds into ~/perl5, which then has to be rebuilt
#      by hand every time the system perl changes version - the apt packages
#      are rebuilt for you, which is why they are the only thing offered.
#
# sudo asks for the password itself, on the terminal, in its own way. Nothing
# here reads, stores or passes a password.
#
# Set WEBCAM_NO_BOOTSTRAP=1 to skip all of this - for a machine where the
# modules come from somewhere other than apt, which is a legitimate setup and
# not something this should argue with.

use strict;
use warnings;

# Module -> the apt package that provides it.
my %APT_FOR = (
    'DateTime'                 => 'libdatetime-perl',
    'DateTime::Duration'       => 'libdatetime-perl',
    'DateTime::Event::Sunrise' => 'libdatetime-event-sunrise-perl',
    'Tk'                       => 'perl-tk',
);

# Command-line programs the light meter and snapshots need. Missing ones are
# mentioned once and nothing more: the schedule still runs without them, only
# the automatic light adjustment stays idle, and the programs already say so
# at startup themselves.
my %APT_FOR_PROGRAM = (
    'v4l2-ctl' => 'v4l-utils',
    'ffmpeg'   => 'ffmpeg',
);

sub _module_missing {
    my ($module) = @_;
    my $path = $module . '.pm';
    $path =~ s{::}{/}g;
    local $SIG{__WARN__} = sub { };
    return !eval { require $path; 1 };
}

sub _have_program {
    my ($program) = @_;
    for my $dir (split /:/, ($ENV{PATH} || '/usr/bin:/bin')) {
        return 1 if -x "$dir/$program";
    }
    return 0;
}

sub _interactive {
    # Both ends matter: STDIN to answer the question, STDOUT to read it.
    return -t STDIN && -t STDOUT;
}

sub ensure {
    my (@modules) = @_;

    return if $ENV{WEBCAM_NO_BOOTSTRAP};

    # A name in the program table is a program, not a module. Taking one as
    # a module name is how the Python side used to refuse to start on a
    # machine that had the ffmpeg encoder but no same-named package from
    # PyPI, so the same guard is here.
    @modules = grep { !exists $APT_FOR_PROGRAM{$_} } @modules;

    my @missing = grep { _module_missing($_) } @modules;

    my @missing_programs =
        grep { !_have_program($_) } sort keys %APT_FOR_PROGRAM;

    return if !@missing && !@missing_programs;

    # A missing program is installed here too, not merely reported. ffmpeg is
    # the one that matters: without it there is no recording at all, so a
    # first run on a clean machine should fix that itself rather than hand
    # back an apt command. On a terminal it offers to install, exactly as it
    # does for a Perl module. Headless, and with the Perl modules all
    # present, it keeps the old behaviour and warns rather than exiting: a
    # cron job that still does something useful is better than one that dies.
    if (!@missing && !_interactive()) {
        my @packages =
            _unique(map { $APT_FOR_PROGRAM{$_} } @missing_programs);
        my $it = @missing_programs == 1 ? 'it' : 'them';
        my %why = ('ffmpeg'   => 'there is no recording without ffmpeg',
                   'v4l2-ctl' => 'the automatic light adjustment needs '
                               . 'v4l2-ctl');
        my $why = join ' and ', map { $why{$_} } grep { $why{$_} }
                                @missing_programs;
        warn "webcam: not installed: @missing_programs - $why. "
           . "To add $it: " . _apt_command(@packages) . "\n";
        return;
    }

    my @packages = _unique(
        (map { $APT_FOR{$_} || () } @missing),
        (map { $APT_FOR_PROGRAM{$_} } @missing_programs),
    );

    my @unknown = grep { !$APT_FOR{$_} } @missing;

    print "\n";
    if (@missing) {
        print "webcam: these Perl modules are needed and not installed:\n";
        print "  $_\n" for @missing;
        print "\n";
    }
    if (@missing_programs) {
        print "webcam: these programs are needed and not installed:\n";
        print "  $_\n" for @missing_programs;
        print "\n";
    }

    if (@unknown) {
        print "No apt package is known here for: @unknown\n";
        print "Install those yourself, then run this again.\n\n";
        exit 1 if !@packages;
    }

    my $apt = _apt_command(@packages);

    if (!_interactive()) {
        # cron, systemd, a pipe. Asking would hang.
        print "Not running on a terminal, so nothing will be installed here.\n";
        print "Run this once, by hand:\n\n";
        print "    $apt\n\n";
        print "Then start this again.\n\n";
        exit 1;
    }

    print "This can install them now with:\n\n";
    print "    $apt\n\n";
    print "sudo will ask for your password.\n" if $apt =~ /^sudo /;
    print "Install them? [y/N] ";

    my $answer = <STDIN>;
    $answer = '' if !defined $answer;
    $answer =~ s/^\s+|\s+$//g;

    if ($answer !~ /^y(es)?$/i) {
        print "\nNothing installed. Run the command above when you are ready.\n\n";
        exit 1;
    }

    print "\n";
    my $status = system($apt);

    if ($status != 0) {
        print "\nThat did not finish - apt exited "
            . ($status == -1 ? "without running" : $status >> 8)
            . ".\n";
        print "Run it by hand to see what it says:\n\n";
        print "    $apt\n\n";
        exit 1;
    }

    # apt succeeding is not the same as the modules now loading: a package can
    # install and still not provide what was asked for, if the table above is
    # wrong about which package holds which module. Check rather than assume,
    # because the alternative is the original "Can't locate" error two lines
    # later, now with an apt run in front of it confusing the picture.
    my @still_missing = grep { _module_missing($_) } @missing;
    push @still_missing, grep { !_have_program($_) } @missing_programs;

    if (@still_missing) {
        print "\napt finished, but these still are not there:\n";
        print "  $_\n" for @still_missing;
        print "\nThat means the package named above does not provide them on "
            . "this release.\n\n";
        exit 1;
    }

    print "\nInstalled. Carrying on.\n\n";
    return;
}

sub _apt_command {
    my (@packages) = @_;
    my $sudo = ($> == 0) ? '' : 'sudo ';
    $sudo = '' if $sudo && !_have_program('sudo');
    return "${sudo}apt-get -y install " . join(' ', @packages);
}

sub _unique {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

# ---- the python side of the dependencies, printed step by step ----
#
# Everything above is about perl: Tk, and the apt packages that provide the
# command-line tools. The correction itself is python - OpenCV for the
# stacking, the CLAHE and the detector, TensorFlow for brain G - and those are
# the two that actually break, so they are installed by webcam_install.py,
# which knows about conda and pip and prints every step as it goes.
#
# Its output is streamed straight through to this terminal rather than
# captured, because a pip resolving TensorFlow is quiet for a long time and a
# captured install looks exactly like a hung one. It never exits non-zero in a
# way that stops us: a window that will not open because an optional
# dependency is missing is worse than one that opens and says so in the tile.
sub ensure_python_stack {
    return if $ENV{WEBCAM_NO_BOOTSTRAP};

    my $helper = '';
    my @where = ('.');
    if ($0 =~ m{^(.*)/[^/]+$}) { unshift @where, $1; }
    push @where, "$ENV{HOME}/Pictures/webcam" if $ENV{HOME};
    for my $dir (@where) {
        next unless defined $dir && length $dir;
        if (-f "$dir/webcam_install.py") { $helper = "$dir/webcam_install.py"; last; }
    }
    unless (length $helper) {
        print "webcam: webcam_install.py is not here, so the python "
            . "dependencies are not being checked\n";
        return;
    }
    if (system('command -v python3 >/dev/null 2>&1') != 0) {
        print "webcam: no python3, so OpenCV, TensorFlow and the detector "
            . "cannot be installed or used\n";
        print "  to add it: apt-get -y install python3\n";
        return;
    }

    print "webcam: checking the python side - OpenCV, TensorFlow, numpy, "
        . "astral\n";
    my $quoted = $helper;
    $quoted =~ s/(['\\])/\\$1/g;
    # Line by line, with the helper's own output passed through unchanged so
    # that the two windows print the same words for the same situation.
    if (open my $pipe, '-|', "python3 '$quoted' 2>&1") {
        while (my $line = <$pipe>) {
            print $line;
        }
        close $pipe;
    } else {
        print "webcam: could not run the python dependency check: $!\n";
    }
    print "\n";
    return 1;
}

1;
