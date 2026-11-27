import '../bridge/decode.dart';

class ScoutModel {
  ScoutModel({
    required this.cli,
    required this.provider,
    required this.id,
    required this.label,
    required this.thinkingLevels,
  });

  final String cli;
  final String provider;
  final String id;
  final String label;
  final List<String> thinkingLevels;

  factory ScoutModel.fromJson(Map<String, dynamic> j) => ScoutModel(
    cli: str(j['cli'], 'omp'),
    provider: str(j['provider']),
    id: str(j['id']),
    label: str(j['label'], str(j['id'])),
    thinkingLevels: strings(j['thinking_levels']),
  );
}
