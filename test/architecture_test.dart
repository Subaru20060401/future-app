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

  // 💡 取り込み中は家計データの変更を断る（GPT 再レビューの残件）。
  //   AppState の公開メソッドで保存するもの（saveData を呼ぶもの）は、始める前に _ensureEditable で断る。
  //   ⚠️ 足し忘れると、取り込み中に受け付けた変更が、取り込みの失敗の巻き戻しで黙って消える
  //     （saveData の安全網で保存はされないが、入力できたように見えてから消える）。
  //   自動の処理（取り込みが終わるのを待って行うもの）は runWhenEditable を使う。
  test('AppState の公開メソッドで保存するものは、取り込み中の変更を断る', () {
    final lines = File('lib/app_state.dart').readAsLinesSync();
    final start = lines.indexWhere((l) => l.startsWith('class AppState'));
    final end = lines.indexWhere((l) => l == '}', start);
    final member = RegExp(r'^  [^ /}@]');
    final name = RegExp(r'([A-Za-z_]\w*)\s*(?:<[^>]*>)?\(');
    // 保存の入口そのもの・取り込みの本体（自分で鍵を持つ）・取り込み中は何もしないもの
    const allowed = {'saveData', 'retryStorage', 'importJson', 'AppState'};
    final missing = <String>[];
    var i = start + 1;
    while (i < end) {
      if (!member.hasMatch(lines[i]) || lines[i].contains(' get ') || lines[i].trimLeft().startsWith('static ')) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < end && !member.hasMatch(lines[j])) {
        j++;
      }
      final m = name.firstMatch(lines[i]);
      final body = lines.sublist(i, j).where((l) => !l.trimLeft().startsWith('//')).join('\n');
      if (m != null && !m.group(1)!.startsWith('_') && !allowed.contains(m.group(1))) {
        final saves = body.contains('saveData(') || body.contains('_saveCardPaymentDays(');
        final guarded = body.contains('_ensureEditable()') || body.contains('runWhenEditable(');
        if (saves && !guarded) missing.add(m.group(1)!);
      }
      i = j;
    }
    expect(missing, isEmpty, reason: '取り込み中の変更を断っていないメソッド');
  });
}

