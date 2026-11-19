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
              borderRadius: BorderRadius.circular(1),
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

/// static by design: MOTION 1 means no spinner
class StatusWord extends StatelessWidget {
  const StatusWord(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final waiting = status == 'blocked';
    return LedgerLabel(
      status == 'unknown' ? 'idle' : status,
      color: waiting ? c.accent : null,
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
        backgroundColor: c.paper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 52,
        centerTitle: false,
        leading: leading,
        titleSpacing: leading == null ? Space.md : 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(title, style: nameStyle(context, size: 19)),
            ?subtitle,
          ],
        ),
        actions: actions,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: c.rule),
        ),
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
