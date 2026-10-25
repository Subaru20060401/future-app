// 💡 実メールで分かった構造だけを架空化し、個人情報を含めず検証する。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_counter_app/app_state.dart';
import 'package:my_counter_app/mail_schedule_rules.dart';

ScheduleReadResult read(String subject, String body, {String id = 'mail'}) =>
    readScheduleMail(
      ScheduleMail(
        id: id,
        subject: subject,
        body: body,
        from: 'サンプル予約 <booking@example.com>',
        receivedAt: DateTime(2026, 10, 25),
      ),
      accountKey: 'test',
    );

const confirmation = '''ご予約番号: TEST01
ご予約内容をご確認ください。
フライト
便名
出発
到着
XX 123
東京(成田) (NRT)
09:15
2026年11月30日(月)
大阪(関西) (KIX)
10:45
2026年11月30日(月)
''';
const itinerary = '''旅程表発行日: 2026年10月1日
ご予約番号
TEST01
フライト ご予約日: 2026年10月1日
Date:2026年11月30日(月)
09:15
Flight number:XX123
運賃: サンプル
Departing:東京(成田)
2026年11月30日(月)
09:15
第1ターミナル
Arriving:大阪(関西)
2026年11月30日(月)
10:45
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('旅程表の発行日・予約日ではなく出発と到着の日時を読む', () {
    final a = read('サンプル航空 旅程表', itinerary).suggestions.single;
    final b = read('サンプル航空 ご予約の確認', confirmation).suggestions.single;
    expect(a.start, DateTime(2026, 11, 30, 9, 15));
    expect(a.end, DateTime(2026, 11, 30, 10, 45));
    expect(a.title, 'XX123 東京(成田) → 大阪(関西)');
    expect(a.blockers, isEmpty);
    expect(b.start, a.start);
    expect(b.end, a.end);
    expect(a.entityKey, b.entityKey);
  });

  test('HTMLの旅程、予約確認、取消を同じ予約として照合する', () async {
    final app = AppState();
    await app.ready;
    final a = read('サンプル航空 旅程表', itinerary, id: 'itinerary');
    final b = read(
      'サンプル航空 ご予約の確認',
      '<html><p>${confirmation.replaceAll('\n', '</p><p>')}</p></html>',
      id: 'confirmation',
    );
    expect(app.addScheduleSuggestions([...a.suggestions, ...b.suggestions]), 1);
    expect(app.pendingScheduleSuggestions, hasLength(1));
    app.addScheduleSuggestions(
      read('予約キャンセル完了', '予約番号: TEST01', id: 'cancel').suggestions,
    );
    expect(app.pendingScheduleSuggestions, isEmpty);
    expect(app.events, isEmpty);
    app.dispose();
  });

  for (final (name, body) in <(String, String)>[
    ('未購入', '$confirmation\n未購入です'),
    ('海外空港', confirmation.replaceAll('(KIX)', '(SIN)')),
    ('到着不明', confirmation.replaceAll('10:45', '未定')),
    ('曜日不一致', confirmation.replaceAll('(月)', '(火)')),
    ('存在しない日', confirmation.replaceAll('11月30日', '11月31日')),
    ('到着が出発より前', confirmation.replaceAll('10:45', '08:45')),
    ('壊れた時刻', confirmation.replaceAll('09:15', '09:1')),
    ('予約番号なし', confirmation.replaceAll('ご予約番号: TEST01', '')),
    ('複数区間', '$confirmation\n${confirmation.replaceAll('XX 123', 'XX 456')}'),
  ]) {
    test('旅程を推測しない: $name', () {
      expect(read('サンプル航空 ご予約の確認', body).suggestions, isEmpty);
    });
  }
  test('日をまたぐ旅程は到着日をそのまま使う', () {
    final body = confirmation
        .replaceAll('09:15', '23:15')
        .replaceAll('10:45\n2026年11月30日(月)', '00:45\n2026年12月1日(火)');
    final s = read('サンプル航空 ご予約の確認', body).suggestions.single;
    expect(s.end, DateTime(2026, 12, 1, 0, 45));
  });

  for (final time in [
    '10:3〜11:00',
    '110:00〜11:00',
    '10:00〜11:99',
    '48:00〜49:00',
    '10:〜11:00',
  ]) {
    test('壊れた時刻を補完しない: $time', () {
      expect(read('予約確定', '日時: 2026年11月30日 $time').suggestions, isEmpty);
    });
  }
  test('ISO日付と日本語の分表記を読む', () {
    final s = read('予約確定', '日時: 2026-11-30 10時5分〜11時半').suggestions.single;
    expect(s.start, DateTime(2026, 11, 30, 10, 5));
    expect(s.end, DateTime(2026, 11, 30, 11, 30));
  });
  test('番号の一部を日付と誤認しない', () {
    expect(read('予約確定', '管理番号: 12345/11/30 10:00〜11:00').suggestions, isEmpty);
  });
  test('勤務時間の欄があっても、時刻が壊れていれば候補にしない', () {
    expect(
      read('勤務確定', '勤務日: 2026年11月30日\n勤務時間: 10:3〜18:00').suggestions,
      isEmpty,
    );
  });
  for (final note in [
    'キャンセルが完了した場合はご連絡ください。',
    '日程変更が完了していません。',
    'キャンセル完了メールを送信します。',
  ]) {
    test('注意書きは取消・変更にしない: $note', () {
      final s = read(
        '予約確定',
        '日時: 2026年11月30日 10:00〜11:00\n$note',
      ).suggestions.single;
      expect(s.action, SuggestionAction.add);
    });
  }
  test('否定文だけでは確定にしない', () {
    expect(
      read('予約について', '予約が確定していません。\n日時: 2026年11月30日 10:00〜11:00').suggestions,
      isEmpty,
    );
  });

  test('不要にした同じ予約の別メールを再提案しない', () async {
    final app = AppState();
    await app.ready;
    final first = read('予約確定', '日時: 2026年11月30日 10:00〜11:00\n予約番号: TEST02');
    app.addScheduleSuggestions(first.suggestions);
    app.rejectScheduleSuggestion(first.suggestions.single.id);
    final reminder = read(
      '予約確定のリマインド',
      '日時: 2026年11月30日 10:00〜11:00\n予約番号: TEST02',
      id: 'reminder',
    );
    expect(app.addScheduleSuggestions(reminder.suggestions), 0);
    expect(app.pendingScheduleSuggestions, isEmpty);
    expect(app.scheduleSuggestions.single.status, SuggestionStatus.rejected);
    app.dispose();
  });
  test('同じ取り込み内の取消で消えた候補は発見件数に含めない', () async {
    final app = AppState();
    await app.ready;
    final add = read('予約確定', '日時: 2026年11月30日 10:00〜11:00\n予約番号: TEST02');
    final cancel = read('予約キャンセル完了', '予約番号: TEST02', id: 'cancel');
    expect(
      app.addScheduleSuggestions([...cancel.suggestions, ...add.suggestions]),
      0,
    );
    expect(app.pendingScheduleSuggestions, isEmpty);
    app.dispose();
  });
}
