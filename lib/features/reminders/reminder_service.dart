import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'reminder.dart';
import 'reminder_action_handler.dart';
import 'reminder_plan.dart';

class ReminderService {
  ReminderService([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  static const _channel = AndroidNotificationChannel(
    'cura_medicine_reminders',
    'Medicine reminders',
    description: 'Reminds you when a dose is due.',
    importance: Importance.high,
  );

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<void> init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(await FlutterTimezone.getLocalTimezone()));
    } catch (error) {
      debugPrint('[Cura.reminders] local timezone unavailable: $error');
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveBackgroundNotificationResponse: reminderActionBackground,
      onDidReceiveNotificationResponse: reminderActionBackground,
    );
    await _android?.createNotificationChannel(_channel);
    _ready = true;
  }

  Future<bool> requestPermissions() async {
    await init();
    final allowed = await _android?.requestNotificationsPermission() ?? true;
    if (allowed) await _android?.requestExactAlarmsPermission();
    return allowed;
  }

  Future<bool> canScheduleExactly() async =>
      await _android?.canScheduleExactNotifications() ?? false;

  Future<void> sync(List<MedicineReminder> reminders) async {
    await init();
    await _clear();

    final mode = await canScheduleExactly()
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    final planned = planNotifications(reminders, DateTime.now());
    for (final n in planned) {
      await _book(n, mode);
    }
    debugPrint(
      '[Cura.reminders] ${reminders.length} doses in ${planned.length} alarms',
    );
  }

  Future<void> _clear() async {
    for (final pending in await _plugin.pendingNotificationRequests()) {
      await _plugin.cancel(id: pending.id);
    }
  }

  Future<void> _book(PlannedNotification n, AndroidScheduleMode mode) async {
    await _plugin.zonedSchedule(
      id: n.id,
      scheduledDate: tz.TZDateTime.from(n.at, tz.local),
      title: n.title,
      body: n.body,
      payload: n.payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          groupKey: _channel.id,
          styleInformation: BigTextStyleInformation(
            n.body,
            contentTitle: n.title,
          ),
          actions: n.courseEnd
              ? const []
              : const [
                  AndroidNotificationAction(kTakenAction, 'Taken'),
                  AndroidNotificationAction(
                    kSnoozeAction,
                    'Snooze 15m',
                    cancelNotification: false,
                  ),
                ],
        ),
      ),
      androidScheduleMode: mode,
      matchDateTimeComponents: n.repeatDaily ? DateTimeComponents.time : null,
    );
  }
}

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService(),
);
