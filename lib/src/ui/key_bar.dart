import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../model/keybar.dart';
import '../theme/tokens.dart';

/// key row sending bytes to the focused terminal, above the keyboard inset
class KeyBar extends StatelessWidget {
  const KeyBar({
    super.key,
    required this.ids,
    required this.onKey,
    this.active = const {},
    required this.onConfigure,
  });

  final List<String> ids;
  final Set<String> active;
  final ValueChanged<TerminalKey> onKey;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final keys = ids.map(keyById).whereType<TerminalKey>().toList();
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.rule)),
      ),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.sm,
                  vertical: 5,
                ),
                itemCount: keys.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final key = keys[i];
                  return _BarButton(
                    label: key.label,
                    tooltip: key.sticky
                        ? 'Toggle ${key.label} on or off'
                        : 'Send ${key.label}',
                    active: active.contains(key.id),
                    onTap: () => onKey(key),
                  );
                },
              ),
            ),
            // config stays pinned outside the scrolling row
            _BarButton(
              icon: Icons.tune,
              tooltip: 'Choose shortcuts',
              onTap: onConfigure,
            ),
            const SizedBox(width: Space.xs),
          ],
        ),
      ),
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({
    this.label,
    this.icon,
    required this.onTap,
    this.tooltip,
    this.active = false,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool active;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  // a tap lasts a few frames; hold the highlight long enough to be seen
  bool _pressed = false;
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  void _hold(bool pressed) {
    _release?.cancel();
    if (pressed) {
      if (!_pressed) setState(() => _pressed = true);
      return;
    }
    _release = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final filled = widget.active || _pressed;
    final child = InkWell(
      onTap: widget.onTap,
      onTapDown: (_) => _hold(true),
      onTapUp: (_) => _hold(false),
      onTapCancel: () => _hold(false),
      borderRadius: BorderRadius.circular(Radii.row),
      child: Container(
        constraints: const BoxConstraints(minWidth: 44),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? c.ink : c.paper,
          border: Border.all(color: filled ? c.ink : c.rule),
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: widget.icon != null
            ? Icon(widget.icon, size: 16, color: filled ? c.paper : c.muted)
            : Text(
                widget.label!,
                style: monoStyle(
                  context,
                  size: 12,
                  color: filled ? c.paper : c.ink,
                ),
              ),
      ),
    );
    return widget.tooltip == null
        ? child
        : Tooltip(message: widget.tooltip!, child: child);
  }
}

/// grouped multi-select key picker, saved on close
class KeyBarPickerSheet extends StatefulWidget {
  const KeyBarPickerSheet({super.key, required this.selected});

  final List<String> selected;

  @override
  State<KeyBarPickerSheet> createState() => _KeyBarPickerSheetState();
}

class _KeyBarPickerSheetState extends State<KeyBarPickerSheet> {
  late List<String> _selected = [...widget.selected];

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final groups = <String, List<TerminalKey>>{};
    for (final key in terminalKeyCatalog) {
      (groups[key.group] ??= []).add(key);
    }
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                Space.md,
                Space.md,
                Space.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Shortcut bar',
                      style: nameStyle(context, size: 18),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selected = []),
                    child: Text(
                      'Clear',
                      style: monoStyle(context, size: 12, color: c.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(_selected),
                    child: Text(
                      'Save',
                      style: monoStyle(context, size: 12, color: c.ink),
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: c.rule, height: 1),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.all(Space.md),
                children: [
                  for (final entry in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        bottom: Space.sm,
                        top: Space.sm,
                      ),
                      child: LedgerLabel(entry.key),
                    ),
                    Wrap(
                      spacing: Space.sm,
                      runSpacing: Space.sm,
                      children: [
                        for (final key in entry.value)
                          SizedBox(
                            height: 44,
                            child: FilterChip(
                              selected: _selected.contains(key.id),
                              onSelected: (_) => _toggle(key.id),
                              showCheckmark: false,
                              label: Text(
                                key.label,
                                style: monoStyle(
                                  context,
                                  size: 12,
                                  color: _selected.contains(key.id)
                                      ? c.paper
                                      : c.ink,
                                ),
                              ),
                              backgroundColor: Colors.transparent,
                              selectedColor: c.ink,
                              side: BorderSide(
                                color: _selected.contains(key.id)
                                    ? c.ink
                                    : c.rule,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(Radii.row),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: Space.lg),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
