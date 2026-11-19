// 💡 ホーム画面: 幅（スマートフォン 320/390・PC 1280）と文字の拡大（1.3 倍）で崩れない・はみ出さないこと、
//   残高・見込み・根拠・次の引き落とし・確定／見込みが文字で読めること。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/drive_sync.dart';
import 'package:my_counter_app/screens/income_screen.dart';

import 'support/rich_fixture.dart';

Future<AppState> _pump(WidgetTester tester, Size size, {double textScale = 1.0}) async {
  await initializeDateFormatting('ja_JP');
  late AppState app;
  await tester.runAsync(() async => app = await richApp(DateTime(2026, 11, 19, 10)));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: app,
    child: MaterialApp(
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const IncomeScreen(),
    ),
  ));
  await tester.pump(const Duration(seconds: 2)); // 金額の動き（AnimatedAmount）を終わらせる
  return app;
}

void main() {
  for (final size in const [Size(320, 720), Size(390, 844), Size(1280, 900)]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('はみ出さない（幅${size.width.toInt()}・文字$scale倍）', (tester) async {
        await _pump(tester, size, textScale: scale);
        expect(tester.takeException(), isNull);
        // 下までスクロールしても例外が出ない
        final scrollable = find.byType(Scrollable).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(scrollable, const Offset(0, -500));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
      });
    }
  }

  testWidgets('残高・いつの残高か・月末の見込みが読める', (tester) async {
    final app = await _pump(tester, const Size(390, 844));
    expect(find.text('いまの残高'), findsOneWidget);
    expect(find.textContaining('10/28 に入力（22日前）'), findsOneWidget);
    expect(find.text('月末の見込み'), findsOneWidget);
    expect(find.text('11月末'), findsWidgets);
    // 残高を22日書き直していないので、注意が出る
    expect(find.text('残高を22日間書き直していません'), findsOneWidget);
    expect(app.thisMonthBalance, isNot(0));
  });

  testWidgets('根拠シート: 確定／見込みが文字で出て、最後が月末の金額', (tester) async {
    final app = await _pump(tester, const Size(390, 844));
    await tester.tap(find.text('根拠を見る ›'));
    await tester.pumpAndSettle();
    expect(find.text('11月末の見込みの根拠'), findsOneWidget);
    expect(find.text('確定'), findsWidgets); // 三井OLIVE は銀行確定
    expect(find.text('見込み'), findsWidgets);
    expect(find.text('= 11月末の見込み'), findsOneWidget);
    expect(app.forecastMonths().first.end, app.thisMonthBalance);
  });

  testWidgets('次の引き落としと、お金の操作（以前の項目が残っている）', (tester) async {
    await _pump(tester, const Size(1280, 900)); // 2列なので全部が1画面に入りやすい
    expect(find.text('次の引き落とし'), findsOneWidget);
    for (final label in ['口座に入金', '予定の入金', '予定の支出', '入出金の履歴', '財布の現金']) {
      expect(find.textContaining(label), findsWidgets, reason: label);
    }
    expect(find.textContaining('引き落としを反映'), findsOneWidget);
    expect(find.textContaining('収支の内訳'), findsOneWidget);
  });

  testWidgets('ドライブ同期が競合していたら、選ぶボタンつきで知らせる', (tester) async {
    final app = await _pump(tester, const Size(390, 844));
    await tester.runAsync(() => app.setDriveSyncEnabled(true));
    lastDriveSyncState.value = DriveSyncState.conflict;
    addTearDown(() => lastDriveSyncState.value = null);
    await tester.pump();
    expect(find.text('この端末と別の端末の両方でデータが変わっています'), findsOneWidget);
    expect(find.text('選ぶ'), findsOneWidget);
    lastDriveSyncState.value = DriveSyncState.upToDate;
    await tester.pump();
    expect(find.text('選ぶ'), findsNothing);
  });
}
