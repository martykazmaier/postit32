# PostIt32

Posts a text file to an [EleBBS](http://www.elebbs.com/) JAM message area, as local mail or echomail. It's a Win32 console program, handy for posting bulletins, rules and news from batch files or events.

## Download

Get `postit32.exe` from the [latest release](https://github.com/martykazmaier/postit32/releases/latest).

## Setup

Set the `RA` environment variable to your EleBBS system directory, the one containing `CONFIG.RA` and `MESSAGES.RA`:

```
SET RA=C:\ELE
```

Optionally set `TZ` to your UTC offset as `[+|-]hhmm` to add a `TZUTC` kludge to each message:

```
SET TZ=-700
```

## Usage

```
POSTIT32 /F:<file> /B:<board> /S:<subject> /FR:<from> [/TO:<to>]
         /L | /E [/A:<address>] [/O:<origin>] [/P]
```

| Option | Meaning |
|---|---|
| `/F:<file>` | Text file to post |
| `/B:<board>` | Area number from `MESSAGES.RA` |
| `/S:<subject>` | Message subject |
| `/FR:<from>` | Sender name |
| `/TO:<to>` | Receiver name (default `All`) |
| `/L` | Post as local mail |
| `/E` | Post as echomail |
| `/A:<address>` | Override the origin address, e.g. `1:234/56` |
| `/O:<origin>` | Override the origin line text |
| `/P` | Mark the message private |

Exactly one of `/L` or `/E` is required. Put quotes around values that contain spaces. Run `POSTIT32` with no arguments to see the help.

### Examples

```
POSTIT32 /F:RULES.TXT /B:1 /S:Rules /FR:Sysop /L
POSTIT32 /F:NEWS.TXT /B:12 "/S:Weekly News" "/FR:Marty Kazmaier" /E
```

The program exits with code 0 on success and 1 on any error, so batch files can check `ERRORLEVEL`.

## How it works

- **Area lookup:** the area is found by number in `%RA%\MESSAGES.RA`, which supplies the JAM base path, origin line and AKA. `%RA%\MESSAGES.ELE` is checked so that Squish areas are rejected.
- **Echomail address:** taken from the area's AKA. AKAs 0 to 9 come from `CONFIG.RA` and AKAs 10 and up from `AKAS.BBS`. Use `/A:` to override it.
- **Echomail extras:** a MSGID, a tear line and an origin line are added. The message is also listed in `ECHOMAIL.JAM` in the message base path from `CONFIG.RA`, so your tosser scans and exports it.
- **Time zone:** if `TZ` is set, a `TZUTC` kludge is added (for example `TZ=-700` gives `TZUTC: -0700`). Forms like `-0700`, `-7` and `-07:00` also work. An unreadable `TZ` gives a warning, and the message is posted without the kludge.
- **Writing:** the JAM base is locked while the message is written, so it's safe to run while the BBS is up. A missing JAM base is created.
- **Text:** CRLF and LF line endings are converted to CR, and a trailing Ctrl-Z is removed.

For echomail, names are cut to 35 characters, the subject to 71 and the origin line to 79, matching FidoNet limits.

## Limitations

- Only JAM areas are supported. Hudson and Squish areas are rejected.
- Netmail isn't supported.

## Building

Install [Free Pascal](https://www.freepascal.org/) 3.2 or later for i386-win32, then run:

```
fpc -O2 postit32.pas
```

## License

Copyright (C) 2026 Martin Kazmaier.

PostIt32 may be distributed under the terms of the [Q Public License version 1.0](LICENSE). Source code is available free of charge from this repository.
