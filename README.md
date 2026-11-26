# chit

Self-hosted notes and shared checklists for the desktop, phone, and watch.

chit is a Keep-style notes app for a household. A single Go server holds the accounts and
the sync log. Every device keeps its own copy and works offline, then catches up over a
server-sent event stream. The desktop side is a small daemon built for
[lastshell](https://github.com/slastra/lastshell), and the Android and Wear OS apps live in
a separate repo.

**Status:** early. The server runs with accounts and the note schema. The sync routes,
`chitd`, and the apps are next.

## Features

- Text notes and checklists, with colors, pins, labels, archive and trash
- Sharing per note with other accounts on the server, as editor or viewer
- Offline-first: every device keeps a replica and merges by field
- Reminders scheduled on each device, with no push service in the middle
- Invite-only accounts, managed from PocketBase's admin UI

## Install

### Requirements

- Go 1.27 or newer

```sh
go install github.com/slastra/chit/cmd/chit-server@latest
```

## Usage

```sh
chit-server serve --http=127.0.0.1:8090 --dir=./pb_data
chit-server version
```

On first start, PocketBase prints a link for creating the first superuser. Accounts are
invite-only: add them from the admin UI at `/_/`.

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
