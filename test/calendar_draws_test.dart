// 💡 カレンダーの引き落とし（公開前の確認 4）: 請求額と実際の引落日は予想と同じ。
//   ただし予想の除外（残高を書いた日より前）はカレンダーには使わない。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/app_state.dart';

import 'support/rich_fixture.dart';

void main() {
  Map<String, (int, bool)> on(AppState a, DateTime d) => {
        for (final s in a.cardPaymentSummaryOnDay(d)) s.cardName: (s.amount, s.isConfirmed),
      };

  test('予想と同じ額・同じ日（締め期間・分割の合算・休みでずれた引落）', () async {
    final a = await richApp(DateTime(2026, 11, 1, 10));
    // 10/31(土) からずれた月末払いカードの10月請求（9月利用 6,000）
    expect(on(a, DateTime(2026, 11, 2))['月末払いカード'], (6000, false));
    // 15日締め・10日払いの三菱: 9/16〜10/15 の利用 7,000（以前は暦月の 12,000）
    expect(on(a, DateTime(2026, 11, 10))['三菱カード'], (7000, false));
    // 楽天: 10月利用 8,900 ＋ 分割 20,500（以前は 8,900）
    expect(on(a, DateTime(2026, 11, 27))['楽天カード'], (29400, false));
    // 三井OLIVE: 銀行確定 15,000（確定の日付）
    expect(on(a, DateTime(2026, 11, 26))['三井OLIVE'], (15000, true));
    // 予想の行と一致する
    final lines = a.forecastMonths(count: 1).first.lines;
    for (final (d, card) in [
      (DateTime(2026, 11, 2), '月末払いカード'),
      (DateTime(2026, 11, 10), '三菱カード'),
      (DateTime(2026, 11, 27), '楽天カード'),
      (DateTime(2026, 11, 26), '三井OLIVE'),
    ]) {
      final l = lines.singleWhere((l) => l.label == card && l.date == d);
      expect(on(a, d)[card]!.$1, -l.amount, reason: '$card $d');
    }
  });

  test('残高を書いた日より前の引落もカレンダーには残す（予想からは外れても）', () async {
    final a = await richApp(DateTime(2026, 11, 28, 10));
    a.balanceUpdatedAt = DateTime(2026, 11, 28, 9); // 11/27 の楽天は予想から外れる
    expect(a.forecastMonths(count: 1).first.lines.any((l) => l.label == '楽天カード' && l.date.day == 27),
        isFalse);
    expect(on(a, DateTime(2026, 11, 27))['楽天カード'], (29400, false));
  });

  test('月をまたぐ銀行確定は、ずれた先の日に確定として出し、翌月の請求は月末に残す', () async {
    final a = await richApp(DateTime(2026, 11, 3, 10));
    a.payments.add(Payment(
      id: 'bk',
      cardName: '月末払いカード',
      amount: 6100,
      paymentDate: DateTime(2026, 11, 2),
      source: PaymentSource.bank,
      sourceId: 'bank-matsu-1102',
    ));
    expect(on(a, DateTime(2026, 11, 2))['月末払いカード'], (6100, true));
    expect(on(a, DateTime(2026, 11, 30))['月末払いカード'], (7000, false));
  });
}
