class SearchHit {
  SearchHit({required this.path, this.line, this.snippet});

  final String path;
  final int? line;
  final String? snippet;

  bool get isContent => line != null;
}
