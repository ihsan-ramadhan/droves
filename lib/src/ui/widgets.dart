import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../bridge/bridge.dart';
import '../model/app_state.dart';
import '../theme/tokens.dart';

/// InheritedWidget reads are illegal in initState; resolve the bridge in didChangeDependencies
mixin BridgeAccess<T extends StatefulWidget> on State<T> {
  AppState? _app;
  Bridge? _readyFor;

  AppState get app => _app!;
  Bridge get bridge => app.bridge!;

  /// fires once per bridge reaching [BridgeState.ready] while mounted, incl. pre-connect screens
  void onBridgeReady();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AppScope.of(context);
    if (!identical(next, _app)) {
      _app?.removeListener(_maybeReady);
      _app = next;
      next.addListener(_maybeReady);
    }
    _maybeReady();
  }

  @override
  void dispose() {
    _app?.removeListener(_maybeReady);
    super.dispose();
  }

  void _maybeReady() {
    final live = _app?.bridge;
    if (live == null || live.state != BridgeState.ready) return;
    if (identical(live, _readyFor)) return;
    _readyFor = live;
    // didChangeDependencies runs in the build phase; loaders' setState would throw there
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onBridgeReady();
      });
    } else {
      onBridgeReady();
    }
  }
}

/// one mark per pane, filled when waiting on the user; the identity motif from DESIGN.md
class TallyRail extends StatelessWidget {
  const TallyRail({super.key, required this.workspaces, this.max = 5});

  final List<WorkspaceInfo> workspaces;
  final int max;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final shown = workspaces.take(max).toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final w in shown)
          Container(
            width: 6,
            height: 22,
            margin: const EdgeInsets.only(right: 3),
            decoration: BoxDecoration(
              color: _markColor(c, w.agentStatus),
              borderRadius: BorderRadius.circular(Radii.xs),
            ),
          ),
      ],
    );
  }

  Color _markColor(DrovesColors c, String status) {
    switch (status) {
      case 'blocked':
        return c.accent;
      case 'working':
        return c.ink.withValues(alpha: 0.55);
      case 'done':
        return c.muted.withValues(alpha: 0.45);
      default:
        return c.rule;
    }
  }
}

/// status reads as a word, never a spinner; only the word itself crossfades
class StatusWord extends StatelessWidget {
  const StatusWord(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final waiting = status == 'blocked';
    return AnimatedSwitcher(
      duration: Motion.duration(context, Motion.medium),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: LedgerLabel(
        key: ValueKey(status),
        status == 'unknown' ? 'idle' : status,
        color: waiting ? c.accent : null,
      ),
    );
  }
}

class DrovesScaffold extends StatelessWidget {
  const DrovesScaffold({
    super.key,
    required this.title,
    required this.child,
    this.bottomBar,
    this.actions,
    this.leading,
    this.subtitle,
  });

  final String title;
  final Widget child;
  final Widget? bottomBar;
  final List<Widget>? actions;
  final Widget? leading;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.paper,
      appBar: AppBar(
        leading: leading,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: c.ink,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            ?subtitle,
          ],
        ),
        actions: actions,
      ),
      body: child,
      bottomNavigationBar: bottomBar,
    );
  }
}

/// names the cause and the next action (R-27)
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
  return switch (live.state) {
    BridgeState.ready => '',
    BridgeState.connecting => 'connecting to bridge',
    BridgeState.failed =>
      'connection failed · ${error ?? live.lastError ?? ''}',
    BridgeState.idle => 'bridge disconnected · waiting to reconnect',
  };
}

/// disconnected bodies offer a real redial, not a load that returns early
VoidCallback connectionRetry(BuildContext context, VoidCallback fallback) {
  final app = AppScope.maybeOf(context);
  if (app == null) return fallback;
  return () => app.reconnect().catchError((_) {}).whenComplete(fallback);
}

/// one place decides what a screen says when it has no usable data:
/// a disconnected bridge outranks a stale error, and a load outranks empty.
/// The label is literal so every tab reads the same when the bridge drops.
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
    // a screen that starts out loading must not promise progress while the
    // socket is down; only a dial in flight counts as work
    final connecting =
        AppScope.maybeOf(context)?.state == BridgeState.connecting;
    Widget state = const SizedBox.shrink();
    if (loading && (connected || connecting)) {
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
      state = StateMessage(
        headline: 'Bridge is not connected',
        body:
            'This screen will update once Droves reconnects. Check the '
            'bridge address or open the Connect screen to switch machines.',
        icon: Icons.cable_outlined,
        action: OutlinedButton(
          onPressed: onRetry,
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    }
    else if (error != null) {
      state = StateMessage(
        headline: 'Could not read $subject',
        body: error!,
        icon: Icons.error_outline,
        action: OutlinedButton(
          onPressed: onRetry,
          child: Text('Try again', style: monoStyle(context, size: 12)),
        ),
      );
    }
    else if (empty) {
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

/// spins only while the owning screen reports a fetch in flight
class RefreshButton extends StatefulWidget {
  const RefreshButton({
    super.key,
    required this.busy,
    required this.onPressed,
    this.tooltip = 'Refresh',
  });

  final bool busy;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  State<RefreshButton> createState() => _RefreshButtonState();
}

class _RefreshButtonState extends State<RefreshButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.busy) _spin.repeat();
  }

  @override
  void didUpdateWidget(RefreshButton old) {
    super.didUpdateWidget(old);
    if (widget.busy == old.busy) return;
    if (widget.busy) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return IconButton(
      tooltip: widget.tooltip,
      // busy refresh holds no second request; the screen owns that guard
      onPressed: widget.busy ? null : widget.onPressed,
      icon: RotationTransition(
        turns: _spin,
        child: Icon(
          Icons.refresh,
          size: 20,
          color: widget.busy ? c.muted : c.ink,
        ),
      ),
    );
  }
}

/// list-shaped placeholder for first paint; not animated, MOTION 1
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.rows = 5, this.rowHeight = 64});

  final int rows;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget bar(double widthFactor, {double height = 10}) =>
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: c.rule.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );

    // Column, not ListView: inside an already-scrolling screen a nested scrollable renders nothing
    return Align(
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // without stretch the ~50%-wide bars shrink-wrap and centre as a floating block
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows; i++) ...[
            if (i > 0) Divider(color: c.rule, height: 1),
            SizedBox(
              height: rowHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    bar(i.isEven ? 0.42 : 0.55, height: 12),
                    const SizedBox(height: 8),
                    bar(i.isEven ? 0.22 : 0.3),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// the agent receives the remote path; the chip shows only the picked name
class StagedChip extends StatelessWidget {
  const StagedChip({super.key, required this.name, required this.onRemove});

  final String name;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(Space.sm, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.rule),
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 13, color: c.muted),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(context, size: 11),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Remove $name',
            iconSize: 18,
            padding: const EdgeInsets.all(3),
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            color: c.muted,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
