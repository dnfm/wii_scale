#!/usr/bin/perl

use strict;
use warnings;

use xwiimote;

use Try::Tiny;
use List::Util qw( sum );
use IO::Poll qw( POLLIN );
use POSIX qw( ceil floor );
use Pod::Usage;
use Getopt::Long;
use Term::ANSIScreen qw( :color :cursor :screen :constants );

# Set to 0 to leave it in kg.
my $convert_to_pounds  = 0;

# If your balance board reads off by X, set that here.  It can be negative,
# and is in the same units as you use in this app, so if you have
# convert_to_pounds set to 1, then this is the fudge factor in pounds.
# Otherwise, it's in kg.
my $fudge_factor       = 0;

# The width of the scale graphic in beautiful ASCII text.
my $scale_width        = 80;

# The height of the scale graphic in beautiful ASCII text.
my $scale_height       = 20;
 
# Exit on weight means once the scale has concluded the weight has stopped
# shifting around/changing enough to get an accurate reading, it'll quit.
# Otherwise, ctrl-c to quit.
my $exit_on_weight     = 0;

# Disconnect the wii scale once a weight is calculated.
my $disconnect_on_exit = 0;

# Whether to display help and quit.
my $help               = 0;

GetOptions(
    'fudge_factor=f'     => \$fudge_factor,
    'use_pounds'         => \$convert_to_pounds,
    'scale_width=i'      => \$scale_width,
    'scale_height=i'     => \$scale_height,
    'exit_on_weight'     => \$exit_on_weight,
    'disconnect_on_exit' => \$disconnect_on_exit,
    'help'               => \$help,
) or pod2usage( 1 );

pod2usage( 0 ) if $help;

$Term::ANSIScreen::AUTORESET = 1;

my %types = (
    generic       => 'Generic Wii Device',
    gen10         => 'First Generation WiiMote',
    gen20         => 'Second Generation WiiMote Plus',
    balanceboard  => 'Wii Balance Board',
    procontroller => 'Nintendo Wii Pro Controller',
    unknown       => 'Unknown Wii Device',
);

$SIG{ INT }  = \&restore_cursor_and_exit;
$SIG{ TERM } = \&restore_cursor_and_exit;

go();

my $device_mac;

sub restore_cursor_and_exit {
    print cls();

    loadpos();

    print "\e[?25h";

    print "$_[0]\n" if $_[0] && $_[0] !~ m/^INT|TERM$/;

    system( 'bluetoothctl', 'disconnect', $device_mac ) if $device_mac;

    exit;
}

sub go {
    savepos();

    print cls();

    my $using;
    my $iface;

    OPEN_DEVICE: {
        try {
            my $iterations = 0;
            my %seen;

            print "Turn your balance board on now.\n";

            while ( $iterations++ < 60 ) {
                sleep 1;

                my $monitor = xwiimote::monitor->new( 1, 1 );

                while ( defined( my $entry = $monitor->poll ) ) {
                    my $identity = identify( $entry );

                    # if it's still working on identifying it, ignore it for now.
                    next if $identity eq 'pending';

                    next if $seen{ $entry }++;

                    my $name = $types{ $identity } // $types{ unknown };
                    my $n    = substr( $name, 0, 1 ) =~ m{[aeiou]} ? 'n' : '';

                    print "Found a$n $name.";

                    if ( $identity eq 'balanceboard' ) {
                        print "  Using it!";

                        $using = $entry;
                    }
                    elsif ( $identity eq 'unknown' ) {
                        redo OPEN_DEVICE;
                    }

                    print "\n";
                }

                last if defined $using;

                sleep 1;
            }
        }
        catch {
            die "couldn't create a monitor: $_\n";
        };

        if ( !defined $using ) {
            die "Timed out trying to find a balance board.\n";
        }

        local $SIG{ ALRM } = sub { die "ALARM\n" };
        alarm( 5 );

        try {
            $iface = get_iface( $using );

            $iface->open( $iface->available() | $xwiimote::IFACE_WRITABLE );
        }
        catch {
            alarm( 0 );

            if ( $_ eq 'ALARM' ) {
                warn "Timed out trying to open the device.  Trying again.\n";

                undef $iface;

                redo OPEN_DEVICE;
            }

            die "Couldn't open balance board device: $_\n";
        };

        alarm( 0 );
    }
    
    die "Failed or timed out opening a device.\n" if !$iface;

    print "Opened.\n";

    # Find the device's mac address so we can tell bluetoothctl to disconnect it.
    $device_mac = get_device_mac( $iface ) if $disconnect_on_exit;

    # Seed the battery information (and this will start the poller.)
    update_battery( $iface );
}

sub get_device_mac {
    my ( $iface ) = @_;

    my $path = $iface->get_syspath();

    my $return_sub = sub {
        warn "$_[0]; can't automatically disconnect.\n";

        return;
    };

    return $return_sub->( "Couldn't get device path" ) if !$path;

    my $uevent_file = "$path/uevent";

    return $return_sub->( "$uevent_file isn't readable" ) if !-r $uevent_file;

    open my $fh, '<', $uevent_file;

    return $return_sub->( "Couldn't open $uevent_file: $!" ) if !$fh;

    chomp( my ( $mac ) = map { /^HID_UNIQ=(\S+)/ } grep { /^HID_UNIQ/ } <$fh> );

    return $return_sub->( "Didn't find MAC in $uevent_file." ) if !$mac;

    return $mac;
}

sub get_iface {
    my ( $entry ) = @_;

    return try {
        xwiimote::iface->new( $entry );
    }
    catch {
        die "can't create interface to wii device: $_\n";
    };
}

sub identify {
    my ( $entry ) = @_;

    return get_iface( $entry )->get_devtype();
}

sub poller {
    my ( $iface ) = @_;

    my $poller = IO::Poll->new();
    my $fdh    = IO::Handle->new_from_fd( $iface->get_fd(), 'r' );

    $poller->mask( $fdh => POLLIN );

    my $event = xwiimote::event->new();

    # Every 10 seconds, ask for the battery status.  It's not important that we
    # update that very often.
    local $SIG{ ALRM } = sub { update_battery( $iface ) };
    alarm( 10 );

    show_scale();

    while ( $poller->poll() != -1 ) {
        try {
            $iface->dispatch( $event );

            if ( $event->{ type } == $xwiimote::EVENT_GONE ) {
                die 'balance board went away.';
            }

            if ( $event->{ type } == $xwiimote::EVENT_BALANCE_BOARD ) {
                update_weights( $event );

                show_scale();
            }
        }
        catch {
            die "Couldn't read from balance board: $_\n"
                if !$!{EAGAIN};
        };
    }
}

sub show_scale {
    my $battery = get_battery();
    my %weights = get_weights();

    locate( 1, 1 );

    print "\e[?25l";

    my $p = BOLD BLUE . '|' . RESET;

    my $weight = ( $weights{ average } // 0 )
               . ( $convert_to_pounds ? ' lbs' : ' kg' );

    # the pipes or pluses on each side removes 2 chars.
    my $space = $scale_width - 2;

    my $mid_line = '+'
                 . '-' x floor(( $space - 1 ) / 2 )
                 . '+'
                 . '-' x ceil( ( $space - 1 ) / 2 )
                 . "+";

    # top, mid, and bottom are subtracted.
    my $lines_around_mid = ( $scale_height - 3 ) / 2;

    print BOLD BLUE . '+' . '-' x $space . "+\n";
    print $p . centre( "Wii Balance Board (Battery $battery%)", $space ) . "$p\n";
    print $p . BOLD BLUE . '-' x $space . "$p\n";
    print $p . centre( $weight, $space ) . "$p\n";

    # put the characters into a matrix, replace the one char showing the
    # position with an x, and then print it.
    my @matrix;

    push @matrix, $mid_line;

    push @matrix, '|' . centre( '|', $space ) . '|'
        for 1 .. floor( $lines_around_mid );

    push @matrix, $mid_line;

    push @matrix,'|' . centre( '|',, $space ) . '|'
        for 1 .. ceil( $lines_around_mid );

    push @matrix, $mid_line;
    
    $_ = [ split m{}, $_ ] for @matrix;

    insert_x( \@matrix );

    foreach my $line ( @matrix ) {
        print $_ eq 'X' ? 'X' :  BOLD BLUE . $_ for @{ $line };
        print "\n";
    }

    print "\e[?25h";
}

sub centre {
    my ( $str, $size ) = @_;

    ( my $stripped = $str ) =~ s/\e\[[0-9;]*m//g;

    my $lpad = floor( ( $size / 2 ) - ( length( $stripped ) / 2 ) );
    my $rpad = ceil(  ( $size / 2 ) - ( length( $stripped ) / 2 ) );

    return ' ' x $lpad 
         . $str
         . ' ' x $rpad;
}

{
    my ( $tl, $tr, $bl, $br );

    my @samples;
    my $total;
    my $avg;

    my %got_weight;

    # the average updates way less often.
    my $average_calls = 0;

    sub insert_x {
        my ( $matrix ) = @_;

        my $height = scalar( @{ $matrix      } );
        my $width  = scalar( @{ $matrix->[0] } );

        $tl //= 0;
        $tr //= 0;
        $bl //= 0;
        $br //= 0;

        my $left  = $tl + $bl;
        my $right = $tr + $br;
        my $up    = $tl + $tr;
        my $down  = $bl + $br;

        my $lr = $right / ( ( $left + $right ) || 1 );
        my $ud = $down  / ( ( $up   + $down  ) || 1 );

        my $x = int( $lr * $width  ) - 1;
        my $y = int( $ud * $height ) - 1;

        $x = 0 if $x < 0;
        $y = 0 if $y < 0;

        $matrix->[ $y ]->[ $x ] = 'X';
    }

    sub update_weights {
        my ( $event ) = @_;

        my $conversion = $convert_to_pounds ? 2.205 : 1;

        my $conv = sub {
            my $measure = ( $event->get_abs($_[0]) )[0] * $conversion / 100;

            # Hopefully weed out the scale jumping around near 0.
            $measure = 0 if $measure < 1;

            return $measure;
        };

        $tl = $conv->(2);
        $tr = $conv->(0);
        $bl = $conv->(3);
        $br = $conv->(1);

        $total = sprintf( '%.2f', $tl + $tr + $bl + $br );

        my $time = time;

        $got_weight{ $time } = $total if $total + ( $fudge_factor // 0 ) > 0;

        my $close_enough = 1;

        my @range = ( $time - 5 ) .. $time;

        foreach my $sample ( @range ) {
            if ( !defined $got_weight{ $sample } || $got_weight{ $sample } < 10 ) {
                $close_enough = 0;

                last;
            }

            if (   $total - .25 > $got_weight{ $sample }
                || $total + .25 < $got_weight{ $sample } ) {

                $close_enough = 0;

                last;
            }
        }

        my $f_avg = sprintf( '%.2f', ( sum( map { $got_weight{ $_ } // 0 } @range ) / 6 ) );

        if ( $close_enough && $exit_on_weight ) {
            alarm( 0 );

            sleep 1;

            restore_cursor_and_exit( "$f_avg" . ( $convert_to_pounds ? 'lbs' : 'kg' ) );
        }

        # if the total weight is less than the fudge factor, don't use it --
        # basically, if it's near 0, it's probably actually zero.
        $total += $fudge_factor if $total >= $fudge_factor and $total > 2;

        $avg = calculate_average();
    }

    sub calculate_average {
        # if the total has changed more than 10%, then assume the weight on
        # the board is actually being changed.
        if ( $total && $avg && ( $total < $avg * .9 || $total > $avg * 1.1 ) ) {
            @samples = ( $total );
        }
        else {
            push @samples, $total;
        }

        if ( scalar( @samples ) > 100 ) {
            shift @samples while scalar( @samples ) > 100;
        }

        # Only actually update the average every 50 updates; the Wii Balance
        # board is *very* sensitive, so it'll be feeding us data super fast.
        if ( !( $average_calls++ % 50 ) ) {
            $avg = sprintf( '%.1f', sum( @samples ) / scalar( @samples ) );
        }

        return $avg;
    }

    sub get_weights {
        (
            tl      => $tl,
            tr      => $tr,
            bl      => $bl,
            br      => $br,
            total   => $total,
            average => $avg,
        )
    }
}

{
    my $battery;

    sub update_battery {
        my ( $iface ) = @_;

        $battery = try { $iface->get_battery() }
                 catch { $battery };

        alarm( 10 );

        # Back to the poller.
        poller( $iface );
    }

    sub get_battery { $battery }
}

__END__

=head1 NAME

scale.pl - Use the wii scale on your system with xwiimote like a standard
bathroom scale.

=head1 SYNOPSIS

Options can be set in the variables at the top of the file manually, or
specified on the command line here.  The command line will override values in
the file.

scale.pl [options]

Options:

    --help
        You're reading it.

    --fudge_factor=<amount> [default: 0]
        Some scales consistently read too high or too low.  This will adjust
        the reading by <amount>.  Negative and decimal values are OK.  In the
        same units as the program is being used.

    --use_pounds
        Whether to display the weight in lbs.  Default is kg.

    --scale_width=<amount> [default: 80]
        Width of the scale ansi graphic in columns.

    --scale_height=<amount> [default: 20]
        Height of the scale ansi graphic in rows.

    --exit_on_weight
        By default, this program will just keep reading from the scale.  To
        quit, you'd hit CTRL-C.  If this is enabled, then once the program
        detects the weight has settled and it has an accurate read, it will
        quit and display the final reading.

    --disconnect_on_exit
        By default, the program will just exit.  If you specify this option, it
        will shell out to bluetoothctl and issue a disconnect to the scale.
        Keep in mind the wii scale has no power management, and if you don't
        disconnect your system from it, it will happily just sit there
        connected until the battery dies.  Good job, Nintendo.  This only works
        on Linux and the way it does it is a little gross, but it works for me.
        Patches welcome and all that.

=head1 AUTHOR

    Justin Wheeler <github dot com at datademons dot com>

=head1 LICENSE

    This program is distributed under the same license as Perl itself.
