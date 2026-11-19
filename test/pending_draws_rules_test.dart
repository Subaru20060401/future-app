// 💡 確認待ちの引き落とし（pendingDraws）: 日付・金額の規則は予想と同じ。
//   ただし確認待ちは予想とは別の状態で、予想のゲート（残高を書いた日）では消えない。
//   消えるのは「引いた」「スキップした」と処理したときだけ。
//   暦: 2026-11-10 火 / 11-30 月 / 10-31 土 → 11-02 月 / 12-27 日 → 12-28 月
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/test_app.dart';

void main() {
  test('口座振替の定期は、休みなら翌営業日（12/27日 → 12/28月）', () async {
    final app = await fixedApp(DateTime(2026, 12, 29, 9));
    app.subscriptions.add(Subscription(id: 's1', title: '家賃', amount: 50000, payDay: 27));
    final d = app.pendingDraws.singleWhere((e) => e.id == 'sub:s1:2026-12');
    expect(d.date, DateTime(2026, 12, 28));
    expect(d.amount, 50000);
  });

  test('締め日が月末以外のカードは、締め期間の利用で見込む（15日締め・10日払い）', () async {
    final app = await fixedApp(DateTime(2026, 11, 12, 9));
    app.cardPaymentDays['三菱'] = 10;
    app.cardClosingDays['三菱'] = 15;
    app.payments.addAll([
      usage('三菱', 7000, DateTime(2026, 10, 14, 12)), // 9/16〜10/15 → 11/10 に落ちる
      usage('三菱', 5000, DateTime(2026, 10, 16, 12)), // 10/16〜 → 12/10 に落ちる
    ]);
    final d = app.pendingDraws.singleWhere((e) => e.id == 'card:三菱:2026-11');
    expect(d.date, DateTime(2026, 11, 10));
    expect(d.amount, 7000); // 以前は暦月（10月）の合計 12,000 を出していた
  });

  test('カードの分割払いも請求に合算して見込む', () async {
    final app = await fixedApp(DateTime(2026, 11, 27, 9));
    app.cardPaymentDays['A'] = 26;
    app.payments.add(usage('A', 4000, DateTime(2026, 10, 5, 12)));
    app.installments.add(Installment(
        id: 'i',
        name: '家電',
        cardName: 'A',
        totalAmount: 6000,
        installmentCount: 3,
        remainingMonths: 3,
        monthlyAmount: 2000,
        startDate: DateTime(2026, 10, 1)));
    final d = app.pendingDraws.singleWhere((e) => e.id == 'card:A:2026-11');
    expect(d.amount, 6000); // 4,000 + 分割 2,000
    // 予想の同じ月の金額と一致する（ゲートの無い状態で比べる）
    expect(app.drawBreakdownOf(DateTime(2026, 11)).singleWhere((e) => e.label == 'A').amount,
        d.amount);
  });

  test('残高を書き直して予想から外れても、確認待ちは処理するまで消えない', () async {
    final app = await fixedApp(DateTime(2026, 11, 27, 9));
    app.cardPaymentDays['A'] = 26;
    app.payments.add(usage('A', 4000, DateTime(2026, 10, 5, 12)));
    app.balanceUpdatedAt = DateTime(2026, 11, 26, 20); // 引落日の後に残高を書いた
    expect(app.drawBreakdownOf(DateTime(2026, 11)), isEmpty); // 予想からは外れる
    expect(app.pendingDraws.map((e) => e.id), contains('card:A:2026-11')); // 確認待ちには残る
    app.skipDraw('card:A:2026-11');
    expect(app.pendingDraws.map((e) => e.id), isNot(contains('card:A:2026-11')));
    // 作り直しても処理済みのまま
    await settle();
    final again = await reloadApp(DateTime(2026, 11, 27, 9));
    expect(again.pendingDraws.map((e) => e.id), isNot(contains('card:A:2026-11')));
  });

  group('休みで翌月にずれた引落（31日払い: 10/31土 → 11/2月）', () {
    Future<AppState> app() async {
      final a = await fixedApp(DateTime(2026, 12, 1, 9));
      a.cardPaymentDays['B'] = 31;
      a.payments.addAll([
        usage('B', 1000, DateTime(2026, 9, 10, 12)), // 10月請求 → 11/2
        usage('B', 2000, DateTime(2026, 10, 10, 12)), // 11月請求 → 11/30
      ]);
      return a;
    }

    test('2つの引落が別々に出る（ID は請求の月）', () async {
      final a = await app();
      final ds = a.pendingDraws.where((e) => e.label == 'B（予定）').toList();
      expect(ds.map((e) => (e.id, e.date, e.amount)), [
        ('card:B:2026-10', DateTime(2026, 11, 2), 1000),
        ('card:B:2026-11', DateTime(2026, 11, 30), 2000),
      ]);
      a.skipDraw('card:B:2026-10');
      expect(a.pendingDraws.map((e) => e.id), ['card:B:2026-11']);
    });

    test('以前のID（引落日の月）で処理済みの、ずれた引落は出さない（以前の記録との互換）', () async {
      final a = await app();
      a.handledDrawIds.add('card:B:2026-11'); // 以前の版で 11/2 の引落を処理した記録
      expect(a.pendingDraws.map((e) => e.id), isNot(contains('card:B:2026-10')));
    });
  });
}
