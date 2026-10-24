// メールから見つけた予定の提案のテスト（計画書 docs/mail-schedule-proposal-plan-2026-10-25.md の段階B・C）。
// ⚠️ 守ること:
//   ・承認するまで、予定・シフト・収入・残高に何も入れない
//   ・承認をやり直しても（途中で落ちても）二重に登録しない
//   ・シフトの給与は勤務先の設定で計算する。休憩不明を0分にしない
//   ・変更・取消は登録済みのものにだけ当てる。取り消した予約を再通知で復活させない
// 💡 データはすべて架空。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/mail_schedule_review_sheet.dart';

ScheduleSuggestion sg({
  String id = 'a:m1#R1',
  String entity = 'R1',
  SuggestionKind kind = SuggestionKind.event,
  SuggestionAction action = SuggestionAction.add,
  DateTime? start,
  DateTime? end,
  String title = 'テスト説明会',
}) =>
    ScheduleSuggestion(
      id: id,
      accountKey: 'acct',
      messageId: id.split('#').first,
      entityKey: entity,
      kind: kind,
      action: action,
      title: title,
      start: start ?? DateTime(2026, 11, 12, 14),
      end: end ?? DateTime(2026, 11, 12, 15, 30),
      evidence: '「ご予約が確定しました」',
      sender: 'テスト株式会社',
      receivedAt: DateTime(2026, 11, 1, 9),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> app() async {
    final a = AppState();
    await a.ready;
    a.workplaces.add(Workplace(
      id: 'w1',
      name: 'テスト派遣',
      paydayMonthOffset: 1,
      wagePeriods: [WagePeriod(hourlyWage: 1200, transportPerDay: 500)],
    ));
    return a;
  }

  int eventCount(AppState a) => a.events.values.fold(0, (n, l) => n + l.length);
  int shiftCount(AppState a) => a.shifts.values.fold(0, (n, l) => n + l.length);

  group('承認するまで何も変わらない', () {
    test('提案を受け取っても、予定・シフト・収入は増えない', () async {
      final a = await app();
      final before = a.incomeArrivingIn(DateTime(2026, 12));
      a.addScheduleSuggestions([
        sg(),
        sg(id: 'a:m2#G1', entity: 'G1', kind: SuggestionKind.shift,
            start: DateTime(2026, 11, 20, 9), end: DateTime(2026, 11, 20, 17)),
      ]);
      expect(eventCount(a), 0);
      expect(shiftCount(a), 0);
      expect(a.incomeArrivingIn(DateTime(2026, 12)), before);
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.scheduleSuggestion), hasLength(2));
    });

    test('同じ提案を何度受け取っても1件', () async {
      final a = await app();
      expect(a.addScheduleSuggestions([sg()]), 1);
      expect(a.addScheduleSuggestions([sg(title: 'テスト説明会（会場変更前）')]), 0);
      expect(a.scheduleSuggestions, hasLength(1));
      expect(a.scheduleSuggestions.single.version, 2, reason: '中身が新しくなったら版を上げる');
    });
  });

  group('予定として登録', () {
    test('登録すると予定が1件でき、提案は登録済みになる', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      expect(a.approveScheduleSuggestion('a:m1#R1'), isNull);
      expect(eventCount(a), 1);
      final e = a.events['2026-11-12']!.single;
      expect(e.id, mailTargetId('acct', 'R1'));
      expect(e.title, 'テスト説明会');
      expect(e.memo, contains('テスト株式会社'));
      expect(a.scheduleSuggestions.single.status, SuggestionStatus.approved);
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.scheduleSuggestion), isEmpty);
    });

    test('承認をやり直しても（途中で落ちたときなど）二重にならない', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      a.approveScheduleSuggestion('a:m1#R1');
      // 保存の途中で落ちて、提案だけ確認待ちに戻った状態を作る
      a.scheduleSuggestions.single.status = SuggestionStatus.pending;
      expect(a.approveScheduleSuggestion('a:m1#R1'), isNull);
      expect(eventCount(a), 1);
    });

    test('処理済みの提案はもう一度承認できない。同じ通知が来ても再提案しない', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      a.rejectScheduleSuggestion('a:m1#R1');
      expect(a.approveScheduleSuggestion('a:m1#R1'), isNotNull);
      a.addScheduleSuggestions([sg()]);
      expect(a.scheduleSuggestions.single.status, SuggestionStatus.rejected);
      expect(eventCount(a), 0);
    });

    test('終了時刻が無い時間指定の予定は、補うまで登録しない（1時間と決めつけない）', () async {
      final a = await app();
      final s = sg()..end = null;
      a.addScheduleSuggestions([s]);
      expect(a.approveScheduleSuggestion(s.id), contains('終了時刻'));
      expect(eventCount(a), 0);
      a.editScheduleSuggestion(s.id,
          title: s.title, start: s.start, end: null, allDay: true, location: '');
      expect(a.approveScheduleSuggestion(s.id), isNull, reason: '終日にすれば登録できる');
    });
  });

  group('シフトとして登録', () {
    final start = DateTime(2026, 11, 20, 9);
    final end = DateTime(2026, 11, 20, 17);
    ScheduleSuggestion gig() =>
        sg(id: 'a:m2#G1', entity: 'G1', kind: SuggestionKind.shift, start: start, end: end,
            title: '単発：設営');

    test('勤務先と休憩が無いと登録しない（休憩を0分と決めつけない）', () async {
      final a = await app();
      a.addScheduleSuggestions([gig()]);
      expect(a.approveScheduleSuggestion('a:m2#G1'), contains('勤務先'));
      expect(a.approveScheduleSuggestion('a:m2#G1', workplaceId: 'w1'), contains('休憩'));
      expect(shiftCount(a), 0);
    });

    test('給与は勤務先の設定で計算する', () async {
      final a = await app();
      a.addScheduleSuggestions([gig()]);
      expect(a.approveScheduleSuggestion('a:m2#G1', workplaceId: 'w1', breakMinutes: 60), isNull);
      final s = a.shifts['2026-11-20']!.single;
      expect(s.id, mailTargetId('acct', 'G1'));
      expect(s.hourlyWage, 1200);
      expect(s.transportPerDay, 500);
      expect(s.breakMinutes, 60);
      expect(s.earnings, 1200 * 7 + 500);
    });

    test('勤務時間の変更は同じシフトを動かし、取消はそのシフトだけ消す', () async {
      final a = await app();
      a.addShift(DateTime(2026, 11, 20),
          a.buildShiftFromWorkplace(a.workplaces.single, DateTime(2026, 11, 20),
              DateTime(2026, 11, 20, 18), DateTime(2026, 11, 20, 21)));
      a.addScheduleSuggestions([gig()]);
      a.approveScheduleSuggestion('a:m2#G1', workplaceId: 'w1', breakMinutes: 60);
      final id = mailTargetId('acct', 'G1');

      // 日付が変わる変更
      a.addScheduleSuggestions([
        sg(id: 'a:m3#G1', entity: 'G1', kind: SuggestionKind.shift,
            action: SuggestionAction.change,
            start: DateTime(2026, 11, 21, 10), end: DateTime(2026, 11, 21, 16), title: '単発：設営'),
      ]);
      expect(a.approveScheduleSuggestion('a:m3#G1'), isNull);
      expect(a.shifts['2026-11-20'], hasLength(1), reason: '元からあった自分のシフトは残る');
      final moved = a.shifts['2026-11-21']!.single;
      expect(moved.id, id);
      expect(moved.breakMinutes, 60, reason: '休憩は登録したときの値を引き継ぐ');

      // 取消
      a.addScheduleSuggestions([
        sg(id: 'a:m4#G1', entity: 'G1', kind: SuggestionKind.shift,
            action: SuggestionAction.cancel, title: '単発：設営'),
      ]);
      expect(a.approveScheduleSuggestion('a:m4#G1'), isNull);
      expect(a.shifts.containsKey('2026-11-21'), isFalse);
      expect(a.shifts['2026-11-20'], hasLength(1));

      // 取り消した予約の「追加」が再送されても復活させない
      a.addScheduleSuggestions([gig()..status = SuggestionStatus.pending]);
      expect(a.scheduleSuggestions.where((s) => s.isOpen), isEmpty);
    });

    test('元の予定を登録していない変更・取消は何もしない', () async {
      final a = await app();
      a.addScheduleSuggestions([
        sg(id: 'a:m9#X', entity: 'X', action: SuggestionAction.cancel),
      ]);
      expect(a.approveScheduleSuggestion('a:m9#X'), contains('見つかりません'));
      expect(a.scheduleSuggestions.single.isOpen, isTrue);
    });
  });

  group('保存', () {
    test('保留はホームに出さず、確認待ちに戻せる', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      a.holdScheduleSuggestion('a:m1#R1');
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.scheduleSuggestion), isEmpty);
      a.reopenScheduleSuggestion('a:m1#R1');
      expect(a.homeNotices.where((n) => n.kind == HomeNoticeKind.scheduleSuggestion), hasLength(1));
    });

    test('取消・変更の提案は、新しい予定の提案より先に出す', () async {
      final a = await app();
      a.addScheduleSuggestions([
        sg(id: 'a:m1#R1', entity: 'R1', start: DateTime(2026, 11, 1, 10), end: DateTime(2026, 11, 1, 11)),
        sg(id: 'a:m5#R5', entity: 'R5', action: SuggestionAction.cancel, start: DateTime(2026, 12, 1, 10)),
      ]);
      expect(a.pendingScheduleSuggestions.first.action, SuggestionAction.cancel);
    });

    test('提案と対応関係は、書き出し→取り込みでも残る（置き換え）', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      a.approveScheduleSuggestion('a:m1#R1');
      final json = a.exportJson();
      final b = await app();
      b.importJson(json);
      expect(b.scheduleSuggestions.single.status, SuggestionStatus.approved);
      expect(b.mailEntityLinks.values.single.targetRef, 'event:${mailTargetId('acct', 'R1')}');
      // 同じ予約の再通知は、取り込んだ先でも再提案しない
      b.addScheduleSuggestions([sg()]);
      expect(b.scheduleSuggestions.where((s) => s.isOpen), isEmpty);
    });

    test('アプリを開き直しても提案と対応関係が残る', () async {
      final a = await app();
      a.addScheduleSuggestions([sg()]);
      a.approveScheduleSuggestion('a:m1#R1');
      await a.saveData();
      final b = AppState();
      await b.ready;
      expect(b.scheduleSuggestions.single.status, SuggestionStatus.approved);
      expect(b.mailEntityLinks, hasLength(1));
    });
  });

  group('シフトの固定ID', () {
    test('IDの無い旧データは読み込み時に採番して保存し、次も同じIDになる', () async {
      SharedPreferences.setMockInitialValues({
        'saved_shifts': jsonEncode({
          '2026-11-03': [
            {
              'workplace': 'カフェ',
              'hourlyWage': 1100,
              'start': '2026-11-03T09:00:00.000',
              'end': '2026-11-03T13:00:00.000',
            }
          ]
        }),
      });
      final a = AppState();
      await a.ready;
      final id = a.shifts['2026-11-03']!.single.id;
      expect(id, startsWith('sh-'));
      await Future<void>.delayed(const Duration(milliseconds: 50)); // 自己修復の保存を待つ
      final b = AppState();
      await b.ready;
      expect(b.shifts['2026-11-03']!.single.id, id);
    });

    test('シフトを編集してもIDは変わらない', () async {
      final a = await app();
      final s = ShiftData(
          workplace: 'カフェ', hourlyWage: 1100,
          start: DateTime(2026, 11, 3, 9), end: DateTime(2026, 11, 3, 13));
      a.addShift(DateTime(2026, 11, 3), s);
      final id = s.id;
      a.updateShift('2026-11-03', 0, ShiftData(
          workplace: 'カフェ', hourlyWage: 1200,
          start: DateTime(2026, 11, 3, 10), end: DateTime(2026, 11, 3, 14)));
      expect(a.shifts['2026-11-03']!.single.id, id);
    });
  });

  testWidgets('確認画面（狭い画面）：シフトは休憩を入れるまで登録できない', (t) async {
    await initializeDateFormatting('ja_JP', null);
    t.view.physicalSize = const Size(320, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final a = await app();
    a.addScheduleSuggestions(sampleScheduleSuggestions(DateTime(2026, 11, 1)));
    final gigSg = a.scheduleSuggestions.firstWhere((s) => s.kind == SuggestionKind.shift);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showSuggestionReviewSheet(context, a, gigSg),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: '320pxでもはみ出さない');
    expect(find.textContaining('休憩時間が書かれていません'), findsOneWidget);

    await t.ensureVisible(find.widgetWithText(FilledButton, 'シフトとして登録'));
    await t.tap(find.widgetWithText(FilledButton, 'シフトとして登録'));
    await t.pumpAndSettle();
    expect(find.text('休憩時間を入れてください'), findsOneWidget);
    expect(shiftCount(a), 0);

    await t.enterText(find.widgetWithText(TextField, '休憩（分）'), '45');
    await t.ensureVisible(find.widgetWithText(FilledButton, 'シフトとして登録'));
    await t.tap(find.widgetWithText(FilledButton, 'シフトとして登録'));
    await t.pumpAndSettle();
    expect(shiftCount(a), 1);
    expect(a.shifts.values.single.single.breakMinutes, 45);
    expect(find.text('シフトに登録しました'), findsOneWidget);
  });
}
