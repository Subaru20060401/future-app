// 定期支払いを、1件ずつの支払日で予想に入れるテスト（2026-11-20 本人の画面で「定期が含まれてない」）。
// ⚠️ 以前は定期をまとめて1行（「定期支払い」）にし、その行の日付を「いちばん早い支払日」にしていた。
//   残高を書き直した日より前にその日が来ていると、まだ落ちていない月末の定期まで丸ごと予想から消えていた。
//   例：5日払いと27日払いがあり、15日に残高を書き直すと、27日の分も消える。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final now = DateTime.now();
  final thisMonth = DateTime(now.year, now.month);

  Future<AppState> app() async {
    final a = AppState();
    await a.ready;
    a.currentBalance = 100000;
    // 今月15日に残高を書き直した（5日の定期はもう残高に入っている）
    a.balanceUpdatedAt = DateTime(now.year, now.month, 15, 12);
    a.addSubscription(title: '早い定期', amount: 1000, payDay: 5);
    a.addSubscription(title: '遅い定期', amount: 2000, payDay: 27);
    return a;
  }

  int subsLine(AppState a) => a
      .drawBreakdownOf(thisMonth)
      .where((e) => e.label == '定期支払い')
      .fold(0, (s, e) => s + e.amount);

  test('まだ来ていない定期だけ引く（もう過ぎた定期は残高に入っているので引かない）', () async {
    final a = await app();
    expect(subsLine(a), 2000);
    expect(a.thisMonthBreakdown['定期支払い'], -2000);
  });

  test('全部まだ来ていなければ、全部引く', () async {
    final a = await app();
    a.balanceUpdatedAt = DateTime(now.year, now.month, 1, 0);
    a.subscriptions.first.payDay = 3;
    expect(subsLine(a), 3000);
  });

  test('全部もう過ぎていれば、引かない', () async {
    final a = await app();
    a.balanceUpdatedAt = DateTime(now.year, now.month, 28, 23);
    a.subscriptions.last.payDay = 20;
    expect(subsLine(a), 0);
    expect(a.thisMonthBreakdown.containsKey('定期支払い'), isFalse);
  });

  test('カード払いの定期は、そのカードの引き落とし日で判断する', () async {
    final a = await app();
    a.cardPaymentDays['テストカード'] = 27;
    // 支払日は3日だが、カードの請求として27日に落ちる
    a.addSubscription(title: 'カードの定期', amount: 500, payDay: 3, method: 'テストカード');
    expect(subsLine(a), 2500);
  });

  test('日ごとの残高でも、定期はそれぞれの支払日に置く', () async {
    final a = await app();
    final events = a.cashEventsAhead(monthsAhead: 0).where((e) => e.label.contains('定期')).toList();
    expect(events.map((e) => e.amount), [-2000]);
    expect(events.single.date.day, greaterThanOrEqualTo(27), reason: '27日（休みなら翌営業日）');
  });
}
