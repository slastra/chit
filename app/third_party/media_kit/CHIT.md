# media_kit 1.2.6, patched for chit

A copy of [media_kit](https://pub.dev/packages/media_kit) 1.2.6 (MIT, see
LICENSE), used through `dependency_overrides` in chit's pubspec.yaml.

One change, in `lib/src/player/native/player/real.dart` (`_create`): libmpv
is initialized with every Lua script off (`load-scripts=no` and each built-in
script's `load-*` option, `osc`, `ytdl`). LuaJIT raises Lua errors through
the C++ unwinder; inside a Flutter app that symbol resolves to
libflutter_linux_gtk's own, and the process segfaults in
`_Unwind_RaiseException` (seen playing an audio file). media_kit has no hook
for options set before `mpv_initialize`, hence the copy.

A second change, in the same options: `ao=pulse,pipewire,alsa`. mpv 0.42's
PipeWire output, playing audio with no video, gets the process SIGKILLed a
few seconds in on PipeWire 1.6.11 (its realtime audio thread overruns the RT
time limit); the same happens with the mpv command line (`mpv --vid=no
file.mp3`), and `--ao=pulse` does not. Set after creation it came too late.

Drop it when media_kit takes such options or the crash is fixed upstream.
