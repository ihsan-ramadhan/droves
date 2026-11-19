import 'package:material_ui/material_ui.dart';

import '../model/app_state.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

/// first-run setup: only the bridge's tailnet address is required
/// token may stay empty over Tailscale private HTTPS; login cookie can be pasted later
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  bool _busy = false;
  bool _showToken = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController();
    _token = TextEditingController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_url.text.isEmpty) _url.text = AppScope.of(context).baseUrl;
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).connect(_url.text, _token.text);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useSaved(int index) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).useEndpoint(index);
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(int index) async {
    await AppScope.of(context).forgetEndpoint(index);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DrovesScaffold(
      title: 'Connect',
      subtitle: const LedgerLabel('private network only'),
      leading: Navigator.of(context).canPop()
          ? IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              color: c.ink,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            )
          : null,
      child: ListView(
        padding: const EdgeInsets.all(Space.lg),
        children: [
          Row(
            children: [
              Image.asset('assets/logo/droves-logo.png', width: 44, height: 44),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  'Connect a computer',
                  style: nameStyle(context, size: 22),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Droves reads your agents through a small bridge on the computer '
            'where they run. Nothing goes through a third party.',
            style: monoStyle(context, size: 12, color: c.muted),
          ),
          if (AppScope.of(context).endpoints.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            LedgerLabel('Saved bridges'),
            const SizedBox(height: Space.xs),
            for (var i = 0; i < AppScope.of(context).endpoints.length; i++)
              _SavedEndpoint(
                endpoint: AppScope.of(context).endpoints[i],
                onUse: () => _useSaved(i),
                onForget: () => _forget(i),
              ),
          ],
          const SizedBox(height: Space.xl),
          const _Step(
            number: 1,
            title: 'Start the bridge',
            body: 'Run droves-bridge on that computer and leave it running.',
          ),
          const _Step(
            number: 2,
            title: 'Copy its private address',
            body: 'In Tailscale, copy the MagicDNS name for that computer.',
          ),
          const _Step(
            number: 3,
            title: 'Copy the access token',
            body: 'Open ~/.config/droves-bridge/token on that computer.',
          ),
          const _Step(
            number: 4,
            title: 'Fill in both fields',
            body: 'Paste them below, then tap Connect.',
            last: true,
          ),
          const SizedBox(height: Space.lg),
          _Field(
            label: 'Bridge address',
            hint: 'https://your-machine.tailnet.ts.net:13030',
            controller: _url,
            keyboard: TextInputType.url,
          ),
          const SizedBox(height: Space.md),
          _Field(
            label: 'Access token',
            hint: 'paste the token',
            controller: _token,
            obscure: !_showToken,
            trailing: IconButton(
              icon: Icon(
                _showToken
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 18,
              ),
              color: c.muted,
              tooltip: _showToken ? 'Hide token' : 'Show token',
              onPressed: () => setState(() => _showToken = !_showToken),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            Container(
              padding: const EdgeInsets.all(Space.sm),
              decoration: BoxDecoration(
                border: Border.all(color: c.accent),
                borderRadius: BorderRadius.circular(Radii.row),
              ),
              child: Text(
                _error!,
                style: monoStyle(context, size: 11, color: c.accent),
              ),
            ),
          ],
          const SizedBox(height: Space.lg),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: c.ink,
                foregroundColor: c.paper,
                disabledBackgroundColor: c.muted,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.row),
                ),
              ),
              child: _busy
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: c.paper,
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        Text(
                          'Connecting',
                          style: monoStyle(context, size: 12, color: c.paper),
                        ),
                      ],
                    )
                  : Text(
                      'Connect',
                      style: monoStyle(
                        context,
                        size: 12,
                        weight: FontWeight.w600,
                        color: c.paper,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: Space.lg),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.rule),
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: 0,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(
                  Space.md,
                  0,
                  Space.md,
                  Space.md,
                ),
                iconColor: c.muted,
                collapsedIconColor: c.muted,
                title: Text(
                  'Need the exact commands?',
                  style: monoStyle(context, size: 11, color: c.ink),
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Run these on the computer that runs your agents:\n\n'
                      'droves-bridge\n'
                      'tailscale serve --bg 13030\n'
                      'cat ~/.config/droves-bridge/token',
                      style: monoStyle(context, size: 10.5, color: c.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.body,
    this.last = false,
  });

  final int number;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.rule),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: monoStyle(context, size: 10, color: c.ink),
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: monoStyle(
                    context,
                    size: 12,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(body, style: monoStyle(context, size: 11, color: c.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.hint,
    required this.controller,
    this.keyboard,
    this.obscure = false,
    this.trailing,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final TextInputType? keyboard;
  final bool obscure;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LedgerLabel(label),
        const SizedBox(height: Space.xs),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: monoStyle(context, size: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: monoStyle(
              context,
              size: 12,
              color: c.muted.withValues(alpha: 0.7),
            ),
            filled: true,
            fillColor: c.surface,
            suffixIcon: trailing,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: Space.md,
              vertical: 14,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.row),
              borderSide: BorderSide(color: c.rule),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Radii.row),
              borderSide: BorderSide(color: c.ink, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// tap dials; the trailing control forgets without touching a live connection
class _SavedEndpoint extends StatelessWidget {
  const _SavedEndpoint({
    required this.endpoint,
    required this.onUse,
    required this.onForget,
  });

  final Endpoint endpoint;
  final VoidCallback onUse;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.xs),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onUse,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      endpoint.displayLabel,
                      style: nameStyle(
                        context,
                        size: 14,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      endpoint.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(context, size: 10.5, color: c.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: c.muted,
            tooltip: 'Forget this bridge',
            onPressed: onForget,
          ),
        ],
      ),
    );
  }
}
