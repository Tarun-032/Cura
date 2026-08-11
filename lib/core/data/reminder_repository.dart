import 'package:drift/drift.dart';

import '../../features/reminders/reminder.dart';
import 'app_database.dart';

class ReminderRepository {
  ReminderRepository(this._db);

  final AppDatabase _db;

  Stream<List<MedicineReminder>> watchAll() {
    final query = _db.select(_db.reminders)
      ..orderBy([(r) => OrderingTerm.asc(r.minuteOfDay)]);
    return query.watch().map((rows) => rows.map(_toModel).toList());
  }

  Future<List<MedicineReminder>> all() async =>
      (await _db.select(_db.reminders).get()).map(_toModel).toList();

  Future<List<MedicineReminder>> forDocument(String documentId) async {
    final query = _db.select(_db.reminders)
      ..where((r) => r.documentId.equals(documentId));
    return (await query.get()).map(_toModel).toList();
  }

  Future<List<MedicineReminder>> addAll({
    required String documentId,
    required String medicineLabel,
    required List<int> minutes,
    required DateTime startDate,
    DateTime? endDate,
  }) async {
    final saved = <MedicineReminder>[];
    for (final minute in minutes) {
      final id = await _db
          .into(_db.reminders)
          .insert(
            RemindersCompanion.insert(
              documentId: documentId,
              medicineLabel: medicineLabel,
              minuteOfDay: minute,
              startDate: startDate,
              endDate: Value(endDate),
            ),
          );
      saved.add(
        MedicineReminder(
          id: id,
          documentId: documentId,
          medicineLabel: medicineLabel,
          minuteOfDay: minute,
          startDate: startDate,
          endDate: endDate,
        ),
      );
    }
    return saved;
  }

  Future<void> setEnabled(int id, bool enabled) =>
      (_db.update(_db.reminders)..where((r) => r.id.equals(id))).write(
        RemindersCompanion(enabled: Value(enabled)),
      );

  Future<void> setTaken(List<int> ids, DateTime? day) =>
      (_db.update(_db.reminders)..where((r) => r.id.isIn(ids))).write(
        RemindersCompanion(
          lastTakenDay: Value(day == null ? null : _dayOnly(day)),
        ),
      );

  Future<void> setCourse(List<int> ids, DateTime? endDate) =>
      (_db.update(_db.reminders)..where((r) => r.id.isIn(ids))).write(
        RemindersCompanion(
          endDate: Value(endDate == null ? null : _dayOnly(endDate)),
        ),
      );

  Future<void> setTime(int id, int minuteOfDay) =>
      (_db.update(_db.reminders)..where((r) => r.id.equals(id))).write(
        RemindersCompanion(minuteOfDay: Value(minuteOfDay)),
      );

  Future<List<int>> deleteForDocument(String documentId) async {
    final doomed = await forDocument(documentId);
    await (_db.delete(
      _db.reminders,
    )..where((r) => r.documentId.equals(documentId))).go();
    return [for (final r in doomed) r.id];
  }

  Future<List<int>> deleteMedicine(String documentId, String label) async {
    final doomed = [
      for (final r in await forDocument(documentId))
        if (r.medicineLabel == label) r.id,
    ];
    if (doomed.isEmpty) return const [];
    await (_db.delete(_db.reminders)..where((r) => r.id.isIn(doomed))).go();
    return doomed;
  }

  Future<List<int>> deleteAll() async {
    final doomed = await all();
    await _db.delete(_db.reminders).go();
    return [for (final r in doomed) r.id];
  }

  Future<List<int>> deleteFinished(DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    final doomed = [
      for (final r in await all())
        if (r.endDate != null && today.isAfter(_dayOnly(r.endDate!))) r.id,
    ];
    if (doomed.isEmpty) return const [];
    await (_db.delete(_db.reminders)..where((r) => r.id.isIn(doomed))).go();
    return doomed;
  }

  MedicineReminder _toModel(ReminderRow row) => MedicineReminder(
    id: row.id,
    documentId: row.documentId,
    medicineLabel: row.medicineLabel,
    minuteOfDay: row.minuteOfDay,
    startDate: row.startDate,
    endDate: row.endDate,
    enabled: row.enabled,
    lastTakenDay: row.lastTakenDay,
  );
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);
