import 'package:material_ui/material_ui.dart';

/// owns the busy flag and the error slot for one screen read, so a failure
/// reads the same on every tab and no screen forgets the mounted check
mixin ScreenLoader<T extends StatefulWidget> on State<T> {
  bool loading = false;
  String? error;

  Future<void> load(Future<void> Function() read, {bool silent = false}) async {
    if (!silent && mounted) setState(() => loading = true);
    try {
      await read();
      if (!mounted) return;
      setState(() {
        loading = false;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  /// a read that cannot start yet still has to drop the busy flag
  void idle() {
    if (mounted && loading) setState(() => loading = false);
  }
}
