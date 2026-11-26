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
  // Errors show as the failing field's supporting text, Material's place
  // for them: a refused sign-in under the password, an unreachable server
  // under the server field (which opens to show it).
  String? _error;
  String? _serverError;
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
      _serverError = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(_server.text.trim(), _email.text, _password.text);
      TextInput.finishAutofillContext(); // offer to save the password
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() {
        _changeServer = true;
        _serverError = "Can't reach this server";
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _changeServer = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Material's filled text field, as the spec draws it (container, top
    // corners, active indicator); errors in its supporting text
    InputDecoration field(String label, IconData icon, [String? error]) =>
        InputDecoration(labelText: label, prefixIcon: Icon(icon), filled: true, errorText: error);
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
                              decoration: field('Server', Icons.dns_outlined, _serverError),
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
                    decoration: field('Password', Icons.key_outlined, _error),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _signIn(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    // Expressive medium button: 56dp, title-medium label
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      textStyle: theme.textTheme.titleMedium,
                    ),
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 3, color: scheme.onPrimary),
                          )
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
