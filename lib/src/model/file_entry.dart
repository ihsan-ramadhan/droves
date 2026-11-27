import '../bridge/decode.dart';

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
    name: str(j['name']),
    path: str(j['path']),
    isDir: j['type'] == 'directory',
    size: whole(j['size']),
  );
}
