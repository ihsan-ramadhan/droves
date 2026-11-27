import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge/decode.dart';
import '../model/commit_info.dart';
import '../model/diff_entry.dart';
import '../theme/tokens.dart';
import 'common/bridge_access.dart';
import 'common/scaffold.dart';
import 'common/state_message.dart';
import 'dialogs.dart';

/// hidden when any path segment starts with a dot, matching the Files browser
bool _hasHiddenSegment(String path) =>
    path.split('/').any((segment) => segment.startsWith('.'));

/// read-only changes for one workspace; commits stay on the machine
class GitScreen extends StatefulWidget {
  const GitScreen({super.key, required this.workspace, required this.label});

  final String workspace;
  final String label;

  @override
  State<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends State<GitScreen>
    with BridgeAccess, WidgetsBindingObserver {
  List<DiffEntry> _entries = const [];
  String? _repo;
  bool _loading = true;
  final Set<String> _selected = {};
  bool _pulling = false;
  bool _pushing = false;
  String _messageDraft = '';
  String get _draftKey => 'droves.commit_draft.${widget.workspace}';
  String? _error;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selected.clear();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _messageDraft = prefs.getString(_draftKey) ?? '';
        // same toggle as the Files browser; hidden paths stay out of the diff list
        _showHidden = prefs.getBool('droves.files.show_hidden') ?? false;
      });
    });
  }

  Future<void> _saveDraft(String text) async {
    _messageDraft = text;
    final prefs = await SharedPreferences.getInstance();
    if (text.trim().isEmpty) {
      await prefs.remove(_draftKey);
    } else {
      await prefs.setString(_draftKey, text);
    }
  }

  Future<void> _toggleHidden() async {
    final next = !_showHidden;
    setState(() => _showHidden = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('droves.files.show_hidden', next);
    await _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _selected.isNotEmpty) {
      setState(() => _selected.clear());
    }
  }

  @override
  void onBridgeReady() => _load();

  List<DiffEntry> get _selectedEntries =>
      _entries.where((e) => _selected.contains(e.path)).toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await bridge.call('git.diff_summary', {
        'workspace_id': widget.workspace,
      });
      final entries = maps(r['entries'])
          .map(DiffEntry.fromJson)
          .where((e) => _showHidden || !_hasHiddenSegment(e.path))
          .toList();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _repo = r['repo_name'] as String?;
        final paths = entries.map((e) => e.path).toSet();
        _selected.retainWhere(paths.contains);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pull() async {
    final ok = await confirmDialog(
      context,
      title: 'Pull this branch?',
      body: 'Fast-forward only. Stops if the branches diverged.',
    );
    if (!ok) return;
    setState(() => _pulling = true);
    try {
      final r = await bridge.call('git.pull', {
        'workspace_id': widget.workspace,
      });
      if (!mounted) return;
      showToast(context, 'Pull: ${(r['summary'] as String?) ?? 'Done'}');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
  }

  Future<void> _push() async {
    final ok = await confirmDialog(
      context,
      title: 'Push this branch?',
      body:
          'Pushes the current branch to origin. Commits local to this machine '
          'leave the machine only when you confirm.',
      confirmLabel: 'Push',
    );
    if (!ok) return;
    setState(() => _pushing = true);
    try {
      final r = await bridge.call('git.push', {
        'workspace_id': widget.workspace,
      });
      if (!mounted) return;
      final branch = str(r['branch']);
      final summary = ((r['summary'] as String?) ?? 'Done').split('\n').last;
      showToast(context, 'Push $branch: $summary');
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _pushing = false);
    }
  }

  Future<void> _commit() async {
    final selected = _selectedEntries;
    if (selected.isEmpty) {
      showToast(context, 'Select files to commit');
      return;
    }
    final message = await promptText(
      context,
      title: 'Commit ${selected.length} file(s)',
      hint: 'Commit message',
      confirmLabel: 'Commit',
      initial: _messageDraft,
      maxLines: 4,
      onChanged: _saveDraft,
    );
    if (message == null || message.isEmpty || !mounted) return;
    try {
      final r = await bridge.call('git.commit.create', {
        'workspace_id': widget.workspace,
        'message': message,
        'paths': selected.map((e) => e.path).toList(),
      });
      if (!mounted) return;
      final sha = str(r['sha']);
      showToast(
        context,
        'Committed ${sha.length > 7 ? sha.substring(0, 7) : sha}'.trim(),
      );
      await _saveDraft('');
      _selected.clear();
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Changes',
      subtitle: LedgerLabel(
        status.isNotEmpty
            ? status
            : _repo == null
            ? widget.label
            : '$_repo · ${widget.label}',
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        if (connected) ...[
          if (_entries.isNotEmpty && _selected.length < _entries.length)
            IconButton(
              icon: const Icon(Icons.select_all, size: 20),
              color: c.ink,
              tooltip: 'Select all',
              style: IconButton.styleFrom(
                splashFactory: NoSplash.splashFactory,
              ),
              onPressed: () =>
                  setState(() => _selected.addAll(_entries.map((e) => e.path))),
            ),
          if (_selected.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.deselect, size: 20),
              color: c.ink,
              tooltip: 'Unselect all',
              style: IconButton.styleFrom(
                splashFactory: NoSplash.splashFactory,
              ),
              onPressed: () => setState(() => _selected.clear()),
            ),
          if (_selected.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.check, size: 20),
              color: c.accent,
              tooltip: 'Commit selected files',
              style: IconButton.styleFrom(
                splashFactory: NoSplash.splashFactory,
              ),
              onPressed: _commit,
            ),
          IconButton(
            icon: Icon(
              _showHidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 20,
            ),
            color: c.ink,
            tooltip: _showHidden ? 'Hide hidden files' : 'Show hidden files',
            style: IconButton.styleFrom(splashFactory: NoSplash.splashFactory),
            onPressed: _toggleHidden,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            color: c.paper,
            tooltip: 'Repository',
            onSelected: (v) => switch (v) {
              'pull' => _pull(),
              'push' => _push(),
              _ => _load(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'refresh',
                enabled: !_pulling,
                child: Text(
                  'Refresh',
                  style: monoStyle(context, size: 12, color: c.ink),
                ),
              ),
              PopupMenuItem(
                value: 'pull',
                enabled: !_pulling,
                child: Text(
                  _pulling ? 'Pulling…' : 'Pull branch',
                  style: monoStyle(context, size: 12, color: c.ink),
                ),
              ),
              PopupMenuItem(
                value: 'push',
                enabled: !_pushing,
                child: Text(
                  _pushing ? 'Pushing…' : 'Push branch',
                  style: monoStyle(context, size: 12, color: c.ink),
                ),
              ),
            ],
          ),
        ],
      ],
      child: _buildBody(context),
    );
  }

  Future<void> _fileAction(DiffEntry e) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                Space.md,
                Space.md,
                Space.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: LedgerLabel(e.path),
              ),
            ),
            ListTile(
              title: Text(
                e.staged ? 'Unstage file' : 'Stage file',
                style: monoStyle(context, size: 12.5),
              ),
              onTap: () =>
                  Navigator.of(sheet).pop(e.staged ? 'unstage' : 'stage'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      await bridge.call('git.file_action', {
        'workspace_id': widget.workspace,
        'path': e.path,
        'action': action,
      });
      await _load();
    } catch (err) {
      if (mounted) showError(context, err);
    }
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final state = ScreenState(
      loading: _loading && _entries.isEmpty,
      error: _error,
      connected: connected,
      empty: _entries.isEmpty,
      subject: 'changes',
      emptyHeadline: 'Nothing to review',
      emptyBody: 'No pending changes.',
      onRetry: connectionRetry(context, _load),
      rows: 7,
      rowHeight: 64,
      emptyIcon: Icons.check_circle_outline,
    );
    if (_loading || !connected || _error != null || _entries.isEmpty) {
      return state;
    }
    return RefreshIndicator(
      color: c.ink,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
        itemBuilder: (_, i) {
          final e = _entries[i];
          return ListTile(
            leading: Checkbox(
              value: _selected.contains(e.path),
              activeColor: c.accent,
              onChanged: (checked) => setState(() {
                if (checked == true) {
                  _selected.add(e.path);
                } else {
                  _selected.remove(e.path);
                }
              }),
            ),
            title: Text(e.path, style: monoStyle(context, size: 12)),
            subtitle: Text(
              e.kind == 'conflicted'
                  ? 'conflicted'
                  : (e.untracked
                        ? 'untracked'
                        : (e.staged ? 'staged' : 'working tree')),
              style: monoStyle(context, size: 10, color: c.muted),
            ),
            trailing: Text(
              '+${e.additions} −${e.deletions}',
              style: monoStyle(context, size: 10, color: c.muted),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DiffScreen(
                  workspace: widget.workspace,
                  path: e.path,
                  oldPath: e.oldPath,
                  kind: e.kind,
                ),
              ),
            ),
            onLongPress: () => _fileAction(e),
          );
        },
      ),
    );
  }
}

class DiffScreen extends StatefulWidget {
  const DiffScreen({
    super.key,
    required this.workspace,
    required this.path,
    this.oldPath,
    this.kind = 'unstaged',
    this.sha,
    this.base,
  });

  final String workspace;
  final String path;
  final String? oldPath;
  final String kind;
  final String? sha;

  /// parent commit of [sha]; `git.commit_file` diffs from it
  final String? base;

  @override
  State<DiffScreen> createState() => _DiffScreenState();
}

class _DiffScreenState extends State<DiffScreen> with BridgeAccess {
  String _patch = '';
  bool _loading = true;
  String? _error;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    try {
      final r = await bridge.call('git.diff_file', {
        'workspace_id': widget.workspace,
        'path': widget.path,
        if (widget.oldPath != null) 'old_path': widget.oldPath,
        if (widget.sha == null) 'kind': widget.kind,
        if (widget.sha != null) ...{'mode': 'commit', 'commit': widget.sha},
      });
      if (!mounted) return;
      setState(() {
        _patch = (r['patch'] as String?) ?? str(r['diff']);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: widget.path.split('/').last,
      subtitle: LedgerLabel(status.isNotEmpty ? status : widget.path),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      child: _loading || !connected || _error != null || _patch.isEmpty
          ? ScreenState(
              loading: _loading && _patch.isEmpty,
              error: _error,
              connected: connected,
              empty: _patch.isEmpty,
              subject: 'diff',
              emptyHeadline: 'No patch',
              emptyBody: 'No text changes in this file.',
              onRetry: connectionRetry(context, _load),
              rows: 12,
              rowHeight: 24,
              emptyIcon: Icons.remove_circle_outline,
            )
          : ListView.builder(
              itemCount: _patch.split('\n').length,
              itemBuilder: (_, i) {
                final line = _patch.split('\n')[i];
                final added = line.startsWith('+') && !line.startsWith('+++');
                final removed = line.startsWith('-') && !line.startsWith('---');
                return Container(
                  color: added
                      ? const Color(0x1A8FA968)
                      : removed
                      ? const Color(0x1AD9642F)
                      : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.sm,
                    vertical: 1,
                  ),
                  child: Text(
                    line,
                    style: monoStyle(
                      context,
                      size: 11,
                      color: added ? c.ink : (removed ? c.ink : c.muted),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// recent commits, read-only; tapping one shows its patch
class CommitsScreen extends StatefulWidget {
  const CommitsScreen({
    super.key,
    required this.workspace,
    required this.label,
  });

  final String workspace;
  final String label;

  @override
  State<CommitsScreen> createState() => _CommitsScreenState();
}

class _CommitsScreenState extends State<CommitsScreen> with BridgeAccess {
  List<CommitInfo> _commits = const [];
  String? _head;
  bool _loading = true;
  String? _error;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await bridge.call('git.commits', {
        'workspace_id': widget.workspace,
      });
      if (!mounted) return;
      setState(() {
        _commits = maps(r['commits']).map(CommitInfo.fromJson).toList();
        _head = r['head'] as String?;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Commits',
      subtitle: LedgerLabel(
        status.isNotEmpty
            ? status
            : _head == null
            ? widget.label
            : 'head ${_head!.substring(0, _head!.length.clamp(0, 7))}',
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [if (connected) RefreshButton(busy: _loading, onPressed: _load)],
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final state = ScreenState(
      loading: _loading && _commits.isEmpty,
      error: _error,
      connected: connected,
      empty: _commits.isEmpty,
      subject: 'commit history',
      emptyHeadline: 'No commits',
      emptyBody: 'This branch has no commits.',
      onRetry: connectionRetry(context, _load),
      rows: 8,
      rowHeight: 64,
      emptyIcon: Icons.history,
    );
    if (_loading || !connected || _error != null || _commits.isEmpty) {
      return state;
    }
    return ListView.separated(
      itemCount: _commits.length,
      separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
      itemBuilder: (_, i) {
        final commit = _commits[i];
        return InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  CommitScreen(workspace: widget.workspace, commit: commit),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.md,
              vertical: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (commit.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Wrap(
                      spacing: 4,
                      children: [
                        for (final tag in commit.tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.accent.withValues(alpha: 0.14),
                              border: Border.all(color: c.accent),
                              borderRadius: BorderRadius.circular(Radii.row),
                            ),
                            child: Text(
                              tag,
                              style: monoStyle(
                                context,
                                size: 10,
                                color: c.accent,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Text(commit.subject, style: nameStyle(context, size: 14.5)),
                const SizedBox(height: 3),
                Text(
                  '${commit.shortSha} · ${commit.author} · ${_date(commit.authoredAt)}',
                  style: monoStyle(context, size: 10, color: c.muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _date(String iso) =>
      iso.length >= 10 ? iso.substring(0, 10) : iso;
}

class CommitScreen extends StatefulWidget {
  const CommitScreen({
    super.key,
    required this.workspace,
    required this.commit,
  });

  final String workspace;
  final CommitInfo commit;

  @override
  State<CommitScreen> createState() => _CommitScreenState();
}

class _CommitScreenState extends State<CommitScreen> with BridgeAccess {
  List<DiffEntry> _files = const [];
  String? _base;
  bool _loading = true;
  String? _error;

  @override
  void onBridgeReady() => _load();

  Future<void> _load() async {
    try {
      final r = await bridge.call('git.commit', {
        'workspace_id': widget.workspace,
        'sha': widget.commit.sha,
      });
      if (!mounted) return;
      setState(() {
        _files = maps(r['entries']).map(DiffEntry.fromJson).toList();
        _base = r['base'] as String?;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final connected = app.connected;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: widget.commit.subject,
      subtitle: LedgerLabel(
        status.isNotEmpty ? status : widget.commit.shortSha,
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        color: c.ink,
        tooltip: 'Back',
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      child: _loading || !connected || _error != null || _files.isEmpty
          ? ScreenState(
              loading: _loading && _files.isEmpty,
              error: _error,
              connected: connected,
              empty: _files.isEmpty,
              subject: 'commit files',
              emptyHeadline: 'No changed files',
              emptyBody: 'No file changes in this commit.',
              onRetry: connectionRetry(context, _load),
              rows: 6,
              rowHeight: 56,
              emptyIcon: Icons.remove_circle_outline,
            )
          : ListView.separated(
              itemCount: _files.length,
              separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
              itemBuilder: (_, i) => ListTile(
                title: Text(
                  _files[i].path,
                  style: monoStyle(context, size: 12),
                ),
                trailing: Text(
                  '+${_files[i].additions} −${_files[i].deletions}',
                  style: monoStyle(context, size: 10, color: c.muted),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DiffScreen(
                      workspace: widget.workspace,
                      path: _files[i].path,
                      sha: widget.commit.sha,
                      base: _base,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
