// シフトの入力フォーム（追加と編集で共通）のテスト（コード点検 2026-10-22 の指摘）。
// ⚠️ 以前は追加と編集に同じフォームが別々にあり、編集では勤務先を変えても時給が入れ替わらなかった。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/widgets/add_entry_sheets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final day = DateTime(2026, 11, 5);

  Future<AppState> open(WidgetTester t, {ShiftData? initial, required void Function(ShiftData) onSave}) async {
    final app = AppState();
    await app.ready;
    app.workplaces.addAll([
      Workplace(id: 'w1', name: 'カフェ', wagePeriods: [WagePeriod(hourlyWage: 1100)]),
      Workplace(id: 'w2', name: '本屋', wagePeriods: [WagePeriod(hourlyWage: 1300, transportPerDay: 200)]),
    ]);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showShiftFormDialog(context, app, day,
                title: initial == null ? 'シフト入力' : 'シフトを編集', initial: initial, onSave: onSave),
            child: const Text('開く'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('開く'));
    await t.pumpAndSettle();
    return app;
  }

  testWidgets('新規は先頭の勤務先の時給から始まる', (t) async {
    ShiftData? saved;
    await open(t, onSave: (s) => saved = s);
    expect(find.widgetWithText(TextField, '1100'), findsOneWidget);
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(saved!.workplaceId, 'w1');
    expect(saved!.hourlyWage, 1100);
    expect(saved!.start, DateTime(2026, 11, 5, 9));
    expect(saved!.breakMinutes, 60);
  });

  testWidgets('編集は保存してある値から始まり、勤務先を変えたら時給と手当も入れ替わる', (t) async {
    final initial = ShiftData(
      workplace: 'カフェ',
      workplaceId: 'w1',
      hourlyWage: 1050, // 当時の時給（今の設定とは違う）
      start: DateTime(2026, 11, 5, 18),
      end: DateTime(2026, 11, 5, 22),
      breakMinutes: 15,
    );
    ShiftData? saved;
    await open(t, initial: initial, onSave: (s) => saved = s);
    expect(find.text('シフトを編集'), findsOneWidget);
    expect(find.widgetWithText(TextField, '1050'), findsOneWidget, reason: '開いただけでは時給を変えない');
    expect(find.widgetWithText(TextField, '15'), findsOneWidget);

    await t.tap(find.text('カフェ'));
    await t.pumpAndSettle();
    await t.tap(find.text('本屋').last);
    await t.pumpAndSettle();
    expect(find.widgetWithText(TextField, '1300'), findsOneWidget);

    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(saved!.workplaceId, 'w2');
    expect(saved!.hourlyWage, 1300);
    expect(saved!.transportPerDay, 200);
    expect(saved!.start, DateTime(2026, 11, 5, 18));
    expect(saved!.end, DateTime(2026, 11, 5, 22));
    expect(saved!.breakMinutes, 15);
  });
}
