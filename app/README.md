# chit app

The Flutter app for [chit](../README.md): Linux, Android and the web. It keeps its own
SQLite replica (drift) and syncs with chit-server the way `chitd` does; the contract is
[docs/design.md](../docs/design.md).

```sh
flutter run -d linux
flutter test
tool/install-linux.sh      # build and install for this user, with a launcher entry
tool/web-assets.sh         # refresh web/sqlite3.wasm and web/drift_worker.js
tool/brand.py              # regenerate the platform icons from assets/brand
```

The code is in `lib/`: `core/` (pure: protocol, clocks, order keys, reminders), `data/`
(the replica, the sync engine, the API), `state/` (Riverpod providers), and `ui/`.
`third_party/media_kit` is a patched copy; see its CHIT.md.
