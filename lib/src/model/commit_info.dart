import '../bridge/decode.dart';

class CommitInfo {
  CommitInfo({
    required this.sha,
    required this.shortSha,
    required this.subject,
    required this.author,
    required this.authoredAt,
    this.tags = const [],
  });

  final String sha;
  final String shortSha;
  final String subject;
  final String author;
  final String authoredAt;
  final List<String> tags;

  factory CommitInfo.fromJson(Map<String, dynamic> j) => CommitInfo(
    sha: str(j['sha']),
    shortSha: str(j['short_sha']),
    subject: str(j['subject']),
    author: str(j['author']),
    authoredAt: str(j['authored_at']),
    tags: strings(j['tags']),
  );
}
