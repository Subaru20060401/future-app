// バックアップの取り込みは「全部読めたときだけ置き換える」テスト（コード点検 2026-10-22 の指摘）。
// ⚠️ 以前は項目ごとに「消してから読む」ので、後半の項目が壊れていると例外になり、
//   シフトだけ消えた（前半だけ置き換わった）状態が残っていた。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppState> filled() async {
    final app = AppState();
    await app.ready;
    app.addShift(
      DateTime(2026, 10, 5),
      ShiftData(
        workplace: 'カフェ',
        hourlyWage: 1100,
        start: DateTime(2026, 10, 5, 9),
        end: DateTime(2026, 10, 5, 17),
      ),
    );
    app.payments.add(Payment(
      id: 'p1',
      cardName: '楽天カード',
      amount: 5000,
      paymentDate: DateTime(2026, 10, 3),
    ));
    app.currentBalance = 80000;
    return app;
  }

  test('後半の項目が壊れていたら、取り込む前のデータが全部残る', () async {
    final app = await filled();
    final before = app.exportJson();
    // 別の端末のデータ（シフト無し）。ただし明細の日付が壊れている
    final broken = jsonDecode(before) as Map<String, dynamic>;
    broken['shifts'] = {};
    broken['currentBalance'] = 1;
    broken['payments'] = [
      {'id': 'x', 'cardName': 'A', 'amount': 1, 'paymentDate': '日付ではない'}
    ];
    expect(() => app.importJson(jsonEncode(broken)), throwsA(anything));

    expect(app.shifts['2026-10-05'], hasLength(1), reason: 'シフトが消えていない');
    expect(app.payments.map((p) => p.id), ['p1']);
    expect(app.currentBalance, 80000);
    expect(jsonDecode(app.exportJson())..remove('exportedAt'),
        jsonDecode(before)..remove('exportedAt'));
  });

  test('JSONとして読めないときも、何も変わらない', () async {
    final app = await filled();
    expect(() => app.importJson('{壊れた'), throwsA(anything));
    expect(app.shifts['2026-10-05'], hasLength(1));
    expect(app.payments, hasLength(1));
  });

  test('正しいデータなら置き換わる（マージしない）', () async {
    final app = await filled();
    final other = jsonDecode(app.exportJson()) as Map<String, dynamic>;
    other['shifts'] = {};
    other['payments'] = [];
    app.importJson(jsonEncode(other));
    expect(app.shifts, isEmpty);
    expect(app.payments, isEmpty);
  });
}
