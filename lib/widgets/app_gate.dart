// 💡 アプリを開く前の関所。
//   ① パスコードロック（他人が端末を触ったときの目隠し）
//   ② Googleログイン（ログインしたらドライブから自分のデータが降りてくる）
//   どちらも設定でONにしたときだけ働く。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../gmail_service.dart';
import '../lock_service.dart';
import '../screens/lock_screen.dart';
import '../screens/login_screen.dart';

class AppGate extends StatefulWidget {
  const AppGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> with WidgetsBindingObserver {
  bool _loginDone = false;
  bool _checkingLogin = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLogin();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 戻ってきたら猶予時間を過ぎている場合だけロックし直す
    if (state == AppLifecycleState.resumed) {
      LockService.instance.onResume();
      // 💡 アクセストークンは1時間で切れる。
      //   ⚠️ iOSのホーム画面アプリは、戻ってきてもページを読み込み直さないことがある。
      //     起動時だけの取り直しでは「数時間空けたら未連携」が直らないので、
      //     戻ってきた時点でも切れていれば黙って取り直す（ページが移動することがある）。
      //     ロック中は画面を出さない約束なので、解除された後にする。
      if (!LockService.instance.isLocked) {
        GmailService.instance.tryRestoreSilently();
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _checkLogin() async {
    final appState = context.read<AppState>();
    // 💡 ログインを求めない設定でも、連携の記憶は読んでおく。
    //   再開時の「黙って取り直す」が signedInOnce を見るため。
    await GmailService.instance.loadAuthState();
    if (!appState.requireGoogleLogin) {
      if (mounted) setState(() => _checkingLogin = false);
      return;
    }
    // 💡 一度でも連携できていればログイン画面は出さない。
    //   ブラウザ版はアクセストークンが1時間で切れるため、毎回ここで止めると
    //   開くたびにログインを求められてしまう。
    //   実際の権限は同期やメール取得のときに、その場で求める。
    await GmailService.instance.loadAuthState();
    if (GmailService.instance.signedInOnce) {
      GmailService.instance.signInSilently(); // 裏で復帰を試みる
      if (!mounted) return;
      setState(() {
        _loginDone = true;
        _checkingLogin = false;
      });
      return;
    }
    await GmailService.instance.signInSilently();
    final ok = await GmailService.instance.hasGmailAccess();
    if (!mounted) return;
    setState(() {
      _loginDone = ok;
      _checkingLogin = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // パスコードが最優先（ログイン画面すら見せない）
    if (LockService.instance.isLocked) {
      return LockScreen(onUnlocked: () {
        // ロック中は飛ばさなかったので、解除された今、切れていれば取り直す
        GmailService.instance.tryRestoreSilently();
        setState(() {});
      });
    }

    final appState = context.watch<AppState>();
    if (appState.requireGoogleLogin && !_loginDone) {
      if (_checkingLogin) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return LoginScreen(
        appState: appState,
        onDone: () => setState(() => _loginDone = true),
      );
    }
    return widget.child;
  }
}
