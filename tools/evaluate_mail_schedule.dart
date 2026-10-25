import 'dart:convert';
import 'dart:io';
import 'package:my_counter_app/mail_schedule_rules.dart';
import 'package:my_counter_app/mail_schedule_models.dart';

// 💡 スマホと同じ日本時間の暦で比較する。実行PCのタイムゾーンには依存しない。
DateTime jstWallClock(int epoch) {
  final t = DateTime.fromMillisecondsSinceEpoch(
    epoch,
    isUtc: true,
  ).add(const Duration(hours: 9));
  return DateTime(
    t.year,
    t.month,
    t.day,
    t.hour,
    t.minute,
    t.second,
    t.millisecond,
  );
}

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      '使い方: dart run tools/evaluate_mail_schedule.dart 入力.json 出力.json [基準日時]',
    );
    exitCode = 64;
    return;
  }
  final now = DateTime.parse(args.length > 2 ? args[2] : '2026-10-25T21:30:00');
  final rows = jsonDecode(File(args[0]).readAsStringSync()) as List;
  final report = <Map<String, dynamic>>[];
  for (final row in rows) {
    final plain = StringBuffer(), html = StringBuffer();
    void walk(Map p) {
      final data = p['body']?['data'] ?? p['body']?['base64_url_content'];
      final content = p['body']?['content'];
      if (content is String || data is String && data.isNotEmpty) {
        final text = content is String
            ? content
            : utf8.decode(
                base64Url.decode(base64Url.normalize(data)),
                allowMalformed: true,
              );
        if (p['mimeType'] == 'text/plain') plain.writeln(text);
        if (p['mimeType'] == 'text/html') html.writeln(text);
      }
      for (final c in p['parts'] as List? ?? []) {
        walk(c as Map);
      }
    }

    walk(row['payload'] as Map);
    final body = plain.isNotEmpty
        ? plain.toString()
        : htmlToText(html.toString());
    final mail = ScheduleMail(
      id: row['id'],
      threadId: row['threadId'] ?? '',
      subject: row['subject'],
      from: row['from'],
      receivedAt: jstWallClock(int.parse(row['internalDate'])),
      body: body,
    );
    final result = readScheduleMail(mail, accountKey: 'evaluation');
    final today = DateTime(now.year, now.month, now.day);
    report.add({
      'id': mail.id,
      'subject': mail.subject,
      'from': mail.from,
      'receivedAt': mail.receivedAt.toIso8601String(),
      'body': body,
      'skipReason': result.skipReason,
      'suggestions': result.suggestions
          .map(
            (s) => {
              ...s.toJson(),
              'past':
                  s.action == SuggestionAction.add &&
                  (s.end ?? s.start)?.isBefore(today) == true,
            },
          )
          .toList(),
    });
  }
  File(args[1]).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'rulesVersion': kScheduleRulesVersion,
      'now': now.toIso8601String(),
      'checked': report.length,
      'mails': report,
    }),
  );
  stdout.writeln(
    '確認: ${report.length}通 / 抽出: ${report.fold<int>(0, (n, r) => n + (r['suggestions'] as List).length)}件',
  );
}
