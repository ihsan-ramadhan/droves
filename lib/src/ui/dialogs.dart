import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// every irreversible action asks the same way, so a new screen never invents
/// its own wording or forgets the cancel path
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String body,
  String cancelLabel = 'Cancel',
  String confirmLabel = 'Continue',
  bool destructive = false,
}) async {
  final c = context.colors;
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title, style: nameStyle(dialog, size: 17)),
      content: Text(body, style: monoStyle(dialog, size: 12, color: c.muted)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(
            cancelLabel,
            style: monoStyle(dialog, size: 12, color: c.muted),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(
            confirmLabel,
            style: monoStyle(
              dialog,
              size: 12,
              color: destructive ? c.error : c.ink,
            ),
          ),
        ),
      ],
    ),
  );
  return yes == true;
}

/// one text prompt for names, labels and commit messages. Returns the trimmed
/// text, or null when the dialog was dismissed.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
  String initial = '',
  int maxLines = 1,
  ValueChanged<String>? onChanged,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PromptDialog(
    title: title,
    hint: hint,
    confirmLabel: confirmLabel,
    initial: initial,
    maxLines: maxLines,
    onChanged: onChanged,
  ),
);

/// owns the controller so it outlives the exit animation of the route
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.initial,
    required this.maxLines,
    this.onChanged,
  });

  final String title;
  final String hint;
  final String confirmLabel;
  final String initial;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      title: Text(widget.title, style: nameStyle(context, size: 17)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: widget.maxLines,
        style: monoStyle(context, size: 13),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: monoStyle(context, size: 12, color: c.muted),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.row),
            borderSide: BorderSide(color: c.rule),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.row),
            borderSide: BorderSide(color: c.ink),
          ),
        ),
        onChanged: widget.onChanged,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: monoStyle(context, size: 12, color: c.muted),
          ),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            widget.confirmLabel,
            style: monoStyle(context, size: 12, color: c.ink),
          ),
        ),
      ],
    );
  }
}
