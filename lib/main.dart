import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart'; // 💡 追加
import 'app_state.dart'; // 💡 追加
import 'background_themes.dart';
import 'notification_service.dart';
import 'calendar_sync.dart';
import 'gmail_sync.dart';
import 'screens/calendar_screen.dart';
import 'screens/income_screen.dart';
import 'screens/todo_screen.dart';
import 'screens/payment_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/deposit_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ja_JP', null);
  // 💡 通知とカレンダー連携は端末アプリ専用。Webでは使えないので繋がない。
  if (!kIsWeb) {
    await NotificationService.instance.init();
  }

  final appState = AppState();
  if (!kIsWeb) {
    // 💡 Appleカレンダー自動連携の実装を接続（OFFのときは何もしない）
    appState.calendarSync = AppleCalendarSync(appState);
    // 💡 データが変わるたびに通知を組み立て直す
    appState.addListener(() {
      NotificationService.instance.rescheduleAll(appState);
    });
  }

  runApp(
    // 💡 アプリ全体を「共有金庫（Provider）」で包み込む
    ChangeNotifierProvider.value(
      value: appState,
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.pink);
    return MaterialApp(
      title: 'ポケットメイド',
      debugShowCheckedModeBanner: false,
      // 💡 DatePicker/TimePicker などMaterialウィジェットを日本語表示にする
      locale: const Locale('ja'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ja'), Locale('en')],
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        // 💡 同梱の日本語フォント（Webでも確実に日本語が出るように）
        fontFamily: 'NotoSansJP',
        // 💡 背景は builder のグラデーションを見せるため透明に
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          // グラデーション背景に馴染ませるため透明＋影なし
          backgroundColor: Colors.transparent,
          foregroundColor: Color(0xFFAD1457),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white.withValues(alpha: 0.85),
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.pink.withValues(alpha: 0.15),
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        listTileTheme: const ListTileThemeData(iconColor: Colors.pink),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Colors.pink,
          foregroundColor: Colors.white,
        ),
        chipTheme: ChipThemeData(
          selectedColor: Colors.pink[100],
          backgroundColor: Colors.pink[50],
          labelStyle: const TextStyle(fontSize: 13),
        ),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      // 💡 全ページ共通のグラデーション背景（設定で色を変更可能）
      builder: (context, child) {
        final themeKey = context.watch<AppState>().backgroundTheme;
        final bg = backgroundThemeByKey(themeKey);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: bg.colors,
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
          child: child!,
        );
      },
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // 💡 アプリ起動時に自動でメールから取得（連携済みのときだけ実行）
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final appState = context.read<AppState>();
      // 前回までに溜まっている入金通知・引き落としがあれば先に聞く
      await _askPendingDeposits(appState);
      await _askPendingDraws(appState);
      final result = await syncGmail(appState);
      if (!mounted || result.notSignedIn) return;
      if (result.skipped) {
        // 取りこぼしで反映を見送ったときは、気づけるように知らせる
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: Colors.orange[800],
            duration: const Duration(seconds: 6),
          ),
        );
      } else if (result.added > 0 || result.removed > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('メール更新: ${result.message}')),
        );
      }
      // 今回の取得で見つかった入金通知を聞く
      await _askPendingDeposits(appState);
      // 引き落とし済みで、まだ口座残高に反映していないものを聞く
      await _askPendingDraws(appState);
    });
  }

  // 💡 未処理の入金通知を1件ずつポップアップで聞く（古い順）
  Future<void> _askPendingDeposits(AppState appState) async {
    while (mounted && appState.pendingDeposits.isNotEmpty) {
      final notice = appState.pendingDeposits.first;
      await showDepositDialog(context, appState, notice);
      if (!mounted) return;
      // ダイアログで処理されなかった場合は無限ループを避けて抜ける
      if (appState.pendingDeposits.isNotEmpty &&
          appState.pendingDeposits.first.sourceId == notice.sourceId) {
        return;
      }
    }
  }

  // 💡 まだ口座に反映していない引き落としを1件ずつ聞く（古い順）
  Future<void> _askPendingDraws(AppState appState) async {
    while (mounted && appState.pendingDraws.isNotEmpty) {
      final draw = appState.pendingDraws.first;
      await showDrawDialog(context, appState, draw);
      if (!mounted) return;
      // 処理されなかった場合は無限ループを避けて抜ける
      final next = appState.pendingDraws;
      if (next.isNotEmpty && next.first.id == draw.id) return;
    }
  }

  final List<Widget> _screens = [
    const CalendarScreen(),
    const TodoScreen(),
    const IncomeScreen(),
    const PaymentScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 💡 選択中の画面だけを表示（全画面同時保持をやめ、FAB/AppBarの混線を防止）
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.pink,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'カレンダー'),
          BottomNavigationBarItem(icon: Icon(Icons.check_circle_outline), label: 'Todo'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet), label: '残高'),
          BottomNavigationBarItem(icon: Icon(Icons.payments), label: '支払い'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '設定'),
        ],
      ),
    );
  }
}