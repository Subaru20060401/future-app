import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'app_state.dart' hide Priority;

// 💡 ローカル通知を一手に管理するサービス
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Tokyo'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios, macOS: ios),
    );
    _initialized = true;
  }

  // 通知許可をリクエスト（iOS / Android13+）
  Future<bool> requestPermission() async {
    await init();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          'pocket_maid',
          'ポケットメイドの通知',
          channelDescription: '支払い・Todo・残高の通知',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      );

  Future<void> _schedule(int id, String title, String body, DateTime when) async {
    // 過去の日時はスキップ
    if (when.isBefore(DateTime.now())) return;
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      tz.TZDateTime.from(when, tz.local),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  // 💡 全データから通知を組み立て直す（変更のたびに呼ぶ）
  Future<void> rescheduleAll(AppState state) async {
    await init();
    await _plugin.cancelAll();
    int id = 0;

    // 支払い: 7日前 / 3日前 / 当日 (朝9時)
    for (final p in state.payments.where((e) => !e.paid)) {
      for (final daysBefore in [7, 3, 0]) {
        final base = p.paymentDate.subtract(Duration(days: daysBefore));
        final when = DateTime(base.year, base.month, base.day, 9, 0);
        final label = daysBefore == 0 ? '本日' : '$daysBefore日後';
        await _schedule(
          id++,
          '💳 ${p.cardName}の支払い ($label)',
          '¥${p.amount} の支払日が近づいています',
          when,
        );
      }
    }

    // Todo: 各Todoの設定した「何日前」に通知。時刻指定があれば締切の時刻、無ければ9:00。
    for (final t in state.allTodos.where((e) => !e.completed)) {
      for (final daysBefore in t.reminderDaysBefore) {
        final base = t.deadline.subtract(Duration(days: daysBefore));
        final when = t.hasTime
            ? DateTime(base.year, base.month, base.day, t.deadline.hour, t.deadline.minute)
            : DateTime(base.year, base.month, base.day, 9, 0);
        final label = daysBefore == 0
            ? '本日締切'
            : daysBefore == 1
                ? '明日締切'
                : '締切$daysBefore日前';
        final labelTag = t.label.isNotEmpty ? '[${t.label}] ' : '';
        await _schedule(id++, '✅ $label: $labelTag${t.title}', t.description, when);
      }
    }

    // 予定: 通知ありのものを「開始のN分前」に通知
    for (final list in state.events.values) {
      for (final e in list) {
        final mins = e.notifyMinutesBefore;
        if (mins == null || e.start == null) continue;
        final when = e.start!.subtract(Duration(minutes: mins));
        final body = e.allDay
            ? '本日の予定'
            : '${e.start!.hour}:${e.start!.minute.toString().padLeft(2, '0')} 開始';
        await _schedule(id++, '📅 ${e.title}', e.location.isNotEmpty ? '${e.location} ・ $body' : body, when);
      }
    }
  }

  // 残高不足を今すぐ通知
  Future<void> notifyShortage(int balance) async {
    await init();
    await _plugin.show(
      99999,
      '⚠ 残高不足の恐れ',
      '今月末の予想残高が ¥$balance です。支払いを確認してください。',
      _details,
    );
  }
}
