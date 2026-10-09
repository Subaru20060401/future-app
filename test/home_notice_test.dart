// ホームの「確認待ち」と、入金前に確認すべき引き落としのテスト。
// ⚠️ 起動時のダイアログをやめてホームの一覧にしたので、未処理の引き落としが
//   残りやすくなった。その状態で入金を反映すると基準日が進み、日付の過ぎた
//   引き落としが予想から抜ける。入金の前に必ず気づけることを固定する。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final lastWeek = today.subtract(const Duration(days: 7));

  // 銀行の引き落とし事前お知らせ（日付が過ぎたもの＝反映待ちになる）
  Payment bankDraw(String card, int amount, DateTime d) => Payment(
        id: 'b_$card${d.day}',
        cardName: card,
        amount: amount,
        paymentDate: d,
        source: PaymentSource.bank,
        sourceId: 'mail_$card${d.day}',
      );

  group('確認待ちの並び', () {
    test('何も無ければ空', () {
      expect(AppState().homeNotices, isEmpty);
    });

    test('引き落としを入金より先に出す（先に反映しないと予想から抜けるため）', () {
      final app = AppState();
      app.pendingDeposits.add(DepositNotice(sourceId: 'dep1', date: lastWeek));
      app.payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      final kinds = app.homeNotices.map((e) => e.kind).toList();
      expect(kinds, [HomeNoticeKind.draw, HomeNoticeKind.deposit]);
    });

    test('引き落としの金額と日付が出る', () {
      final app = AppState()..payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      final n = app.homeNotices.single;
      expect(n.amount, 30000);
      expect(n.date, yesterday);
      expect(n.draw, isNotNull);
    });

    test('反映・スキップしたものは出ない', () {
      final app = AppState()..payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      final id = app.homeNotices.single.draw!.id;
      app.skipDraw(id);
      expect(app.homeNotices, isEmpty);
    });

    test('カード未設定の分割払いがあれば、設定を促す', () {
      final app = AppState();
      app.installments.add(Installment(
        id: 'i1',
        name: 'PC',
        cardName: '',
        totalAmount: 60000,
        installmentCount: 6,
        remainingMonths: 6,
        monthlyAmount: 10000,
        interestRate: 0,
        startDate: DateTime(now.year, now.month),
      ));
      expect(app.homeNotices.single.kind, HomeNoticeKind.installmentWithoutCard);
    });
  });

  group('今日・直近の予定', () {
    final base = DateTime(2026, 10, 10, 12, 0); // 10/10 正午を「今」とする
    String key(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    ShiftData shift(DateTime s, DateTime e) =>
        ShiftData(workplace: 'カフェ', hourlyWage: 1100, start: s, end: e);

    test('シフトと予定を時刻順にまとめ、終わったものは出さない', () {
      final app = AppState();
      final d10 = DateTime(2026, 10, 10);
      app.shifts[key(d10)] = [
        shift(DateTime(2026, 10, 10, 8), DateTime(2026, 10, 10, 11)), // 終わった
        shift(DateTime(2026, 10, 10, 15), DateTime(2026, 10, 10, 18)),
      ];
      app.events[key(d10)] = [
        EventData(id: 'e1', title: '説明会', start: DateTime(2026, 10, 10, 13), end: DateTime(2026, 10, 10, 14)),
      ];
      final list = app.upcomingSchedule(from: base);
      expect(list.map((e) => e.title).toList(), ['説明会', 'カフェ']);
      expect(list.last.isShift, isTrue);
    });

    test('終日の予定はその日の先頭に来る', () {
      final app = AppState();
      final d11 = DateTime(2026, 10, 11);
      app.shifts[key(d11)] = [shift(DateTime(2026, 10, 11, 9), DateTime(2026, 10, 11, 12))];
      app.events[key(d11)] = [EventData(id: 'e2', title: '誕生日', allDay: true)];
      final list = app.upcomingSchedule(from: base);
      expect(list.map((e) => e.title).toList(), ['誕生日', 'カフェ']);
      expect(list.first.allDay, isTrue);
    });

    test('指定した日数より先は出さない', () {
      final app = AppState();
      final far = DateTime(2026, 10, 20);
      app.shifts[key(far)] = [shift(DateTime(2026, 10, 20, 9), DateTime(2026, 10, 20, 12))];
      expect(app.upcomingSchedule(from: base, days: 3), isEmpty);
    });
  });

  group('入金の前に確認すべき引き落とし', () {
    test('基準日より後の未処理の引き落としは、入金で予想から抜けるので警告対象', () {
      final app = AppState();
      app.balanceUpdatedAt = lastWeek; // 先週に残高を書いた
      app.payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      expect(app.drawsAtRiskOnSnapshotAdvance, hasLength(1));
    });

    test('実際に、そのまま入金を反映すると予想から抜ける（だから先に聞く）', () {
      final app = AppState()..setCardPaymentDay('三井OLIVE', 26);
      app.balanceUpdatedAt = lastWeek;
      app.payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      final before = app.drawsAtRiskOnSnapshotAdvance.length;
      app.addDeposit(1000); // 基準日が今日に進む
      expect(before, 1);
      // 引き落としは「反映待ち」に残るが、予想の基準日より前になった
      expect(app.pendingDraws, hasLength(1));
      expect(app.drawsAtRiskOnSnapshotAdvance, isEmpty);
    });

    test('先に引き落としを反映すれば、警告対象は無くなる', () {
      final app = AppState();
      app.balanceUpdatedAt = lastWeek;
      app.payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      final d = app.drawsAtRiskOnSnapshotAdvance.single;
      app.applyDraw(d.id, d.amount, label: d.label);
      expect(app.drawsAtRiskOnSnapshotAdvance, isEmpty);
      expect(app.homeNotices, isEmpty);
    });

    test('基準日より前の引き落としは、もう予想に入っていないので対象外', () {
      final app = AppState();
      app.balanceUpdatedAt = today; // 今日、通帳を見て残高を書いた
      app.payments.add(bankDraw('三井OLIVE', 30000, yesterday));
      expect(app.drawsAtRiskOnSnapshotAdvance, isEmpty);
      // ただし未処理としては残る（スキップしてもらう）
      expect(app.homeNotices.single.kind, HomeNoticeKind.draw);
    });
  });
}
