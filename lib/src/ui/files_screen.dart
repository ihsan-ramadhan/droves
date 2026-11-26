import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge/bridge.dart';
import '../theme/tokens.dart';
import 'widgets.dart';

class FileEntry {
  FileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
    name: (j['name'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    isDir: j['type'] == 'directory',
    size: (j['size'] as num?)?.toInt() ?? 0,
  );
}

/// writes go through the bridge's upload path so permissions and paths stay on the owning machine
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.workspace, required this.label});

  final String workspace;
  final String label;

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> with BridgeAccess {
  final List<FileEntry> _stackDirs = [];
  final List<List<FileEntry>> _stack = [];
  List<FileEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  static const _showHiddenKey = 'droves.files.show_hidden';
  bool _showHidden = false;
  late final Future<void> _prefsReady;

  @override
  void initState() {
    super.initState();
    _prefsReady = _loadShowHidden();
  }

  Future<void> _loadShowHidden() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _showHidden = prefs.getBool(_showHiddenKey) ?? false;
    } catch (_) {
      _showHidden = false;
    }
  }

  @override
  Future<void> onBridgeReady() async {
    await _prefsReady;
    if (!mounted) return;
    await _load('');
  }

  Future<void> _load(String path) async {
    setState(() => _loading = true);
    try {
      final r = await bridge.listFiles(
        widget.workspace,
        path: path,
        showHidden: _showHidden,
      );
      final entries =
          ((r['entries'] as List?) ?? const [])
              .cast<Map<String, dynamic>>()
              .map(FileEntry.fromJson)
              .where((e) => _showHidden || !e.name.startsWith('.'))
              .toList()
            ..sort(
              (a, b) => a.isDir == b.isDir
                  ? a.name.compareTo(b.name)
                  : (a.isDir ? -1 : 1),
            );
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  String get _currentPath => _stackDirs.isEmpty ? '' : _stackDirs.last.path;
  Future<void> _toggleHidden() async {
    final next = !_showHidden;
    setState(() => _showHidden = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showHiddenKey, next);
    await _load(_currentPath);
  }

  Future<void> _open(FileEntry e) async {
    if (e.isDir) {
      _stack.add(_entries);
      _stackDirs.add(e);
      await _load(e.path);
    } else {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileScreen(
            workspace: widget.workspace,
            path: e.path,
            name: e.name,
          ),
        ),
      );
      if (mounted) await _load(_currentPath);
    }
  }

  void _up() {
    if (_stackDirs.isEmpty) return;
    _stackDirs.removeLast();
    final previous = _stack.removeLast();
    setState(() {
      _entries = previous;
    });
  }

  Future<String?> _askName(String title, String hint) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title, style: nameStyle(context, size: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: monoStyle(context, size: 13),
          decoration: InputDecoration(hintText: hint, isDense: true),
          onSubmitted: (v) => Navigator.of(dialog).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    return (name == null || name.isEmpty || name.contains('/')) ? null : name;
  }

  Future<void> _createFile() async {
    final name = await _askName('New file', 'notes.md');
    if (name == null || !mounted) return;
    final path = _currentPath.isEmpty ? name : '$_currentPath/$name';
    setState(() => _busy = true);
    try {
      await bridge.writeFile(widget.workspace, path, '');
      await _load(_currentPath);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              FileScreen(workspace: widget.workspace, path: path, name: name),
        ),
      );
      if (mounted) await _load(_currentPath);
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createFolder() async {
    final name = await _askName('New folder', 'src');
    if (name == null) return;
    setState(() => _busy = true);
    try {
      await bridge.createDirectory(widget.workspace, _currentPath, name);
      await _load(_currentPath);
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _entryActions(FileEntry e) async {
    final c = context.colors;
    final action = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
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
              leading: Icon(
                e.isDir
                    ? Icons.folder_open_outlined
                    : Icons.description_outlined,
                size: 18,
              ),
              title: Text('Open', style: monoStyle(context, size: 12.5)),
              onTap: () => Navigator.of(sheet).pop('open'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, size: 18, color: c.accent),
              title: Text(
                'Delete',
                style: monoStyle(context, size: 12.5, color: c.accent),
              ),
              onTap: () => Navigator.of(sheet).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'open') {
      await _open(e);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Delete ${e.name}?', style: nameStyle(context, size: 17)),
        content: Text(
          e.isDir
              ? 'Deletes the folder and everything inside it.'
              : 'Deletes the file.',
          style: monoStyle(context, size: 12, color: c.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Delete', style: TextStyle(color: c.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await bridge.deleteFile(widget.workspace, e.path);
      await _load(_currentPath);
    } catch (err) {
      if (mounted) _toast('$err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message, style: monoStyle(context, size: 12))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = _stackDirs.isEmpty ? widget.label : _stackDirs.last.name;
    final status = connectionSubtitle(context, _error);
    return DrovesScaffold(
      title: 'Files',
      subtitle: LedgerLabel(
        status.isNotEmpty
            ? status
            : _currentPath.isEmpty
            ? widget.label
            : _currentPath,
      ),
      leading: IconButton(
        icon: Icon(
          _stackDirs.isEmpty ? Icons.arrow_back : Icons.arrow_upward,
          size: 20,
        ),
        color: c.ink,
        tooltip: _stackDirs.isEmpty ? 'Back' : 'Parent folder',
        onPressed: () =>
            _stackDirs.isEmpty ? Navigator.of(context).maybePop() : _up(),
      ),
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.add, size: 20),
          color: c.paper,
          tooltip: 'New',
          enabled: !_busy,
          onSelected: (v) => v == 'file' ? _createFile() : _createFolder(),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'file',
              child: Text('New file', style: monoStyle(context, size: 12)),
            ),
            PopupMenuItem(
              value: 'folder',
              child: Text('New folder', style: monoStyle(context, size: 12)),
            ),
          ],
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
          onPressed: _toggleHidden,
        ),
        IconButton(
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : const Icon(Icons.refresh, size: 20),
          color: c.ink,
          tooltip: 'Refresh',
          onPressed: _busy ? null : () => _load(_currentPath),
        ),
      ],
      child: _buildBody(context, title),
    );
  }

  Widget _buildBody(BuildContext context, String title) {
    final c = context.colors;
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    final state = ScreenState(
      loading: _loading,
      error: _error,
      connected: connected,
      empty: _entries.isEmpty,
      subject: 'folder',
      emptyHeadline: 'Empty folder',
      emptyBody: 'No files here. Use + to add one.',
      onRetry: connectionRetry(context, () => _load(_currentPath)),
      rows: 8,
      rowHeight: 52,
      emptyIcon: Icons.folder_open_outlined,
      emptyAction: OutlinedButton(
        onPressed: _createFile,
        child: Text('New file', style: monoStyle(context, size: 12)),
      ),
    );
    if (_loading || !connected || _error != null || _entries.isEmpty) {
      return state;
    }
    return RefreshIndicator(
      color: c.ink,
      onRefresh: () => _load(_currentPath),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _entries.length,
        separatorBuilder: (_, _) => Divider(color: c.rule, height: 1),
        itemBuilder: (_, i) {
          final e = _entries[i];
          return InkWell(
            onTap: () => _open(e),
            onLongPress: () => _entryActions(e),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: 13,
              ),
              child: Row(
                children: [
                  Icon(
                    e.isDir
                        ? Icons.folder_outlined
                        : Icons.description_outlined,
                    size: 17,
                    color: c.muted,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: e.isDir
                          ? nameStyle(context, size: 14.5)
                          : monoStyle(context, size: 12.5),
                    ),
                  ),
                  if (!e.isDir)
                    Text(
                      _size(e.size),
                      style: monoStyle(context, size: 10, color: c.muted),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class FileScreen extends StatefulWidget {
  const FileScreen({
    super.key,
    required this.workspace,
    required this.path,
    required this.name,
  });

  final String workspace;
  final String path;
  final String name;

  @override
  State<FileScreen> createState() => _FileScreenState();
}

class _FileScreenState extends State<FileScreen> with BridgeAccess {
  final _editor = TextEditingController();
  final _scroll = ScrollController();
  String _text = '';
  bool _truncated = false;
  bool _binary = false;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void onBridgeReady() => _load();

  @override
  void dispose() {
    _editor.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _editable => !_binary && !_truncated;

  Future<void> _load() async {
    try {
      final r = await bridge.readFile(widget.workspace, widget.path);
      if (!mounted) return;
      setState(() {
        _text = (r['text'] as String?) ?? '';
        _truncated = r['truncated'] == true;
        _binary = r['binary'] == true;
        _editor.text = _text;
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await bridge.writeFile(widget.workspace, widget.path, _editor.text);
      if (!mounted) return;
      setState(() {
        _text = _editor.text;
        _editing = false;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved ${widget.name}',
            style: monoStyle(context, size: 12),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e', style: monoStyle(context, size: 12))),
      );
    }
  }

  Future<void> _leave() async {
    if (!_editing || _editor.text == _text) {
      Navigator.of(context).maybePop();
      return;
    }
    final c = context.colors;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Discard changes?', style: nameStyle(context, size: 17)),
        content: Text(
          '${widget.name} has unsaved edits.',
          style: monoStyle(context, size: 12, color: c.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Discard', style: TextStyle(color: c.accent)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final live = app.bridge;
    final connected = live != null && live.state == BridgeState.ready;
    return PopScope(
      canPop: !_editing || _editor.text == _text,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: DrovesScaffold(
        title: widget.name,
        subtitle: LedgerLabel(
          _binary
              ? 'binary · read only'
              : _truncated
              ? 'preview truncated · read only'
              : widget.path,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          color: c.ink,
          tooltip: 'Back',
          onPressed: _leave,
        ),
        actions: [
          if (_editable)
            _editing
                ? IconButton(
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          )
                        : const Icon(Icons.check, size: 20),
                    color: c.ink,
                    tooltip: 'Save',
                    onPressed: _saving ? null : _save,
                  )
                : IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    color: c.ink,
                    tooltip: 'Edit',
                    onPressed: () => setState(() => _editing = true),
                  ),
        ],
        child: _loading || !connected || _error != null || _binary
            ? ScreenState(
                loading: _loading,
                error: _error,
                connected: connected,
                empty: _binary,
                subject: 'file',
                emptyHeadline: 'Binary file',
                emptyBody: 'Only text files can be opened here.',
                onRetry: connectionRetry(context, _load),
                rows: 10,
                rowHeight: 26,
                emptyIcon: Icons.data_object_outlined,
              )
            : _editing
            ? Padding(
                padding: const EdgeInsets.all(Space.sm),
                child: TextField(
                  controller: _editor,
                  scrollController: _scroll,
                  autofocus: true,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: monoStyle(context, size: 12),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              )
            : _text.isEmpty
            ? StateMessage(
                headline: 'Empty file',
                body: _editable
                    ? 'Tap the pencil to write the first line.'
                    : 'This file has no readable text.',
                icon: Icons.description_outlined,
                action: _editable
                    ? OutlinedButton(
                        onPressed: () => setState(() => _editing = true),
                        child: Text(
                          'Edit',
                          style: monoStyle(context, size: 12),
                        ),
                      )
                    : null,
              )
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(Space.md),
                itemCount: _text.split('\n').length,
                itemBuilder: (_, i) => Text(
                  _text.split('\n')[i],
                  style: monoStyle(context, size: 11.5),
                ),
              ),
      ),
    );
  }
}
