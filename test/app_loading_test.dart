// 起動時の読み込み状態（isLoaded / ready）のテスト。
// 💡 読み終える前の初期値（0円）を出さない・同期を読み込み前に始めないための目印。
// ⚠️ 読み込みで例外が出ても「読み終えた」にならないと、ホームが読み込み中のまま止まる。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('読み終えると ready が完了し、保存した残高が入っている', () async {
    SharedPreferences.setMockInitialValues({'flutter.saved_balance': 85000});
    final app = AppState();
    expect(app.isLoaded, isFalse, reason: '作った直後はまだ読んでいない');
    await app.ready.timeout(const Duration(seconds: 5));
    expect(app.isLoaded, isTrue);
    expect(app.currentBalance, 85000);
  });

  test('保存データが壊れていて読み込みが失敗しても、読み込み中のまま止まらない', () async {
    // 💡 わざと壊れたJSONを入れる
    SharedPreferences.setMockInitialValues({'flutter.saved_shifts': '{broken'});
    final errors = <Object>[];
    late AppState app;
    await runZonedGuarded(() async {
      app = AppState();
      await app.ready.timeout(const Duration(seconds: 5));
    }, (e, _) => errors.add(e));
    expect(app.isLoaded, isTrue);
    // 例外そのものは握りつぶさず外へ出ている（原因を追えるように）
    expect(errors, isNotEmpty);
  });
}
