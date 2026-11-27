/// Adding files to notes: where they come from (gallery, camera, voice
/// memo, file picker), the add button, and a new note made of files.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';

import '../core/protocol.dart';
import '../data/local_files.dart' as files;
import '../data/media.dart';
import '../state/providers.dart';
import 'note_routes.dart';
import 'create.dart' show newNoteDefaults;
import 'expressive.dart';
import 'feedback.dart';
import 'layout.dart';
import 'media_deck.dart';

bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Where new files come from.
enum AddSource {
  media('Photo or video', Icons.photo_library_outlined),
  photo('Take photo', Icons.photo_camera_outlined),
  video('Record video', Icons.videocam_outlined),
  memo('Voice memo', Icons.mic_none),
  file('File', Icons.attach_file);

  const AddSource(this.label, this.icon);
  final String label;
  final IconData icon;

  /// The camera is Android's (the system camera, through image_picker).
  bool get available => switch (this) {
    photo || video => _android,
    _ => true,
  };

  static List<AddSource> get offered => values.where((s) => s.available).toList();
}

Future<NewFile> _fromXFile(XFile f) async =>
    (name: f.name, size: await f.length(), path: kIsWeb ? null : f.path, bytes: kIsWeb ? await f.readAsBytes() : null);

Future<NewFile> _fromPicked(PlatformFile f) async => (
  name: f.name,
  size: await f.length() ?? 0,
  path: kIsWeb ? null : f.path,
  bytes: kIsWeb || f.path == null ? await f.readAsBytes() : null,
);

/// Asks for files from [source]; empty when the user backs out.
Future<List<NewFile>> pickFrom(BuildContext context, AddSource source) async {
  final images = ImagePicker();
  switch (source) {
    case AddSource.media:
      if (_android) return Future.wait((await images.pickMultipleMedia()).map(_fromXFile));
      return Future.wait((await FilePicker.pickFiles(type: FileType.media)).map(_fromPicked));
    case AddSource.photo:
      final f = await images.pickImage(source: ImageSource.camera);
      return f == null ? const [] : [await _fromXFile(f)];
    case AddSource.video:
      final f = await images.pickVideo(source: ImageSource.camera);
      return f == null ? const [] : [await _fromXFile(f)];
    case AddSource.memo:
      final memo = await _recordVoiceMemo(context);
      return memo == null ? const [] : [memo];
    case AddSource.file:
      return Future.wait((await FilePicker.pickFiles()).map(_fromPicked));
  }
}

/// The Add button for the note's toolbar: the ways to add a file, as a menu
/// on expanded windows and a bottom sheet on compact ones (like the palette).
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.onPick});
  final ValueChanged<AddSource> onPick;

  @override
  Widget build(BuildContext context) {
    const icon = Icon(Icons.add_box_outlined);
    if (isExpanded(context)) {
      return MenuAnchor(
        builder: (context, ctl, _) =>
            IconButton(tooltip: 'Add', icon: icon, onPressed: () => ctl.isOpen ? ctl.close() : ctl.open()),
        menuChildren: [
          for (final s in AddSource.offered)
            MenuItemButton(leadingIcon: Icon(s.icon), onPressed: () => onPick(s), child: Text(s.label)),
        ],
      );
    }
    return IconButton(
      tooltip: 'Add',
      icon: icon,
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedList(
                children: [
                  for (final s in AddSource.offered)
                    ListTile(
                      leading: Icon(s.icon),
                      title: Text(s.label),
                      onTap: () {
                        Navigator.pop(sheet);
                        onPick(s);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Queues [picked] on [note] and says which files were too large.
Future<void> attachTo(BuildContext context, String note, List<NewFile> picked) async {
  if (picked.isEmpty) return;
  final c = ProviderScope.containerOf(context);
  final tooBig = await attachFiles(c.read(replicaProvider), c.read(engineProvider), note, picked);
  if (tooBig.isNotEmpty) {
    showMessage(
      tooBig.length == 1
          ? '${tooBig.first} is over the ${maxAttachmentSize >> 20} MB limit'
          : '${tooBig.length} files are over the ${maxAttachmentSize >> 20} MB limit',
    );
  }
}

/// A new note holding [picked], opened.
Future<void> newNoteWithFiles(BuildContext context, List<NewFile> picked) async {
  if (picked.isEmpty) return;
  final engine = ProviderScope.containerOf(context).read(engineProvider);
  if (engine == null) return;
  final id = randomId();
  final label = newNoteDefaults.value.label;
  await engine.edit([
    engine.op(Collections.notes, id, 'kind', 'text'),
    if (label != null) engine.op(Collections.noteState, id, 'labels', [label]),
  ]);
  if (!context.mounted) return;
  await attachTo(context, id, picked);
  if (context.mounted) await openNote(context, '/note/$id');
}

/// Records a voice memo: a dialog on expanded windows, a bottom sheet on
/// compact ones. Null when cancelled or the microphone is refused.
Future<NewFile?> _recordVoiceMemo(BuildContext context) {
  // nothing outside closes it: a stray tap would lose the recording
  return showAdaptive<NewFile>(context, dismissible: false, maxHeight: 400, build: (_, _) => const _MemoRecorder());
}

class _MemoRecorder extends StatefulWidget {
  const _MemoRecorder();

  @override
  State<_MemoRecorder> createState() => _MemoRecorderState();
}

class _MemoRecorderState extends State<_MemoRecorder> {
  final _rec = AudioRecorder();
  final _started = DateTime.now();
  Timer? _tick;
  StreamSubscription<Amplitude>? _levels;
  double _level = 0;
  String _ext = 'm4a';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'chit needs the microphone to record.');
        return;
      }
      // AAC in m4a where the platform has it; Opus, then WAV, otherwise
      var encoder = AudioEncoder.aacLc;
      for (final (e, ext) in [(AudioEncoder.aacLc, 'm4a'), (AudioEncoder.opus, 'ogg'), (AudioEncoder.wav, 'wav')]) {
        if (await _rec.isEncoderSupported(e)) {
          encoder = e;
          _ext = ext;
          break;
        }
      }
      await _rec.start(RecordConfig(encoder: encoder, numChannels: 1), path: await files.recordingPath(_ext));
      _levels = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
        // dBFS to 0..1 over a 50 dB range
        if (mounted) setState(() => _level = ((a.current + 50) / 50).clamp(0.0, 1.0));
      });
      _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't start recording.");
    }
  }

  Future<void> _finish({required bool keep}) async {
    setState(() => _saving = keep);
    _tick?.cancel();
    await _levels?.cancel();
    final where = await _rec.stop();
    if (!mounted) return;
    if (!keep || where == null || where.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final now = DateTime.now();
    final name = '$voiceMemoName, ${DateFormatLite.stamp(now)}.$_ext';
    if (kIsWeb) {
      // the web recorder hands back a blob URL
      final bytes = (await http.get(Uri.parse(where))).bodyBytes;
      if (mounted) Navigator.pop(context, (name: name, size: bytes.length, path: null, bytes: bytes) as NewFile);
      return;
    }
    final size = await files.sizeOf(where);
    if (mounted) Navigator.pop(context, (name: name, size: size, path: where, bytes: null) as NewFile);
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_levels?.cancel());
    unawaited(_rec.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final elapsed = DateTime.now().difference(_started);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(_error == null ? Icons.mic : Icons.mic_off_outlined, color: scheme.secondary, size: 24),
            const SizedBox(height: 16),
            Text(
              _error == null ? 'Recording' : "Can't record",
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (_error case final e?)
              Text(
                e,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              )
            else ...[
              Text(
                formatDuration(elapsed),
                textAlign: TextAlign.center,
                style: theme.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 16),
              Semantics(
                label: 'Input level',
                child: LinearProgressIndicator(value: _level, minHeight: 8, borderRadius: BorderRadius.circular(4)),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => _finish(keep: false),
                  child: Text(_error == null ? 'Cancel' : 'Close'),
                ),
                // a dialog's actions are text buttons (Material's dialog spec)
                if (_error == null)
                  TextButton(onPressed: _saving ? null : () => _finish(keep: true), child: const Text('Save')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Nov 26 10.45", without pulling a locale into a file name (and with no
/// colon, which some file systems refuse).
abstract final class DateFormatLite {
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String stamp(DateTime d) =>
      '${_months[d.month - 1]} ${d.day} ${d.hour.toString().padLeft(2, '0')}.${d.minute.toString().padLeft(2, '0')}';
}
