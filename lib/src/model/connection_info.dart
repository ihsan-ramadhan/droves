import '../bridge/decode.dart';

class ConnectionInfo {
  ConnectionInfo({
    required this.id,
    required this.label,
    required this.state,
    required this.type,
    required this.isDefault,
    required this.readOnly,
    this.controlSocket,
  });

  final String id;
  final String label;
  final String state;
  final String type;
  final bool isDefault;
  final bool readOnly;
  final String? controlSocket;

  factory ConnectionInfo.fromJson(Map<String, dynamic> j) => ConnectionInfo(
    id: str(j['id']),
    label: str(j['label']),
    state: str(j['state'], 'unknown'),
    type: str(j['type'], 'local'),
    isDefault: flag(j['is_default']),
    readOnly: flag(j['read_only']),
    controlSocket: strOrNull(j['control_socket_path']),
  );
}
