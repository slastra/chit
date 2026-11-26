# chit

Self-hosted notes and shared checklists for the desktop, phone, and watch.

chit is a Keep-style notes app for a household. A single Go server holds the accounts and
the sync log. Every device keeps its own copy and works offline, then catches up over a
server-sent event stream. The desktop side is a small daemon built for
[lastshell](https://github.com/slastra/lastshell), and the Android and Wear OS apps live in
a separate repo.

**Status:** early. The server and the `chit` CLI work end to end: notes, lists, sharing,
attachments, a live change feed, and `chitd`, the desktop daemon. The apps are next.

## Features

- Text notes and checklists, with colors, pins, labels, archive and trash
- Attachments up to 25 MB, with image thumbnails, visible only to people on the note
- Sharing per note with other accounts on the server, as editor or viewer
- Offline-first: every device keeps a replica and merges by field
- Reminders scheduled on each device, with no push service in the middle
- Invite-only accounts, managed from PocketBase's admin UI

## Install

### Requirements

- Go 1.27 or newer

```sh
go install github.com/slastra/chit/cmd/chit-server@latest   # the server
go install github.com/slastra/chit/cmd/chit@latest          # the CLI
```

## Usage

### Server

```sh
chit-server serve --http=127.0.0.1:8090 --dir=./pb_data
chit-server version
```

On first start, PocketBase prints a link for creating the first superuser. Accounts are
invite-only: add them from the admin UI at `/_/`.

### CLI

```sh
chit login https://chit.example.com      # asks for email and password
chit new Groceries --list milk eggs      # a checklist
chit new "Wifi" "the code is on the router"
chit add groceries coffee
chit check groceries milk                # --undo to uncheck
chit show groceries
chit ls                                  # --archived, --trashed
chit pin groceries
chit people
chit share groceries angelica            # --viewer for read-only
chit attach groceries receipt.jpg        # files up to 25 MB
chit get groceries receipt               # download (-o PATH, --thumb 320x320)
chit detach groceries receipt
chit remind groceries 17:30              # 10m, 2h, "tomorrow 9:00"; --clear
chit status                              # session, and whether chitd is up
chit watch                               # live changes, Ctrl-C to stop
```

Notes, items and people are found by name: an exact match first, then a prefix, then a
substring. When several match, chit lists them with their ids. Every command takes
`--json`. Piped input works too: `printf 'socks\nshirts\n' | chit add packing`.

### chitd

`chitd` keeps a local replica, works offline, and serves lastshell and the CLI over a unix
socket; the CLI uses it automatically when it is running. It also shows reminder toasts
and toasts for other people's edits on shared notes. Setup, the socket protocol and the
capture grammar are in [docs/chitd.md](docs/chitd.md).

## Configuration

`chit login` saves the server, a session token and a device id to
`~/.config/chit/config.json` (mode 600). `CHIT_SERVER` overrides the saved server. The
token refreshes itself when it is within three days of expiring. `"activity_toasts": false`
turns off chitd's toasts for other people's edits.

## How it works

The server embeds [PocketBase](https://pocketbase.io) for accounts, the admin UI, files
and backups. Notes, checklist items and sharing are PocketBase collections, but clients
never write them directly. Each change is an op stamped with a hybrid logical clock. The
server applies it if it wins, numbers it, and streams it to every device that can see the
note. The full contract is in [docs/design.md](docs/design.md).

## Development

```sh
go test ./...
go run ./cmd/chit-server serve
```

## Deploying

The `Dockerfile` builds a static binary and stores data in the `/pb_data` volume. Mount a
persistent volume there and expose port 8090 behind your proxy.

## License

MIT © 2026 Shaun Lastra. See [LICENSE](LICENSE).
