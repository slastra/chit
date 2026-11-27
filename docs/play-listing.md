# Play listing

The text for chit's Google Play store listing. Edit it here, then paste it into Play
Console (Grow > Store presence > Main store listing).

## App name (30)

chit: notes and lists

## Short description (80)

Notes and shared checklists for your household, synced through your own server.

## Full description (4000)

chit is a notes app for a household. Write notes, keep checklists, set reminders, and
share any of them with the people you live with, who see each change as it happens.

Notes and lists
- Text notes and checklists, with colors, labels and pins
- Drag to arrange your board, and to reorder and indent checklist items
- Check items off right on the card; uncheck them all to use a list again
- Search every word across your notes, lists, labels and archive

Shared with your household
- Share any note with someone, to edit or just to read
- Edits arrive live, and two people typing in the same note at once both keep their words
- See who else has a note open, and when they are typing

Reminders
- A reminder on any note, at a time you choose, with Done and Snooze right in the notification
- Reminders are kept on the phone itself, so they come even when it is offline

Pictures, voice and files
- Attach photos, videos, voice memos and documents up to 250 MB
- Play audio and video right from the card; record a voice memo in the app
- Share text, links and files to chit from any app

Works offline
- Every note is on your phone, so chit opens instantly and works without a connection
- Changes sync the moment you are back online

Private by design
- chit runs on your own server, not someone else's cloud: no ads, no tracking, no analytics
- Material You colors that follow your wallpaper

chit needs a chit server and an account on it. Accounts are by invitation from whoever
runs the server.

## Graphics

`docs/store/` holds the store graphics: six phone screenshots (`play-*.png`, 1080x1920),
the feature graphic (`feature-graphic.png`, 1024x500) and the README's images. To
redo them after the UI changes:

1. Start a throwaway `chit-server` on 127.0.0.1 with a superuser `admin@example.com` /
   `adminpass123`, and run `tool/store/seed.py http://127.0.0.1:PORT OUT` to stage a
   household's notes (every note type, a second person to share with).
2. Run the Linux build in a headless sway at 1080x2400, scale 2.625 (a Pixel-sized phone),
   signed in with `OUT/session.json`, and capture `raw-board`, `raw-list`, `raw-trip`,
   `raw-paint`, `raw-player` and `raw-dark` with grim; then `raw-wide` at 2560x1600,
   scale 2, with a note open in the pane. `OUT/angelica.json` posts presence for the
   shared-list shots.
3. `tool/store/compose.py RAW_DIR docs/store` frames them.
