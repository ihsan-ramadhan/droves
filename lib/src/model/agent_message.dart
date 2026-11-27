class AgentMessage {
  AgentMessage({
    required this.id,
    required this.role,
    required this.text,
    this.kind = 'message',
    this.toolName,
    this.isError = false,
    this.textBytes,
    this.sentAt,
  });

  final String id;
  final String role;

  final String kind;
  final String text;
  final String? toolName;
  final bool isError;

  final int? textBytes;
  final String? sentAt;

  bool get isUser => role == 'user';
  bool get isTool => kind == 'tool_call' || kind == 'tool_result';
}
