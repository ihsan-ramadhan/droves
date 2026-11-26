import 'package:material_ui/material_ui.dart';

import '../bridge/bridge.dart';
import '../theme/tokens.dart';
import 'files_screen.dart';
import 'widgets.dart';

class SearchHit {
  SearchHit({required this.path, this.line, this.snippet});

  final String path;
  final int? line;
  final String? snippet;

  bool get isContent => line != null;
}

/// mirrors `file.search` with both modes; one query returns name and content hits
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.workspace, required this.label});

  final String workspace;
  final String label;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with BridgeAccess {
  final _query = TextEditingController();
  final _focus = FocusNode();
  List<SearchHit> _nameHits = const [];
  List<SearchHit> _contentHits = const [];
  bool _searching = false;
  bool _ran = false;
  String? _error;

  @override
  void onBridgeReady() {}

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _nameHits = const [];
        _contentHits = const [];
        _ran = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await Future.wait([
        bridge.call('file.search', {
          'workspace_id': widget.workspace,
          'mode': 'files',
          'query': q,
        }),
        bridge.call('file.search', {
          'workspace_id': widget.workspace,
          'mode': 'content',
          'query': q,
        }),
      ]);
      List<SearchHit> parse(Map<String, dynamic> r) =>
          ((r['results'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()
              .map(
                (j) => SearchHit(
                  path: (j['path'] as String?) ?? '',
                  line: (j['line'] as num?)?.toInt(),
                  snippet: j['snippet'] as String?,
                ),
              )
              .toList();
      if (!mounted) return;
      setState(() {
        _nameHits = parse(results[0]);
        _contentHits = parse(results[1]);
        _searching = false;
        _ran = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _ran = true;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Search',
      subtitle: LedgerLabel(status.isNotEmpty ? status : widget.label),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: TextField(
              controller: _query,
              focusNode: _focus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              style: monoStyle(context, size: 13),
              decoration: InputDecoration(
                hintText: 'Names or contents',
                hintStyle: monoStyle(
                  context,
                  size: 12,
                  color: c.muted.withValues(alpha: 0.75),
                ),
                filled: true,
                fillColor: c.surface,
                prefixIcon: Icon(Icons.search, size: 18, color: c.muted),
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
          ),
          Expanded(child: _buildResults(context)),
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final c = context.colors;
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    if (_searching) {
      return ScreenState(
        loading: true,
        error: null,
        connected: true,
        empty: false,
        subject: 'workspace',
        emptyHeadline: '',
        emptyBody: '',
        onRetry: () {},
        loadingBody: 'Searching',
        rows: 3,
        rowHeight: 44,
      );
    }
    final state = ScreenState(
      loading: false,
      error: _error,
      connected: connected,
      empty: !_ran || _nameHits.isEmpty && _contentHits.isEmpty,
      subject: 'search',
      emptyHeadline: _ran ? 'No matches' : 'Search this workspace',
      emptyBody: _ran
          ? 'Nothing in ${widget.label} matches “${_query.text.trim()}”.'
          : 'File names first, then matching lines inside files.',
      onRetry: connectionRetry(context, () => _search(_query.text)),
      emptyIcon: _ran ? Icons.search_off : Icons.search,
    );
    if (!connected ||
        _error != null ||
        !_ran ||
        _nameHits.isEmpty && _contentHits.isEmpty) {
      return state;
    }
    return ListView(
      children: [
        if (_nameHits.isNotEmpty) ...[
          _header(context, 'Files', _nameHits.length),
          for (final hit in _nameHits) _fileRow(context, hit),
        ],
        if (_contentHits.isNotEmpty) ...[
          _header(context, 'Inside files', _contentHits.length),
          for (final hit in _contentHits) _contentRow(context, hit),
        ],
        SizedBox(
          height: Space.xl,
          child: ColoredBox(color: c.paper),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String text, int count) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(Space.md, Space.md, Space.md, Space.sm),
    child: LedgerLabel('$text · $count'),
  );

  Widget _fileRow(BuildContext context, SearchHit hit) => InkWell(
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileScreen(
          workspace: widget.workspace,
          path: hit.path,
          name: hit.path.split('/').last,
        ),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 11),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 16,
            color: context.colors.muted,
          ),
          const SizedBox(width: Space.sm),
          Expanded(child: Text(hit.path, style: monoStyle(context, size: 12))),
        ],
      ),
    ),
  );

  Widget _contentRow(BuildContext context, SearchHit hit) {
    final c = context.colors;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileScreen(
            workspace: widget.workspace,
            path: hit.path,
            name: hit.path.split('/').last,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(hit.path, style: monoStyle(context, size: 11.5)),
                ),
                Text(
                  ':${hit.line}',
                  style: monoStyle(context, size: 10, color: c.muted),
                ),
              ],
            ),
            if (hit.snippet != null && hit.snippet!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                hit.snippet!.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(context, size: 10.5, color: c.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
