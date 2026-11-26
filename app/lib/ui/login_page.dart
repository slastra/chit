import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "Can't reach that server.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    InputDecoration field(String label, IconData icon) =>
        InputDecoration(labelText: label, prefixIcon: Icon(icon), border: const OutlineInputBorder());
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.sticky_note_2_outlined, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text('chit', textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
                const SizedBox(height: 32),
                TextField(
                  controller: _server,
                  decoration: field('Server', Icons.dns_outlined),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _email,
                  decoration: field('Email', Icons.alternate_email),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
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
                  Text(e, style: TextStyle(color: theme.colorScheme.error)),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
