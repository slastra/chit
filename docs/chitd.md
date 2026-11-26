# chitd

chitd is the desktop client: a local replica of everything you can see, kept in step with
the server, that works offline and serves lastshell and the `chit` CLI over a unix socket.
It also shows reminder toasts and toasts for other people's edits on shared notes.

## Running it

```sh
chit login https://chit.example.com
go build -o ~/.local/bin/chitd ./cmd/chitd
ln -s $PWD/systemd/chitd.service ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now chitd
chit status
```

| Path | What |
|---|---|
| `$CHIT_SOCKET`, else `$XDG_RUNTIME_DIR/chit.sock` | the socket (mode 600) |
| `$XDG_DATA_HOME/chit/replica.db` | the replica and the outbox |
| `~/.config/chit/config.json` | the session, shared with the CLI |

`CHITD_NO_TOASTS=1` turns every toast off (tests). `"activity_toasts": false` in the config
turns off toasts for other people's edits; reminders still show.

## Sync

- First start: the server snapshot fills the replica. After that chitd follows the SSE
  stream from its saved cursor and merges each change field by field, newer write wins,
  the same rule as the server.
- Local edits apply to the replica at once and go into the outbox, which survives
  restarts. The outbox drains in order whenever the server answers. An op the server
  rejects is dropped and the replica reloads from a snapshot (pending ops are replayed on
  top).
- chitd has its own device id, separate from the CLI's. CLI commands sent straight to the
  server (`CHIT_DIRECT=1`, or with chitd stopped) come back to chitd through the feed.
- Signing in as someone else, or to another server, starts a fresh replica.

## Socket protocol

One JSON object per line. Requests carry `op` and an optional `req`, echoed in the reply.
Types are in `internal/sock`.

| `op` | Fields | Reply |
|---|---|---|
| `status` | | `status` |
| `snapshot` | | `snapshot` (the server's snapshot shape) |
| `ops` | `ops` | `results` (applied locally and queued) |
| `people` | `fresh` | `people` (cached for an hour, served stale offline) |
| `preview` | `text` | `plan` (what `capture` would do) |
| `capture` | `text` | `plan` (and does it) |
| `check` | `item`, `on` | `results` |
| `pin` | `note`, `on` | `results` |
| `subscribe` | `changes` | `{"ok":true}`, then pushed events |
| `quiet` | `seconds` | holds activity toasts back (lastshell sends it while open) |

Replies: `{"req":"…","ok":true,…}` or `{"req":"…","ok":false,"error":"…"}`.

Pushed to subscribers:

- `{"event":"state", online, signed_in, pending, server, user, error, notes:[…]}` on
  subscribe and after every change (at most every 100 ms). Each note: `id, title, kind,
  color, body (first 600 characters), pinned, archived, shared, open, done, items:[{id,
  text, checked, indent}], attachments, reminder, updated`, pinned first, then most
  recently updated. Notes in the trash are left out.
- `{"event":"change","change":{…}}` for every change, local or remote, when the
  subscription asked for `changes`.

## Capture

`capture` turns one typed line into edits:

| Typed | Does |
|---|---|
| `groceries: milk, eggs` | adds items to the list titled Groceries |
| `wifi: guest code 1234` | appends a line to the text note titled Wifi |
| anything else | a new text note (first line is the title when there are several) |

The part before `:` must be a note's exact title, or a prefix (two characters or more) of
exactly one title. So "re: taxes" or "meet at 3:30" stay new notes.

## Toasts

- **Reminders** (`chit remind groceries 17:30`): a sticky toast with Done and Snooze 10
  min. Done syncs `reminder_done`, which closes the toast on every desk. A reminder fires
  once; one missed by up to 12 hours (desk off) fires on start.
- **Activity**: other people's edits on shared notes, grouped per person and note over 20
  seconds into one toast. Your own edits, from any device, never toast.
