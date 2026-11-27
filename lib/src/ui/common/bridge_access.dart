import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../../bridge/bridge.dart';
import '../../model/app_state.dart';

mixin BridgeAccess<T extends StatefulWidget> on State<T> {
  AppState? _app;
  Bridge? _readyFor;

  AppState get app => _app!;
  Bridge get bridge => app.bridge!;

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
