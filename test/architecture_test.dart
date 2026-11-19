// 💡 依存の向きを固定する: finance（計算部品）と models（データ型）は
//   AppState・画面・外部サービス・Flutter に依存しない（AppState → finance/models の一方向）。
//   破ると「部品を直したら状態や画面まで巻き込まれる」形に戻ってしまう。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final forbidden = RegExp(
      r"""^import\s+['"](?:package:flutter/|package:shared_preferences|package:googleapis|package:provider|.*app_state\.dart|.*screens/|.*widgets/|.*gmail_|.*drive_sync|.*google_)""");

  for (final dir in ['lib/finance', 'lib/models']) {
    test('$dir は状態・画面・外部サービス・Flutter を import しない', () {
      final files = Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      expect(files, isNotEmpty);
      for (final f in files) {
        for (final line in f.readAsLinesSync()) {
          expect(forbidden.hasMatch(line.trim()), isFalse, reason: '${f.path}: $line');
        }
      }
    });
  }

  test('finance は DateTime.now() を読まない（基準時刻は引数で受け取る）', () {
    for (final f in Directory('lib/finance').listSync(recursive: true).whereType<File>()) {
      final code = f
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('DateTime.now()'), isFalse, reason: f.path);
    }
  });
}
