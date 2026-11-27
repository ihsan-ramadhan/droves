import 'package:material_ui/material_ui.dart';

import '../../bridge/bridge.dart';
import '../../theme/tokens.dart';

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
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: c.ink),
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
