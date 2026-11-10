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

    my @missing = grep { _module_missing($_) } @modules;

    my @missing_programs =
        grep { !_have_program($_) } sort keys %APT_FOR_PROGRAM;

    if (!@missing) {
        if (@missing_programs) {
            my @packages =
                _unique(map { $APT_FOR_PROGRAM{$_} } @missing_programs);
            my $it = @missing_programs == 1 ? 'it' : 'them';
            warn "webcam: not installed: @missing_programs - the schedule "
               . "runs without $it, the automatic light adjustment does "
               . "not. To add $it: " . _apt_command(@packages) . "\n";
        }
        return;
    }

    my @packages = _unique(
        map { $APT_FOR{$_} || () } @missing
    );

    my @unknown = grep { !$APT_FOR{$_} } @missing;

    print "\n";
    print "webcam: these Perl modules are needed and not installed:\n";
    print "  $_\n" for @missing;
    print "\n";

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

    if (@still_missing) {
        print "\napt finished, but these still will not load:\n";
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

1;
