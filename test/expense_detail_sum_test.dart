// 💡 月ごとの支出詳細: 内訳（expenseDetailOf）を足すと、一覧の金額（expenseBreakdownOf）に一致する。
//   以前はカード払いのローン・頭金が合計にだけ入り、内訳に出ていなかった（B5）。
import 'package:flutter_test/flutter_test.dart';

import 'support/rich_fixture.dart';

void main() {
  for (final clock in [DateTime(2026, 11, 19, 10), DateTime(2027, 1, 30, 10)]) {
    test('内訳の合計が一覧の金額と一致する（$clock の前後の月）', () async {
      final app = await richApp(clock);
      for (var i = -2; i <= 2; i++) {
        final m = DateTime(clock.year, clock.month + i);
        for (final e in app.expenseBreakdownOf(m)) {
          final detail = app.expenseDetailOf(m, e.label);
          final sum = detail.fold<int>(0, (s, d) => s + d.amount);
          expect(sum, e.amount, reason: '${m.year}/${m.month} ${e.label}: $detail');
        }
      }
    });
  }
}
