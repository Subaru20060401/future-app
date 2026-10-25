// 💡 実メールは使わず、狭い画面・文字拡大・操作の取り消しを検証する。
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/screens/mail_schedule_screen.dart';

ScheduleSuggestion sample(
  String id, {
  SuggestionStatus status = SuggestionStatus.pending,
}) => ScheduleSuggestion(
  id: id,
  accountKey: 'test',
  messageId: id,
  entityKey: id,
  kind: SuggestionKind.event,
  title: '仕事体験参加者向け オンライン会社説明会',
  start: DateTime(2026, 11, 2, 10),
  end: DateTime(2026, 11, 2, 11, 30),
  location: 'オンライン（参加URLは詳細に記載）',
  sender: 'サンプル株式会社 採用担当',
  evidence: '「説明会の予約が確定しました」',
  receivedAt: DateTime(2026, 10, 26),
  status: status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await initializeDateFormatting('ja_JP', null);
    final font = FontLoader('NotoSansJP')
      ..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<AppState> mount(
    WidgetTester t, {
    double width = 390,
    double scale = 1,
    List<ScheduleSuggestion>? items,
    GlobalKey? capture,
  }) async {
    t.view.physicalSize = Size(width, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final app = AppState();
    await app.ready;
    app.scheduleSuggestions = items ?? [sample('first')];
    await t.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'NotoSansJP',
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
            ),
            locale: const Locale('ja'),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const [Locale('ja')],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const MailScheduleScreen(),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    addTearDown(app.dispose);
    return app;
  }

  for (final width in [320.0, 412.0]) {
    testWidgets('幅$width・文字150%でも予定を読み、詳細から戻れる', (t) async {
      await mount(t, width: width, scale: 1.5);
      expect(find.text('仕事体験参加者向け オンライン会社説明会'), findsOneWidget);
      await t.ensureVisible(find.text('内容を確認'));
      await t.tap(find.text('内容を確認'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.tap(find.text('日時・内容を編集'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('予定として登録'));
      expect(t.takeException(), isNull, reason: '詳細の操作がはみ出さない');
      await t.ensureVisible(find.byTooltip('閉じる'));
      await t.tap(find.byTooltip('閉じる'));
      await t.pumpAndSettle();
      expect(find.text('メールの予定'), findsOneWidget);
    });
  }

  testWidgets('不要操作はその場で戻せる。予定は勝手に登録されない', (t) async {
    final app = await mount(t);
    await t.tap(find.text('内容を確認'));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('この予約は登録しない'));
    await t.tap(find.text('この予約は登録しない'));
    await t.pumpAndSettle();
    expect(app.scheduleSuggestions.single.status, SuggestionStatus.rejected);
    await t.tap(find.text('元に戻す'));
    await t.pumpAndSettle();
    expect(app.pendingScheduleSuggestions, hasLength(1));
    expect(app.events, isEmpty);
  });

  testWidgets('履歴は読み取り表示で、不要の判断だけ確認待ちへ戻せる', (t) async {
    final app = await mount(
      t,
      items: [sample('rejected', status: SuggestionStatus.rejected)],
    );
    await t.tap(find.text('履歴'));
    await t.pumpAndSettle();
    await t.tap(find.text('詳細を見る'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await t.ensureVisible(find.widgetWithText(OutlinedButton, '確認待ちに戻す'));
    await t.tap(find.widgetWithText(OutlinedButton, '確認待ちに戻す'));
    await t.pumpAndSettle();
    expect(app.pendingScheduleSuggestions, hasLength(1));
    expect(app.events, isEmpty);
  });

  testWidgets('空の状態からメール検索を見つけられる', (t) async {
    await mount(t, width: 320, scale: 1.5, items: []);
    expect(find.text('確認待ちはありません'), findsOneWidget);
    await t.ensureVisible(find.text('メールから予定を探す'));
    expect(t.takeException(), isNull);
  });

  test('登録済み・整理済みの候補を未登録に戻さない', () async {
    final app = AppState();
    await app.ready;
    app.scheduleSuggestions = [
      sample('approved', status: SuggestionStatus.approved),
      sample('old', status: SuggestionStatus.superseded),
    ];
    app.reopenScheduleSuggestion('approved');
    app.reopenScheduleSuggestion('old');
    expect(app.pendingScheduleSuggestions, isEmpty);
    app.dispose();
  });

  testWidgets('画面プレビューを架空データで出力', (t) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    final key = GlobalKey();
    final second = sample('second')
      ..title = 'サンプル便 東京 → 大阪'
      ..start = DateTime(2026, 11, 5, 9)
      ..end = DateTime(2026, 11, 5, 10, 30)
      ..location = '成田空港 → 関西空港'
      ..sender = 'サンプル航空';
    await mount(t, capture: key, items: [sample('first'), second]);
    Future<void> save(String name) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await t.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('.dart_tool/mail_schedule_eval/ui');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await save('list');
    await t.tap(find.text('内容を確認').first);
    await t.pumpAndSettle();
    await save('review');
    debugDisableShadows = true;
  }, skip: !const bool.fromEnvironment('CAPTURE_MAIL_UI'));
}
