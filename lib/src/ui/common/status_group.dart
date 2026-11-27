import 'package:material_ui/material_ui.dart';

import '../../theme/tokens.dart';

enum StatusGroup { working, done, idle }

StatusGroup statusGroupOf(String status) => switch (status) {
  'blocked' || 'working' => StatusGroup.working,
  'done' => StatusGroup.done,
  _ => StatusGroup.idle,
};

int statusRank(String status) => switch (status) {
  'blocked' => 0,
  'working' => 1,
  'done' => 2,
  _ => 3,
};

extension StatusGroupLabel on StatusGroup {
  String get label => switch (this) {
    StatusGroup.working => 'Working',
    StatusGroup.done => 'Done',
    StatusGroup.idle => 'Idle',
  };
}

class StatusSection<T> {
  const StatusSection(this.group, this.items);

  final StatusGroup group;
  final List<T> items;
}

List<StatusSection<T>> statusSections<T>(
  Iterable<T> items,
  String Function(T) status,
) {
  final indexed = items.toList().asMap().entries.toList()
    ..sort((a, b) {
      final byStatus = statusRank(status(a.value))
          .compareTo(statusRank(status(b.value)));
      return byStatus == 0 ? a.key.compareTo(b.key) : byStatus;
    });
  final buckets = <StatusGroup, List<T>>{
    for (final group in StatusGroup.values) group: [],
  };
  for (final entry in indexed) {
    buckets[statusGroupOf(status(entry.value))]!.add(entry.value);
  }
  return [
    for (final group in StatusGroup.values)
      if (buckets[group]!.isNotEmpty) StatusSection(group, buckets[group]!),
  ];
}

class StatusSectionHeader extends StatelessWidget {
  const StatusSectionHeader({
    super.key,
    required this.group,
    required this.count,
  });

  final StatusGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.lg,
        Space.md,
        Space.sm,
      ),
      child: LedgerLabel('${group.label} · $count'),
    );
  }
}
