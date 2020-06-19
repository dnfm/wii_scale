# wii_scale
Perl script to use the Wii Balance Board as a bathroom scale with xWiimote.

## Prerequisites

The following perl modules are required to make this work:

- Readonly
- Try::Tiny
- Term::ANSIScreen

You will also need the xwiimote perl bindings which is provided by xwiimote-bindings.

That is [here](https://github.com/dvdhrm/xwiimote-bindings).

Also required (but you should already have them because they're in core) are:

- POSIX
- IO::Poll
- List::Util

Only non-perl prerequisite is xWiimote which can be obtained [here](https://github.com/dvdhrm/xwiimote).

## Usage

Make sure your balance board is paired with your system, and then simply run:

`perl scale.pl`

The program will instruct you what to do from there.

## License

Released under the GNU GPL 3.0.  Do with it what you please.  I provide no warranty of any kind.
