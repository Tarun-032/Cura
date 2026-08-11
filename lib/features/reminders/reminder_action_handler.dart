/// Notification Taken/Snooze — fresh DB + plugin in this isolate.
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/data/app_database.dart';
import '../../core/data/reminder_repository.dart';

const kTakenAction = 'taken';
const kSnoozeAction = 'snooze';

/// Snooze ids outside plan ranges.
const _snoozeBase = 900000;
const _snoozeMinutes = 15;

/// Top-level action entry (required by the plugin).
@pragma('vm:entry-point')
void reminderActionBackground(NotificationResponse response) {
  final action = response.actionId;
  if (action != kTakenAction && action != kSnoozeAction) return;
  // Isolate is short-lived; don't await.
  _handle(action!, response).catchError(
    (Object error) => debugPrint('[Cura.reminders] action failed: $error'),
  );
}

Future<void> _handle(String action, NotificationResponse response) async {
  final ids = _doseIds(response.payload);
  if (ids.isEmpty) return;

  if (action == kSnoozeAction) {
    await _snooze(response);
    return;
  }

  final dir = await getApplicationDocumentsDirectory();
  final db = AppDatabase.background(File(p.join(dir.path, kDatabaseFileName)));
  try {
    await ReminderRepository(db).setTaken(ids, DateTime.now());
  } finally {
    await db.close();
  }
}

Future<void> _snooze(NotificationResponse response) async {
  tzdata.initializeTimeZones();
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin.zonedSchedule(
    id: _snoozeBase + (response.id ?? 0) % 1000,
    scheduledDate: tz.TZDateTime.now(
      tz.local,
    ).add(const Duration(minutes: _snoozeMinutes)),
    title: 'Snoozed: still due',
    body: 'Tap to open Cura.',
    payload: response.payload,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        'cura_medicine_reminders',
        'Medicine reminders',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
        actions: [AndroidNotificationAction(kTakenAction, 'Taken')],
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
  );
}

/// Parse dose ids from payload.
List<int> _doseIds(String? payload) {
  final head = payload?.split('|').first ?? '';
  return [for (final part in head.split(',')) ?int.tryParse(part)];
}
