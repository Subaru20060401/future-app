// 💡 見本の提案（架空の説明会・面接・単発バイト）を入れる機能は 2026-11 に削除した。
//   残っている未承認の見本は、起動時と取り込み時に片付ける。
//   ⚠️ 見本かどうかは sample の印だけで決める。タイトル（「面接」など）では決めない。
//   本人が登録した予定・シフト、承認済みの見本、Gmail から来た本物の提案は残す。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/mail_schedule_models.dart';

import 'support/test_app.dart';

void main() {
  final today = DateTime(2026, 11, 20, 10);

  ScheduleSuggestion suggestion(String id, String title,
          {bool sample = false, SuggestionStatus status = SuggestionStatus.pending}) =>
      ScheduleSuggestion(
        id: id,
        accountKey: sample ? 'sample' : 'acct',
        messageId: id.split('#').first,
        entityKey: id,
        kind: SuggestionKind.event,
        title: title,
        start: DateTime(2026, 12, 1, 10),
        end: DateTime(2026, 12, 1, 11),
        evidence: '「確定しました」',
        sender: 'テスト',
        receivedAt: DateTime(2026, 11, 19),
        sample: sample,
        status: status,
      );

  // 見本 4 件（未承認・保留・却下・承認済み）と、同じ「面接」というタイトルの本物の提案
  Map<String, dynamic> backupWithSamples(AppState a) {
    final data = jsonDecode(a.exportJson()) as Map<String, dynamic>;
    data['scheduleSuggestions'] = [
      suggestion('sample:m1#A', '会社説明会（オンライン）', sample: true).toJson(),
      suggestion('sample:m2#B', '面接（サンプル商事）', sample: true, status: SuggestionStatus.held).toJson(),
      suggestion('sample:m3#C', '単発：イベント設営（サンプル）', sample: true, status: SuggestionStatus.rejected)
          .toJson(),
      suggestion('sample:m4#D', '見本で登録した予定', sample: true, status: SuggestionStatus.approved).toJson(),
      suggestion('acct:m9#Z', '面接（本物の会社）').toJson(),
    ];
    data['events'] = {
      '2026-12-01': [
        {'id': 'e1', 'title': '面接', 'date': '2026-12-01T10:00:00.000'}
      ]
    };
    return data;
  }

  void expectCleaned(AppState a) {
    expect(a.scheduleSuggestions.map((s) => s.id), unorderedEquals(['sample:m4#D', 'acct:m9#Z']),
        reason: '未承認の見本だけ消え、承認済みの見本と本物の提案は残る');
    expect(a.events['2026-12-01']?.map((e) => e.title), ['面接'], reason: '本人の予定は消さない');
  }

  test('古いバックアップの取り込みで、未承認の見本を片付ける（タイトルでは判定しない）', () async {
    final a = await fixedApp(today);
    await a.importJson(jsonEncode(backupWithSamples(a)));
    expectCleaned(a);
  });

  test('起動時にも片付けて保存する（何度起動しても同じ）', () async {
    final a = await fixedApp(today);
    final data = backupWithSamples(a);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_schedule_suggestions', jsonEncode(data['scheduleSuggestions']));
    await prefs.setString('saved_events', jsonEncode(data['events']));
    final b = await reloadApp(today);
    expectCleaned(b);
    await settle();
    final c = await reloadApp(today);
    expectCleaned(c);
  });

  test('見本でない提案は、タイトルが「面接」でも消さない', () async {
    final a = await fixedApp(today);
    a.scheduleSuggestions.add(suggestion('acct:m1#X', '面接'));
    expect(a.repairData(), isFalse);
    expect(a.scheduleSuggestions, hasLength(1));
  });
}
