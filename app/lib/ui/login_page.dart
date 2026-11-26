import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/api.dart';
import '../state/providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _server = TextEditingController(text: 'https://chit.lastra.us');
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(_server.text.trim(), _email.text, _password.text);
      TextInput.finishAutofillContext(); // offer to save the password
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "Can't reach that server.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _changeServer = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    InputDecoration field(String label, IconData icon) => InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      border: const OutlineInputBorder(
        borderSide: BorderSide.none,
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    );
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // the brand mark: an Expressive shape around the note glyph
                  Center(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: scheme.primaryContainer,
                        shape: MaterialShapeBorder(shape: MaterialShapes.sunny),
                      ),
                      child: SizedBox.square(
                        dimension: 96,
                        child: Icon(Icons.sticky_note_2_outlined, size: 44, color: scheme.onPrimaryContainer),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Sign in to chit', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    Uri.tryParse(_server.text)?.host ?? _server.text,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 32),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    child: _changeServer
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: TextField(
                              controller: _server,
                              decoration: field('Server', Icons.dns_outlined),
                              keyboardType: TextInputType.url,
                              onChanged: (_) => setState(() {}),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  TextField(
                    controller: _email,
                    decoration: field('Email', Icons.alternate_email),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email, AutofillHints.username],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    decoration: field('Password', Icons.key_outlined),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _signIn(),
                  ),
                  if (_error case final e?) ...[
                    const SizedBox(height: 12),
                    Row(
                      spacing: 8,
                      children: [
                        Icon(Icons.error_outline, size: 20, color: scheme.error),
                        Expanded(
                          child: Text(e, style: TextStyle(color: scheme.error)),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 8),
                  if (!_changeServer)
                    TextButton(
                      onPressed: () => setState(() => _changeServer = true),
                      child: const Text('Change server'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
