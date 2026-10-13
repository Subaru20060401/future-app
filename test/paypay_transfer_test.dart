// PayPay残高から銀行への出金（＝口座への入金予定）のテスト。
// 💡 「【PayPay】出金を受け付けました」メールには金額と振込予定日があるので、
//   着金前から予想に入れ、銀行の振込入金通知が来たら金額を埋めて結びつける。
// ⚠️ 本文は実物の形に合わせた架空のもの（支店・名義・口座・取引番号はダミー）。
//   公開リポジトリなので、実際のメールの中身は入れない。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/gmail_service.dart';

// 実物と同じく表の罫線（|）と改行が混ざった本文
String mail({
  String bank = '三井住友銀行',
  String accepted = '2026年10月13日 23時37分8秒',
  String amount = '12000円',
  String? fee,
  String scheduled = '2026年10月15日前後',
  String txn = '00000000000000000001',
}) =>
    ''' 【PayPay】出金を受け付けました

| | 出金を受け付けました | |
| | $bank | |
| | $accepted | |

| | $amount | |
${fee == null ? '' : '| | 手数料 $fee | |\n'}
| | 振込予定日 | |
| | $scheduled | |

| | 振込先 | |
| | 支店名 | テスト支店 | |
| | 口座番号 | 普通*****00 | |
| | 口座名義 | テスト**** | |
| | 取引番号 | $txn | |
| | 支払い方法 | PayPay残高 | |
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('メールの読み取り', () {
    test('金額・振込予定日・受付日時・銀行・取引番号を読む', () {
      final t = parsePayPayTransferText(mail(), messageId: 'm1')!;
      expect(t.amount, 12000);
      expect(t.fee, 0);
      expect(t.scheduledDate, DateTime(2026, 10, 15));
      expect(t.acceptedAt, DateTime(2026, 10, 13, 23, 37, 8));
      expect(t.bank, '三井住友銀行');
      expect(t.id, '00000000000000000001');
    });

    test('手数料つきは差し引いた額にする（予想が多めに出ないように）', () {
      final t = parsePayPayTransferText(mail(amount: '10100円', fee: '100円'), messageId: 'm1')!;
      expect(t.amount, 10000);
      expect(t.fee, 100);
    });

    test('3桁区切りの金額も読める', () {
      final t = parsePayPayTransferText(mail(amount: '12,000円'), messageId: 'm1')!;
      expect(t.amount, 12000);
    });

    test('HTMLだけのメール（項目と値が別のセル）でも読める', () {
      const html = '''<html><head><style>td{font-size:12px;color:#333}</style></head><body>
<table><tr><td>出金を受け付けました</td></tr><tr><td>三井住友銀行</td></tr>
<tr><td>2026年10月13日 23時37分8秒</td></tr><tr><td style="font-size:24px">10,100円</td></tr>
<tr><td>手数料&nbsp;100円</td></tr>
<tr><td>振込予定日</td></tr><tr><td>2026年10月15日前後</td></tr>
<tr><td>取引番号</td><td>00000000000000000002</td></tr></table></body></html>''';
      final t = parsePayPayTransferText(html, messageId: 'm1')!;
      expect(t.amount, 10000);
      expect(t.fee, 100);
      expect(t.scheduledDate, DateTime(2026, 10, 15));
      expect(t.bank, '三井住友銀行');
      expect(t.id, '00000000000000000002');
    });

    test('振込予定日が読めなければ推測で埋めない', () {
      expect(parsePayPayTransferText(mail(scheduled: '未定'), messageId: 'm1'), isNull);
    });

    test('出金のメールでなければ読まない', () {
      expect(parsePayPayTransferText('PayPayクーポンのお知らせ 12000円', messageId: 'm1'), isNull);
    });
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  PayPayTransfer transfer({
    String id = 't1',
    int amount = 12000,
    DateTime? accepted,
    DateTime? scheduled,
    String bank = '三井住友銀行',
  }) =>
      PayPayTransfer(
        id: id,
        amount: amount,
        acceptedAt: accepted ?? today,
        scheduledDate: scheduled ?? today.add(const Duration(days: 2)),
        bank: bank,
      );

  group('予想への反映', () {
    test('振込予定日の月の予想に入り、内訳にも出る', () {
      final app = AppState()..currentBalance = 50000;
      final t = transfer();
      app.addPayPayTransfers([t]);
      final m = DateTime(t.scheduledDate.year, t.scheduledDate.month);
      expect(app.transferForecastIn(m), 12000);
      final breakdown = m.month == now.month ? app.thisMonthBreakdown : app.nextMonthBreakdown;
      expect(breakdown.keys.where((k) => k.startsWith('PayPayからの入金')), hasLength(1));
    });

    test('月末の予想と日付の並び（最低残高）が食い違わない', () {
      final app = AppState()..currentBalance = 50000;
      app.addPayPayTransfers([transfer()]);
      var running = app.effectiveBalance;
      for (final e in app.cashEventsAhead()) {
        running += e.amount;
      }
      expect(running, app.monthAfterNextBalance);
    });

    test('三井住友以外への出金は口座に関係しないので入れない', () {
      final app = AppState()..addPayPayTransfers([transfer(bank: 'ゆうちょ銀行')]);
      expect(app.paypayTransfers, isEmpty);
    });

    test('同じ取引番号は1件として扱う（取り込み直しても増えない）', () {
      final app = AppState()
        ..addPayPayTransfers([transfer()])
        ..addPayPayTransfers([transfer()]);
      expect(app.paypayTransfers, hasLength(1));
    });

    test('残高を書いた日より前に振り込まれる予定なら、もう残高に入っているので足さない', () {
      final app = AppState()..addPayPayTransfers([transfer(scheduled: today)]);
      app.updateBalance(62000); // 今日、通帳を見て書いた（入金済み）
      expect(app.transferForecastIn(DateTime(now.year, now.month)), 0);
    });
  });

  group('銀行の振込入金通知と結びつける', () {
    AppState withNotice({DateTime? noticeDate}) {
      final app = AppState()..currentBalance = 50000;
      app.addPayPayTransfers([transfer()]);
      app.pendingDeposits.add(DepositNotice(
          sourceId: 'dep1', date: noticeDate ?? today.add(const Duration(days: 2))));
      return app;
    }

    test('受付日〜予定日の3日後までに届いた入金通知は、その出金の着金と見る', () {
      final app = withNotice();
      final n = app.pendingDeposits.single;
      expect(app.transferForDeposit(n)?.id, 't1');
      // ホームの確認待ちにも金額つきで出る
      final notice = app.homeNotices.single;
      expect(notice.title, 'PayPayからの入金');
      expect(notice.amount, 12000);
    });

    test('離れた日の入金通知は結びつけない（別の入金かもしれない）', () {
      final app = withNotice(noticeDate: today.add(const Duration(days: 10)));
      expect(app.transferForDeposit(app.pendingDeposits.single), isNull);
    });

    test('結びつけて反映すると、残高に入り、予想からは外れる（二重に足さない）', () {
      final app = withNotice(noticeDate: today); // 予定日より早く着金した
      final t = app.transferForDeposit(app.pendingDeposits.single)!;
      final before = app.monthAfterNextBalance;
      app.applyDepositNotice('dep1', t.amount, transferId: t.id);
      expect(app.currentBalance, 62000);
      expect(app.pendingTransfers, isEmpty);
      expect(app.monthAfterNextBalance, before, reason: '予想の合計は変わらない（入る場所が残高に移っただけ）');
      expect(app.balanceHistory.first.label, 'PayPayからの入金');
    });

    test('反映を取り消すと、出金は未着に戻って予想に入る', () {
      final app = withNotice(noticeDate: today);
      final t = app.transferForDeposit(app.pendingDeposits.single)!;
      app.applyDepositNotice('dep1', t.amount, transferId: t.id);
      app.undoBalanceEntry(app.balanceHistory.first.id);
      expect(app.pendingTransfers.single.id, 't1');
    });
  });

  test('書き出し・取り込みで保たれる（ドライブ同期でも消えない）', () {
    final app = AppState()..addPayPayTransfers([transfer(), transfer(id: 't2')]);
    app.pendingDeposits.add(DepositNotice(sourceId: 'dep1', date: today));
    app.applyDepositNotice('dep1', 12000, transferId: 't1');
    final restored = AppState()..importJson(app.exportJson());
    expect(restored.paypayTransfers.map((e) => e.id), containsAll(['t1', 't2']));
    expect(restored.pendingTransfers.map((e) => e.id).toList(), ['t2']);
  });
}
