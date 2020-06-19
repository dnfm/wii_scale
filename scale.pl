#!/usr/bin/perl

use strict;
use warnings;

use xwiimote;

use Readonly;
use Try::Tiny;
use List::Util qw( sum );
use IO::Poll qw( POLLIN );
use POSIX qw( ceil floor );
use Term::ANSIScreen qw( :color :cursor :screen :constants );


# Set to 0 to leave it in kg.
Readonly my $convert_to_pounds => 1;

# If your balance board reads off by X, set that here.  It can be negative,
# and is in the same units as you use in this app, so if you have
# convert_to_pounds set to 1, then this is the fudge factor in pounds.
# Otherwise, it's in kg.
Readonly my $fudge_factor      => 0;

# The width of the scale graphic in beautiful ASCII text.
Readonly my $scale_width       => 80;

# The height of the scale graphic in beautiful ASCII text.
Readonly my $scale_height      => 20;
 
$Term::ANSIScreen::AUTORESET = 1;

my %types = (
    generic       => 'Generic Wii Device',
    gen10         => 'First Generation WiiMote',
    gen20         => 'Second Generation WiiMote Plus',
    balanceboard  => 'Wii Balance Board',
    procontroller => 'Nintendo Wii Pro Controller',
    unknown       => 'Unknown Wii Device',
);

$SIG{ INT }  = \&restore_cursor;
$SIG{ TERM } = \&restore_cursor;

go();

sub restore_cursor {
    locate( 1, 1 );

    print "\e[?25h";

    warn "$_[0]\n" if $_[0];

    exit;
}

sub go {
    print cls();

    my $using;

    try {
        my $iterations = 0;
        my %seen;

        print "Turn your balance board on now.\n";

        while ( $iterations++ < 60 ) {
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

    my $iface = get_iface( $using );

    try {
        $iface->open( $iface->available() | $xwiimote::IFACE_WRITABLE );
    }
    catch {
        die "Couldn't open balance board device: $_\n";
    };
    
    # Seed the battery information.
    update_battery( $iface );

    # Remember where the cursor was when we started.
    savepos();

    # Start the poller.
    poller( $iface );
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

    loadpos();

    print "\e[?25l";

    my $p = BOLD BLUE . '|' . RESET;

    my $weight = $weights{ average }
               . ( $convert_to_pounds ? ' lbs' : ' kg' );

    # the pipes or pluses on each side removes 2 chars.
    my $space = $scale_width - 2;

    my $mid_line = '+'
                 . '-' x floor(( $space - 1 ) / 2 )
                 . '+'
                 . '-' x ceil( ( $space - 1 ) / 2 )
                 . "+";

    # top, mid, and bottom are subtracted.
    my $lines_around_mid = $scale_height - 3 / 2;

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

    # the average updates way less often.
    my $average_calls = 0;

    sub insert_x {
        my ( $matrix ) = @_;

        my $height = scalar( @{ $matrix      } );
        my $width  = scalar( @{ $matrix->[0] } );

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

        $total = $tl + $tr + $bl + $br;

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

        try {
            $battery = $iface->get_battery();
        }
        catch {
            die "Couldn't get battery status: $_\n";
        };

        alarm( 10 );

        # Back to the poller.
        poller( $iface );
    }

    sub get_battery {
        return $battery;
    }
}
