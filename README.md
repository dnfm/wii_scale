# wii_scale

Perl script to use the Wii Balance Board as a bathroom scale with xWiimote.

The program will show a little ANSI graphic of your scale, which will show the weight currently on it, the battery level, as well as the current distribution of your weight on the scale.

Here's an example of the program's output:
```
+------------------------------------------------+
|        Wii Balance Board (Battery 70%)         |
|------------------------------------------------|
|                    38.6 lbs                    |
+-----------------------+------------------------+
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |   X                    |
|                       |                        |
+-----------------------+------------------------+
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
|                       |                        |
+-----------------------+------------------------+ 
```

## Prerequisites

The following perl modules are required to make this work:

- Try::Tiny
- Term::ANSIScreen

You will also need the xwiimote perl bindings which is provided by xwiimote-bindings.

That is [here](https://github.com/dvdhrm/xwiimote-bindings).

Also required (but you should already have them because they're in core) are:

- POSIX
- IO::Poll
- List::Util
- Pod::Usage
- Getopt::Long

Only non-perl prerequisite is xWiimote which can be obtained [here](https://github.com/dvdhrm/xwiimote).

## Before Running

There are a few variables at the top of the script you can edit to change the behaviour of the program a bit.  You can also specify them on the command-line instead.  Run with --help to see how to do that.

`fudge_factor` just modifies the weight up or down in case your Balance Board isn't exactly right.  I used some weights from a local sporting good store to find mine reads too low by a bit.  You can use positive or negative numbers.

`convert_to_pounds` is an obvious one.  The xWiimote libraries report kg by default.  This converts to lbs.

`scale_width` the width in characters of your terminal the little graphic showing your scale will be.

`scale_height` the height in characters of your terminal the little graphic showing your scale will be.

`exit_on_width` will make the program quit and print the final weight once it's decided the weight has stopped adjusting and moving around too much.

`disconnect_on_exit` (linux only) -- the way it does it is rudimentary, but will shell out to bluetoothctl and issue a disconnect command when exiting to save battery (the wii balance board will just stay on forever if you let it until the batteries die.)

## Usage

Make sure your balance board is paired with your system, and then simply run:

`perl scale.pl`

The program will instruct you what to do from there.

## License

Released under the same terms as perl itself.
