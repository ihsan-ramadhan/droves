# Client

The Flutter client keeps three layers apart so a screen only describes what it
shows.

## Layering

| Layer | Lives in | Holds |
|---|---|---|
| Wire | `lib/src/bridge/` | `bridge.dart` (socket, RPC, typed reads), `decode.dart` (payload casts), `failure.dart` (error wording) |
| Model | `lib/src/model/` | `app_state.dart` plus one file per payload type (`diff_entry.dart`, `commit_info.dart`, `file_entry.dart`, `connection_info.dart`, `scout_model.dart`, `agent_message.dart`, `search_hit.dart`) |
| View | `lib/src/ui/` | one file per screen, `common/` for shared widgets, `dialogs.dart`, `screen_loader.dart` |

A screen must not declare payload classes, parse raw maps, or spell out socket
errors. If a screen needs a cast, it calls `maps`, `str`, or `integer` from
`decode.dart`.

## Screen contract

Every screen that reads data follows the same shape:

```dart
class _FooScreenState extends State<FooScreen> with BridgeAccess, ScreenLoader {
  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    await load(() async {
      final r = await bridge.call('foo.list');
      if (!mounted) return;
      setState(() => _items = maps(r['items']).map(Foo.fromJson).toList());
    });
  }
}
```

- `ScreenLoader` owns `loading` and `error`, so no screen repeats the
  try/catch, the mounted check, or the error reset.
- The body is one `ScreenState(...)` call. It decides between skeleton, bridge
  down, read failure, and empty. A screen never renders those by hand.
- `loading` is passed as `loading && <content>.isEmpty`, so a pull-to-refresh
  keeps the current rows on screen instead of blanking them.
- Every screen with a header offers `RefreshButton`; pull-to-refresh is added
  where a vertical list already scrolls.
- Errors reach the user only through `friendlyFailure` / `friendlyErrorText`
  (via `ScreenState` or `showError`). Raw exceptions stay in the log.
- Confirmation and text entry go through `confirmDialog` and `promptText` in
  `ui/dialogs.dart`, never a hand-built `AlertDialog`.

## Shared widgets

`ui/common/bridge_access.dart` resolves the bridge outside `initState`.
`ui/common/scaffold.dart` holds `DrovesScaffold`, `RefreshButton`, `TallyRail`,
`StatusWord`, and `StagedChip`. `ui/common/state_message.dart` holds
`StateMessage`, `ScreenState`, `BridgeDownState`, `connectionSubtitle`,
`connectionRetry`, `showError`, and `SkeletonRows`. `ui/common/status_group.dart`
holds the Working, Done, Idle bands plus `statusSections` and
`StatusSectionHeader`; Inbox and Agents both use them.

## Tests

`flutter analyze` and `flutter test` are the gate. Screen behaviour that has
bitten before is covered by a widget test: `screen_state_test.dart` for the
state ladder, `inbox_offline_test.dart` and `offline_actions_test.dart` for the
single offline layout, `failure_test.dart` for error wording,
`bridge_uri_test.dart` for URL joins, `app_state_origin_test.dart` for the web
origin guard, and `list_grouping_test.dart` for the status bands.
