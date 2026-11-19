// 💡 保存・読込・書き出し・取り込みの往復と、起動時／取り込み時の自己修復。
//   どれも「画面は壊れず、次に開いたときにデータが静かに変わる」形で出る不具合を防ぐ。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/failing_prefs.dart';
import 'support/rich_fixture.dart';
import 'support/test_app.dart';

void main() {
  final now = DateTime(2026, 11, 19, 10);

  group('往復で全項目が残る', () {
    test('書き出し → 取り込み → 書き出し が一致する', () async {
      final a = await richApp(now);
      final json = a.exportJson();
      final b = await fixedApp(now);
      await b.importJson(json);
      expect(exportWithoutStamp(b), exportWithoutStamp(a));
    });

    test('保存 → 作り直して読込 → 書き出し が一致する', () async {
      final a = await richApp(now);
      await a.saveData();
      final b = await reloadApp(now);
      expect(exportWithoutStamp(b), exportWithoutStamp(a));
    });

    test('取り込み → 保存 → 作り直して読込 でも一致する（ドライブの取り込み後の再起動）', () async {
      final a = await richApp(now);
      final json = a.exportJson();
      final b = await fixedApp(now);
      await b.importJson(json);
      final c = await reloadApp(now);
      expect(exportWithoutStamp(c), exportWithoutStamp(a));
    });
  });

  group('B1: 取り込んだカードの引落日・締め日が再起動後も残る', () {
    test('カード設定を取り込み、作り直して読み込んでも同じ', () async {
      final src = await fixedApp(now);
      src.cardPaymentDays.addAll({'テストカード': 10});
      src.cardClosingDays['テストカード'] = 15;
      final json = src.exportJson();

      final app = await fixedApp(now, prefs: {}); // 初回起動＝既定のカードが入る
      expect(app.cardPaymentDays, isNotEmpty);
      await app.importJson(json);
      final reloaded = await reloadApp(now);
      expect(reloaded.cardPaymentDays, {'テストカード': 10});
      expect(reloaded.cardClosingDays, {'テストカード': 15});
    });

    test('カードを全部消した空の設定も、取り込み・再起動で既定のカードに戻らない', () async {
      final src = await fixedApp(now);
      src.cardPaymentDays.clear();
      final json = src.exportJson();
      expect(jsonDecode(json)['cardPaymentDays'], isEmpty);

      final app = await fixedApp(now, prefs: {});
      await app.importJson(json);
      final reloaded = await reloadApp(now);
      expect(reloaded.cardPaymentDays, isEmpty);
    });

    test('設定画面でカードを全部外した空の設定も、再起動で戻らない', () async {
      final app = await fixedApp(now, prefs: {});
      for (final c in [...app.cardPaymentDays.keys]) {
        app.removeCard(c);
      }
      await settle();
      final reloaded = await reloadApp(now);
      expect(reloaded.cardPaymentDays, isEmpty);
    });
  });

  group('取り込みの保存の失敗（importJson は保存の完了を待つ）', () {
    test('保存に失敗したら例外を返し、取り込む前の内容に戻す', () async {
      final app = await fixedApp(now);
      app.currentBalance = 1234;
      await app.saveData();
      final before = exportWithoutStamp(app);
      final src = await richApp(now);
      final json = src.exportJson();

      final store = await useFailingStore();
      store.failAfter = store.writes + 3; // 保存の途中で失敗する
      await expectLater(app.importJson(json), throwsA(isA<StateError>()));
      expect(exportWithoutStamp(app), before); // メモリは元の内容
    });
  });

  group('B2: 自己修復でシフトのIDと予定のIDを保つ', () {
    Map<String, Object> legacyPrefs() => {
          'flutter.saved_shifts': jsonEncode({
            '2026-11-03': [
              ShiftData(
                id: 'sh-fixed',
                workplace: 'カフェ',
                hourlyWage: 1000,
                start: DateTime(2026, 11, 3, 10),
                end: DateTime(2026, 11, 3, 15),
                calendarEventId: 'ev-123',
              ).toJson(),
            ],
          }),
        };

    test('勤務先の無いシフトに勤務先を付けても、IDと予定IDは同じ', () async {
      final app = await fixedApp(now, prefs: legacyPrefs());
      final s = app.shifts['2026-11-03']!.single;
      expect(s.id, 'sh-fixed');
      expect(s.calendarEventId, 'ev-123');
      expect(s.workplaceId, isNotNull); // 勤務先は付く（従来どおり）
    });

    test('自己修復を2回走らせても、2回目は何も変えない', () async {
      final app = await fixedApp(now, prefs: legacyPrefs());
      final first = exportWithoutStamp(app);
      expect(app.repairData(), isFalse);
      expect(exportWithoutStamp(app), first);
    });

    test('予定IDが無いシフトに、推測で予定IDを付けない', () async {
      final prefs = {
        'flutter.saved_shifts': jsonEncode({
          '2026-11-04': [
            ShiftData(
              id: 'sh-2',
              workplace: '塾',
              hourlyWage: 1500,
              start: DateTime(2026, 11, 4, 17),
              end: DateTime(2026, 11, 4, 21),
            ).toJson(),
          ],
        }),
      };
      final app = await fixedApp(now, prefs: prefs);
      expect(app.shifts['2026-11-04']!.single.calendarEventId, isNull);
    });
  });

  group('B8: 取り込み時も起動時と同じ自己修復をする', () {
    test('古い名前「三井住友」のカードは取り込み時にも三井OLIVEにまとめる', () async {
      final src = await fixedApp(now);
      src.payments.add(usage('三井住友', 1000, DateTime(2026, 11, 2, 12)));
      final json = src.exportJson();
      final app = await fixedApp(now);
      await app.importJson(json);
      expect(app.payments.single.cardName, '三井OLIVE');
    });

    test('直すものが無ければ、読み込みで保存しない（変更時刻を進めない）', () async {
      final a = await richApp(now);
      await a.saveData();
      final at = a.dataUpdatedAt;
      final b = await reloadApp(now.add(const Duration(days: 1)));
      await settle();
      expect(b.dataUpdatedAt, at);
    });
  });
}
