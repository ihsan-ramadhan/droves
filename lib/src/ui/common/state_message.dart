import 'package:material_ui/material_ui.dart';

import '../../bridge/bridge.dart';
import '../../bridge/failure.dart';
import '../../model/app_state.dart';
import '../../theme/tokens.dart';
import '../connect_screen.dart';
import 'scaffold.dart';

/// names the cause and the next action
class StateMessage extends StatelessWidget {
  const StateMessage({
    super.key,
    required this.headline,
    required this.body,
    this.action,
    this.icon,
  });

  final String headline;
  final String body;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.xl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 22, color: c.muted),
            const SizedBox(height: Space.md),
          ],
          Text(headline, style: nameStyle(context, size: 20)),
          const SizedBox(height: Space.sm),
          Text(body, style: monoStyle(context, size: 12, color: c.muted)),
          if (action != null) const SizedBox(height: Space.lg),
          ?action,
        ],
      ),
    );
  }
}

/// a tab's subtitle says why it is quiet before the body has to
String connectionSubtitle(BuildContext context, String? error) {
  final live = AppScope.of(context).bridge;
  if (live == null) return 'no bridge connected';
  final reason = error?.isNotEmpty == true ? error : live.lastError;
  return switch (live.state) {
    BridgeState.ready => '',
    BridgeState.connecting => 'connecting to bridge',
    BridgeState.failed =>
      'connection failed · '
          '${failureTag(reason, base: _base(context))}',
    BridgeState.idle => 'bridge disconnected · waiting to reconnect',
  };
}

Uri? _base(BuildContext context) =>
    Uri.tryParse(AppScope.maybeOf(context)?.baseUrl ?? '');

/// the bridge is the one thing every tab needs, so every tab says the same
/// words and offers the same two ways out while it is down
class BridgeDownState extends StatelessWidget {
  const BridgeDownState({super.key, this.error, this.onRetry});

  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.maybeOf(context);
    final saved = app?.baseUrl.isNotEmpty == true;
    final dialing = app?.state == BridgeState.connecting;
    final reason = error?.isNotEmpty == true ? error : app?.error;
    void openConnect() =>
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ConnectScreen()));

    return StateMessage(
      headline: 'Bridge is not connected',
      body: saved
          ? friendlyFailure(reason, base: Uri.tryParse(app?.baseUrl ?? ''))
          : 'Add the machine that runs your agents to get started.',
      icon: Icons.cable_outlined,
      action: saved
          ? Wrap(
              spacing: Space.md,
              runSpacing: Space.sm,
              children: [
                FilledButton(
                  onPressed: dialing
                      ? null
                      : connectionRetry(context, onRetry ?? () {}),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dialing) ...[
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        ),
                        const SizedBox(width: Space.xs),
                      ],
                      Text(
                        'Try again',
                        style: monoStyle(
                          context,
                          size: 12,
                          weight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: openConnect,
                  child: Text(
                    'Change bridge',
                    style: monoStyle(context, size: 12),
                  ),
                ),
              ],
            )
          : FilledButton(
              onPressed: openConnect,
              child: Text(
                'Add bridge',
                style: monoStyle(
                  context,
                  size: 12,
                  weight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
    );
  }
}

void showError(BuildContext context, Object error) {
  final app = AppScope.maybeOf(context);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        friendlyErrorText(error, base: Uri.tryParse(app?.baseUrl ?? '')),
        style: monoStyle(context, size: 12),
      ),
    ),
  );
}

void showToast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
  );
}

VoidCallback connectionRetry(BuildContext context, VoidCallback fallback) {
  final app = AppScope.maybeOf(context);
  if (app == null) return fallback;
  return () => app.reconnect().catchError((_) {}).whenComplete(fallback);
}

class ScreenState extends StatelessWidget {
  const ScreenState({
    super.key,
    required this.loading,
    required this.error,
    required this.connected,
    required this.empty,
    required this.subject,
    required this.emptyHeadline,
    required this.emptyBody,
    required this.onRetry,
    this.loadingBody = 'Reading from the bridge',
    this.rows = 5,
    this.rowHeight = 64,
    this.emptyIcon,
    this.emptyAction,
  });

  final bool loading;
  final String? error;
  final bool connected;
  final bool empty;
  final String subject;
  final String emptyHeadline;
  final String emptyBody;
  final VoidCallback onRetry;
  final String loadingBody;
  final int rows;
  final double rowHeight;
  final IconData? emptyIcon;
  final Widget? emptyAction;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    Widget state = const SizedBox.shrink();
    // while a dial is in flight the down state stays put, otherwise a retry
    // flashes the message into a skeleton and back
    if (loading && connected) {
      state = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              Space.xs,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: context.colors.muted,
                  ),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    '$loadingBody $subject',
                    style: monoStyle(
                      context,
                      size: 11,
                      color: context.colors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SkeletonRows(rows: rows, rowHeight: rowHeight),
        ],
      );
    }
    if (!connected) {
      state = BridgeDownState(error: error, onRetry: onRetry);
    } else if (error != null) {
      state = StateMessage(
        headline: 'Could not read $subject',
        body: friendlyFailure(error, base: _base(context)),
        icon: Icons.error_outline,
        action: OutlinedButton(
          onPressed: onRetry,
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    } else if (empty) {
      state = StateMessage(
        headline: emptyHeadline,
        body: emptyBody,
        icon: emptyIcon,
        action: emptyAction,
      );
    }
    return AnimatedSwitcher(
      duration: Motion.duration(context, Motion.medium),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        if (reduced) return child;
        return FadeTransition(opacity: animation, child: child);
      },
      child: KeyedSubtree(key: ValueKey(state.runtimeType), child: state),
    );
  }
}
