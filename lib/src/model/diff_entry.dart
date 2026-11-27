import '../bridge/decode.dart';

class DiffEntry {
  DiffEntry({
    required this.path,
    required this.staged,
    required this.untracked,
    this.kind = 'unstaged',
    this.oldPath,
    this.additions = 0,
    this.deletions = 0,
  });

  final String path;
  final bool staged;
  final bool untracked;

  final String kind;
  final String? oldPath;
  final int additions;
  final int deletions;

  factory DiffEntry.fromJson(Map<String, dynamic> j) => DiffEntry(
    path: str(j['path']),
    staged: flag(j['staged']) || j['kind'] == 'staged',
    untracked: flag(j['untracked']) || j['kind'] == 'untracked',
    kind: str(j['kind'], 'unstaged'),
    oldPath: strOrNull(j['old_path']),
    additions: whole(j['additions']),
    deletions: whole(j['deletions']),
  );
}
