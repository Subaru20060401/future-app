// 💡 メールから予定・単発バイトを「規則で」読み取る（AIを使わない方式）。
//   メールは端末の外に出さない（2026-10-25 本人と決定：課金しない・無料枠のAIに個人情報を送らない）。
//   決まった書き方（「日時：11月12日(木) 14:00〜15:30」など）だけ読む。読めないものは確認事項にして、
//   推測で埋めない。最終的に登録するかは、確認画面で本人が決める。
// ⚠️ ここは提案を作るだけ。保存・重複判定・登録は AppState（addScheduleSuggestions / approve…）。
// ⚠️ メール本文は持ち帰らない。提案に残すのは短い根拠（evidence）と元メールのIDだけ。
import 'mail_schedule_models.dart';
export 'mail_schedule_models.dart' show kScheduleRulesVersion;

// 端末で読むメール1通ぶん（Gmailから取ったもの、またはテストの架空メール）
class ScheduleMail {
  final String id;
  final String threadId;
  final String subject;
  final String from; // 「表示名 <address>」
  final DateTime receivedAt;
  final String body; // テキスト（HTMLならタグを外したもの）
  const ScheduleMail({
    required this.id,
    this.threadId = '',
    required this.subject,
    required this.from,
    required this.receivedAt,
    required this.body,
  });
}

// 読み取りの結果。提案が0件なら、なぜ対象外か（skipReason）を残す
class ScheduleReadResult {
  final List<ScheduleSuggestion> suggestions;
  final String? skipReason;
  const ScheduleReadResult(this.suggestions, [this.skipReason]);
}

// ───── 文字の正規化 ─────
String _half(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      b.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      b.write(' ');
    } else {
      b.writeCharCode(r);
    }
  }
  return b
      .toString()
      .replaceAll(RegExp(r'[～〜~－–—]'), '〜')
      .replaceAll('：', ':')
      .replaceAll('\r', '');
}

// 💡 HTMLメールの本文から文字だけを取り出す（画像や追跡URLは読みに行かない）
String htmlToText(String html) {
  var s = html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|tr|li|h\d)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</t[dh]>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  const ent = {
    '&nbsp;': ' ',
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
  };
  ent.forEach((k, v) => s = s.replaceAll(k, v));
  return s.replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);'), (m) {
    final v = m.group(1)!;
    final n = int.tryParse(
      v.startsWith('x') ? v.substring(1) : v,
      radix: v.startsWith('x') ? 16 : 10,
    );
    return n != null && n > 0 && n <= 0x10ffff && (n < 0xd800 || n > 0xdfff)
        ? String.fromCharCode(n)
        : m.group(0)!;
  });
}

// ⚠️ 引用（> で始まる行・「元のメッセージ」以降）は古い日時を含むので読まない
String _dropQuoted(String body) {
  final lines = <String>[];
  for (final l in body.split('\n')) {
    final t = l.trimLeft();
    if (RegExp(
      r'^(-{2,}\s*(Original Message|元のメッセージ|以下、?元のメッセージ)|On .+ wrote:|.+さんは書きました:)',
    ).hasMatch(t)) {
      break;
    }
    if (t.startsWith('>') || t.startsWith('＞')) continue;
    lines.add(l);
  }
  return lines.join('\n');
}

// ───── 種類の判定 ─────
final _payment = RegExp(
  r'カード利用|ご利用金額|ご請求|引落|引き落とし|振込入金|入金のお知らせ|お支払金額|支払金額|決済|支払い?を受け付け|売上',
);
final _promoSubject = RegExp(
  r'募集|キャンペーン|セール|クーポン|メルマガ|おすすめ|新着求人|プレゼント|お得|予約受付中|予約受付を開始|予約開始|予約しませんか|追加日程|日程公開|チケットトレード|先行販売|再抽選|面接確約枠|スカウト',
);
final _invitation = RegExp(
  r'ご予約ください|ご予約をお待ち|お申し込みください|お申込みください|申込受付中|参加受付中|参加者募集|ご参加ください|予約完了後|予約した時点|予約いただいた時点|予約が完了した.*対象|予約後.*表示され',
);
final _conditional = RegExp(
  r'場合|いただいた方|いただいている方|いただいた時点|いただくと|完了後|完了した.*対象|完了していれば|完了している場合|完了していない|キャンセル待ち|していません|しておりません|ではありません|していない|メールを送信|通知が届き',
);
final _cancel = RegExp(
  r'(?:予約|申込|申し込み|勤務|お仕事)?(?:の)?(?:キャンセル|取り?消し|取消)[、\s]*(?:が[、\s]*)?(?:完了(?:いたしました|しました)?|を承り|を受け付けました|受付完了|いたしました|されました|のお知らせ|となりました)|開催中止|中止(?:のお知らせ|となりました|いたします)|勤務(?:の)?取り?消し',
);
final _change = RegExp(
  r'(日程|日時|時間|会場|場所|勤務時間|集合時間)(の)?変更(が完了|されました|のお知らせ|となりました|いたしました|しました)|予約(の)?変更(が完了|を承り|しました)',
);
final _confirm = RegExp(
  r'(ご?予約|お?申し?込み?)(が|を)?(確定|完了|承りました)|予約確定|予約完了|予約受付完了|ご予約(を)?いただ(き|いた)|ご予約ありがとう|お申し?込みいただき|(面接|面談|説明会|選考)(の)?(日時|日程)?(が|を)?(確定|決定)|(勤務|お仕事|シフト|就業)(が|の)?(確定|決定)|採用(が)?決定|参加(が)?確定|ご来店をお待ち',
);
final _tentative = RegExp(
  r'受付(いたしました|しました|完了)|受け付けました|抽選|候補日|ご都合の(良い|よい)|日程調整|ご回答|仮予約|キャンセル待ち',
);
final _remind = RegExp(r'リマインド|前日のお知らせ|前日となりました|明日は|明日の|まもなく|予定のお知らせ');
final _shiftWords = RegExp(r'勤務|お仕事|シフト|単発|派遣|就業|集合時間|集合時刻|バイト|稼働');
final _english = RegExp(
  r'\b(reservation|appointment|confirmed|interview)\b',
  caseSensitive: false,
);

// ───── 日付・時刻 ─────
class _When {
  final DateTime day;
  final bool hadYear;
  final int? weekday; // メールに書かれた曜日（1=月..7=日）
  final int? startMin;
  final int? endMin;
  const _When(this.day, this.hadYear, this.weekday, this.startMin, this.endMin);
}

const _wd = {'月': 1, '火': 2, '水': 3, '木': 4, '金': 5, '土': 6, '日': 7};

int? _clock(String? h, String? m) {
  if (h == null) return null;
  final hh = int.parse(h);
  final mm = m == null || m.isEmpty ? 0 : int.parse(m);
  if (hh > 47 || mm > 59) return null;
  return hh * 60 + mm;
}

// 「2026年11月12日(木) 14:00〜15:30」「11/12(木)14時〜15時半」などを読む。
final _dateRe = RegExp(
  r'(?<![\d/:.-])(?:(\d{4})\s*[年/.-]\s*)?(\d{1,2})\s*[月/.-]\s*(\d{1,2})(?!\d)\s*日?\s*(?:[(（]\s*([月火水木金土日])\s*(?:曜日?)?\s*[)）])?',
);
// ⚠️ 壊れた時刻も拾い、検証で落とす。10:3を10:00、110:00を10:00にしない。
final _timeRe = RegExp(
  r'(?<![\d:])(\d+)\s*(?::\s*(\d*)|時\s*(?:(\d+)\s*分|(半))?)(?![\d:])',
);

int? _timeMinutes(RegExpMatch m) {
  if (m.group(1)!.length > 2 ||
      (m.group(2) != null && m.group(2)!.length != 2)) {
    return null;
  }
  return _clock(
    m.group(1),
    m.group(2) ?? m.group(3) ?? (m.group(4) == null ? null : '30'),
  );
}

_When? _readWhen(String text, DateTime received) {
  final dm = _dateRe.firstMatch(text);
  if (dm == null) return null;
  final month = int.parse(dm.group(2)!);
  final dayN = int.parse(dm.group(3)!);
  if (month < 1 || month > 12 || dayN < 1 || dayN > 31) return null;
  final hadYear = dm.group(1) != null;
  var year = hadYear ? int.parse(dm.group(1)!) : received.year;
  if (!hadYear) {
    // 年が無い日付は、受信日に近い先の日付として読む（12月に届いた「1月5日」は翌年）
    final guess = DateTime(year, month, dayN);
    if (guess.isBefore(received.subtract(const Duration(days: 60)))) year += 1;
  }
  final day = DateTime(year, month, dayN);
  if (day.month != month || day.day != dayN) return null; // 2月30日など実在しない
  // ⚠️ 別の日付や署名の営業時間から時刻を借りない。
  final tail = text.substring(dm.end);
  final nextDate = _dateRe.firstMatch(tail);
  final nearby = tail.substring(0, nextDate?.start ?? tail.length).split('\n');
  var rest = nearby.first;
  if (nearby.length > 1 &&
      RegExp(
        r'発.*(?:→|着)|^(?:開始|勤務時間|就業時間|時間)\s*[:]',
      ).hasMatch(nearby[1].trim())) {
    rest += ' ${nearby[1]}';
  }
  final times = _timeRe.allMatches(rest).take(2).toList();
  if (times.any((m) => _timeMinutes(m) == null)) return null;
  int? st;
  int? en;
  if (times.isNotEmpty) {
    st = _timeMinutes(times[0]);
    // 2つ目の時刻は「〜」でつながっているときだけ終了として読む
    if (times.length > 1) {
      final between = rest.substring(times[0].end, times[1].start);
      // 飛行機の「発 20:45 → 着 22:55」も範囲として読む
      if (between.contains('〜') ||
          between.contains('-') ||
          between.contains('→')) {
        en = _timeMinutes(times[1]);
      }
    }
  }
  return _When(day, hadYear, _wd[dm.group(4)], st, en);
}

// ───── 項目の取り出し ─────
String? _label(String text, String labels) {
  final m = RegExp(
    '(?:^|\\n)\\s*[■●・]?\\s*(?:[【\\[]\\s*(?:$labels)\\s*[】\\]]\\s*[:]?|(?:$labels)\\s*:)\\s*([^\\n]+)',
  ).firstMatch(text);
  final v = m?.group(1)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

// 💡「日　時」「会　場」のように字の間に空白を入れたラベルを詰める（実メールで多い）
String _joinLabelSpaces(String t) {
  for (final w in const [
    '日時',
    '会場',
    '場所',
    '内容',
    '時間',
    '件名',
    '勤務',
    '集合',
    '開催',
    '実施',
  ]) {
    // 行の頭（記号の後ろ）にあるラベルだけ詰める（「前日 場所」のような文中は触らない）
    t = t.replaceAllMapped(
      RegExp(r'(^|\n|[■●・【\[])(\s*)' + w[0] + r'[ \t]+' + w[1]),
      (m) => '${m.group(1)}${m.group(2)}$w',
    );
  }
  return t;
}

String _cleanSubject(String s) => _half(s)
    .replaceAll(RegExp(r'^((re|fw|fwd)\s*:\s*)+', caseSensitive: false), '')
    .replaceAll(RegExp(r'【[^】]*】|\[[^\]]*\]'), '')
    .replaceAll(RegExp(r'(のお知らせ|のご案内|のご連絡|について)$'), '')
    .replaceAll(RegExp(r'(の)?(ご?予約)?(受付)?(完了|確定)$'), '')
    .trim();

String _senderName(String from) {
  final m = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(from);
  return (m?.group(1) ?? from).trim();
}

String _senderDomain(String from) {
  final m = RegExp(r'@([A-Za-z0-9.-]+)').firstMatch(from);
  return (m?.group(1) ?? 'unknown').toLowerCase();
}

// 参加URLは会議サービスのものだけ拾う（追跡URL・広告URLは拾わない）
String _meetingUrl(String text) {
  final m = RegExp(
    r'https://(?:[\w-]+\.)?(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com)/[^\s<>"）)]+',
  ).firstMatch(text);
  return m?.group(0) ?? '';
}

String _evidence(String text, RegExpMatch? m) {
  if (m == null) return '';
  final line = text.substring(
    text.lastIndexOf('\n', m.start) + 1,
    text.indexOf('\n', m.end) < 0 ? text.length : text.indexOf('\n', m.end),
  );
  final t = line.trim();
  return '「${t.length > 40 ? '${t.substring(0, 40)}…' : t}」';
}

// ⚠️ 取消・変更も、注意書きの条件文や否定文を実行済みと扱わない。
RegExpMatch? _assertedMatch(RegExp pattern, String text) {
  for (final m in pattern.allMatches(text)) {
    final before = text.substring(0, m.start);
    final after = text.substring(m.end);
    final sentence =
        before.split(RegExp(r'[\n。！？]')).last +
        m.group(0)! +
        after.split(RegExp(r'[\n。！？]')).first;
    if (!_conditional.hasMatch(sentence) && !_invitation.hasMatch(sentence)) {
      return m;
    }
  }
  return null;
}

String? _reservationNumber(String text) => RegExp(
  r'(?:予約番号|受付番号|予約ID|予約No\.?|申込番号|応募番号|お仕事番号|案件番号|お問い合わせ番号)\s*[:]?\s*([A-Za-z0-9-]{3,})',
).firstMatch(text)?.group(1);

// 💡 日本国内の対応空港だけ扱う。海外の「現地時刻」を日本時間と誤って登録しない。
const _flightAirports = {
  'NRT': '東京(成田)',
  'HND': '東京(羽田)',
  'OKA': '沖縄',
  'KIX': '大阪(関西)',
  'ITM': '大阪(伊丹)',
  'CTS': '札幌(新千歳)',
  'FUK': '福岡',
  'NGO': '名古屋(中部)',
};

String? _airportCode(String name) {
  final code = RegExp(r'\(([A-Z]{3})\)').firstMatch(name)?.group(1);
  if (code != null) return _flightAirports.containsKey(code) ? code : null;
  for (final e in _flightAirports.entries) {
    if (name.trim() == e.value) return e.key;
  }
  return null;
}

DateTime? _flightTime(String text, DateTime received) {
  final w = _readWhen(text, received);
  final times = _timeRe.allMatches(text).toList();
  if (w == null ||
      !w.hadYear ||
      times.length != 1 ||
      (w.weekday != null && w.weekday != w.day.weekday)) {
    return null;
  }
  final minutes = _timeMinutes(times.single);
  if (minutes == null || minutes >= 24 * 60) return null;
  return w.day.add(Duration(minutes: minutes));
}

ScheduleReadResult? _readFlight(
  ScheduleMail mail,
  String subject,
  String body,
  String accountKey,
) {
  if (!RegExp(r'旅程表|ご予約の確認').hasMatch(subject) ||
      !RegExp(r'フライト|Flight number', caseSensitive: false).hasMatch(body)) {
    return null;
  }
  final reservation = _reservationNumber(body);
  if (reservation == null ||
      RegExp(r'未購入|未入金|仮予約|支払期限|お支払い期限').hasMatch('$subject\n$body')) {
    return const ScheduleReadResult([], '購入・予約確定を確認できない旅程');
  }
  final compact = body
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
  final flightMarkers = RegExp(
    r'^(?:Flight number:|便名[: ]*)?([A-Z]{2})\s*(\d{1,4})(?:便)?$',
    multiLine: true,
  ).allMatches(compact).toList();
  final flights = <String, ScheduleSuggestion>{};
  for (var i = 0; i < flightMarkers.length; i++) {
    final marker = flightMarkers[i];
    final section = compact.substring(
      marker.end,
      i + 1 < flightMarkers.length
          ? flightMarkers[i + 1].start
          : compact.length,
    );
    String? departure, arrival;
    DateTime? start, end;
    final departing = RegExp(
      r'Departing:([^\n]+)\n([^\n]+)\n([^\n]+)',
    ).firstMatch(section);
    final arriving = RegExp(
      r'Arriving:([^\n]+)\n([^\n]+)\n([^\n]+)',
    ).firstMatch(section);
    if (departing != null &&
        arriving != null &&
        departing.start < arriving.start) {
      departure = _airportCode(departing.group(1)!);
      arrival = _airportCode(arriving.group(1)!);
      start = _flightTime(
        '${departing.group(2)} ${departing.group(3)}',
        mail.receivedAt,
      );
      end = _flightTime(
        '${arriving.group(2)} ${arriving.group(3)}',
        mail.receivedAt,
      );
    } else if (RegExp(r'便名\s+出発\s+到着').hasMatch(compact)) {
      final points = RegExp(
        r'^([^\n]+\([A-Z]{3}\))\n([^\n]+)\n([^\n]+)',
        multiLine: true,
      ).allMatches(section).toList();
      if (points.length == 2) {
        departure = _airportCode(points[0].group(1)!);
        arrival = _airportCode(points[1].group(1)!);
        start = _flightTime(
          '${points[0].group(2)} ${points[0].group(3)}',
          mail.receivedAt,
        );
        end = _flightTime(
          '${points[1].group(2)} ${points[1].group(3)}',
          mail.receivedAt,
        );
      }
    }
    if (departure == null ||
        arrival == null ||
        departure == arrival ||
        start == null ||
        end == null ||
        !end.isAfter(start) ||
        end.difference(start) > const Duration(hours: 24)) {
      return const ScheduleReadResult([], '旅程の出発・到着日時または国内空港を確認できません');
    }
    final flight = '${marker.group(1)}${marker.group(2)}';
    flights['$flight|$departure|$arrival|$start|$end'] = ScheduleSuggestion(
      id: '$accountKey:${mail.id}#0',
      accountKey: accountKey,
      messageId: mail.id,
      entityKey: '${_senderDomain(mail.from)}#$reservation',
      kind: SuggestionKind.event,
      title:
          '$flight ${_flightAirports[departure]} → ${_flightAirports[arrival]}',
      start: start,
      end: end,
      location: '$departure → $arrival',
      evidence: '予約番号・便名・出発地・到着地とそれぞれの日時を旅程で確認（国内線）',
      sender: _senderName(mail.from),
      receivedAt: mail.receivedAt,
    );
  }
  // ⚠️ 複数区間の取消照合は未対応。片道だけ切り出して往復予約を誤登録しない。
  if (flights.length != 1) {
    return const ScheduleReadResult([], '単一区間の旅程を確認できません（複数区間は未対応）');
  }
  return ScheduleReadResult(flights.values.toList());
}

// 💡 1通を読み、提案（0件以上）にする。
//   accountKey: どのGoogleアカウントのメールか（メールアドレスそのものは入れない）
ScheduleReadResult readScheduleMail(
  ScheduleMail mail, {
  required String accountKey,
}) {
  final subject = _half(mail.subject);
  final decodedBody =
      RegExp(
        r'<(?:html|body|table|div|p)\b',
        caseSensitive: false,
      ).hasMatch(mail.body)
      ? htmlToText(mail.body)
      : mail.body;
  final body = _joinLabelSpaces(_dropQuoted(_half(decodedBody)));
  final text = '$subject\n$body';

  final cancelM = _assertedMatch(_cancel, text);
  final changeM = cancelM == null ? _assertedMatch(_change, text) : null;
  if (cancelM == null && changeM == null && !_promoSubject.hasMatch(subject)) {
    final flight = _readFlight(mail, subject, body, accountKey);
    if (flight != null) return flight;
  }
  // ⚠️ 取消には返金・決済の説明もある。支払いの単語だけで除外しない。
  if (_payment.hasMatch(text) &&
      !_confirm.hasMatch(text) &&
      cancelM == null &&
      changeM == null) {
    return const ScheduleReadResult([], '支払い・入金のメール');
  }
  // 💡 条件文・予約方法の説明は、本人の予約確定の証拠にしない。
  final confirmM = _assertedMatch(_confirm, text);
  final tentativeM = _tentative.firstMatch(text);
  final remindM = _remind.firstMatch(text);
  if (cancelM == null &&
      changeM == null &&
      confirmM == null &&
      tentativeM == null &&
      remindM == null) {
    if (_english.hasMatch(text)) {
      return const ScheduleReadResult([], '英語のメール（未対応）');
    }
    return const ScheduleReadResult([], '予約・勤務の確定ではない');
  }
  // 💡 募集・宣伝の件名は、本文に予約方法の「確定」があっても出さない
  if (_promoSubject.hasMatch(subject) && cancelM == null && changeM == null) {
    return const ScheduleReadResult([], '募集・宣伝');
  }

  if (cancelM == null && changeM == null && confirmM == null) {
    return const ScheduleReadResult([], '本人の予約・参加の確定を確認できません');
  }
  if (cancelM == null &&
      changeM == null &&
      RegExp(r'抽選|仮予約|承認後に確定|結果は後日|未購入|未入金').hasMatch(text) &&
      !RegExp(r'当選|購入完了|入金確認|発券完了').hasMatch(text)) {
    return const ScheduleReadResult([], '抽選・仮予約・未購入のため参加未確定');
  }

  final action = cancelM != null
      ? SuggestionAction.cancel
      : changeM != null
      ? SuggestionAction.change
      : SuggestionAction.add;
  final isShift = _shiftWords.hasMatch(text);
  final missing = <String>[];
  if (action == SuggestionAction.add && confirmM == null) {
    if (tentativeM != null) {
      missing.add('まだ確定していません（${tentativeM.group(0)}）');
    } else {
      missing.add('確定の文が見つかりません（リマインドの可能性）');
    }
  }

  // 予約番号など（同じ予約の変更・取消を当てる手がかり）
  final reservationNo = _reservationNumber(text);
  final domain = _senderDomain(mail.from);

  // 日時の行（「日時：」などのラベル行を優先。無ければ本文の最初の日付）
  final whenLines = <String>[];
  const whenLabels =
      '(?:変更後の?)?(?:日時|日程|開催日時|開催日|予約日時|ご予約日時|面接日時|面談日時|勤務日時|勤務日|就業日|集合日時|日付|実施日|来店日時|搭乗日|出発日)';
  final lineRe = RegExp(
    '(?:^|\\n)\\s*[■●・]?\\s*(?:[【\\[]\\s*$whenLabels\\s*[】\\]]\\s*:?|$whenLabels\\s*:)\\s*([^\\n]+)',
  );
  for (final m in lineRe.allMatches(body)) {
    whenLines.add(m.group(1)!);
  }
  // 変更のメールは「変更後」を優先し、「変更前」は読まない
  if (action == SuggestionAction.change) {
    final after = RegExp(r'変更後[^\n]*?[:]\s*([^\n]+)').firstMatch(body);
    if (after != null) {
      whenLines
        ..clear()
        ..add(after.group(1)!);
    }
    whenLines.removeWhere((l) => l.contains('変更前'));
  }
  if (whenLines.isEmpty) whenLines.add(body);

  // 勤務時間・集合時刻（単発バイト）
  final workTime = _label(body, '勤務時間|就業時間|稼働時間');
  final meetTime = _label(body, '集合時間|集合時刻');

  final whens = <_When>[];
  for (final l in whenLines) {
    final w = _readWhen(l, mail.receivedAt);
    if (w != null &&
        !whens.any((x) => x.day == w.day && x.startMin == w.startMin)) {
      whens.add(w);
    }
  }
  if (RegExp(r'候補日|日程調整|ご都合の(良い|よい)').hasMatch(text)) {
    // 候補日の中から選ぶメールは、どれか1つに決めつけない
    return const ScheduleReadResult([], '候補日から選ぶ案内で日時が未確定');
  }
  if (whens.isEmpty && action != SuggestionAction.cancel) {
    if (RegExp(r'添付|PDF|別紙').hasMatch(body)) {
      missing.add('詳細は添付ファイルにあるようです（添付は読んでいません）');
    } else if (missing.isEmpty) {
      missing.add('日時が読み取れませんでした');
    }
  }

  final title =
      _label(
        body,
        'イベント名|イベント|講座名|説明会名|セミナー名|予約内容|ご予約内容|コース|メニュー|お仕事内容|職種|案件名',
      ) ??
      _cleanSubject(mail.subject);
  final location =
      _label(body, '会場名|開催場所|実施場所|会場|場所|勤務地|就業場所|集合場所|住所|店舗') ??
      (RegExp(
            r'オンライン|Zoom|Google Meet|Teams',
            caseSensitive: false,
          ).hasMatch(body)
          ? 'オンライン'
          : '');
  final url = _meetingUrl(body);
  final evidence = _evidence(
    text,
    cancelM ?? changeM ?? confirmM ?? tentativeM ?? remindM,
  );

  ScheduleSuggestion make(int n, _When? w) {
    final miss = [...missing];
    DateTime? start;
    DateTime? end;
    var allDay = false;
    if (w != null) {
      if (!w.hadYear) miss.add('年が書かれていません（${w.day.year}年として読みました）');
      if (w.weekday != null && w.weekday != w.day.weekday) {
        miss.add('日付と曜日が合いません。日付を確かめてください');
      }
      var st = w.startMin;
      var en = w.endMin;
      // 単発バイトは「勤務時間」を開始・終了にし、集合時刻は確認事項に出す
      if (isShift && workTime != null) {
        final t = _readWhen('${w.day.month}月${w.day.day}日 $workTime', w.day);
        if (t?.startMin != null) {
          st = t!.startMin;
          en = t.endMin;
        }
      }
      if (isShift && meetTime != null) {
        final m = _timeRe.firstMatch(meetTime);
        if (m != null) miss.add('集合は ${m.group(0)}（勤務の開始とは別）');
      }
      if (st == null) {
        allDay = !isShift;
        start = w.day;
        if (isShift) miss.add('勤務の開始時刻が読み取れませんでした');
      } else {
        start = w.day.add(Duration(minutes: st));
        if (en != null) {
          var e = w.day.add(Duration(minutes: en));
          if (!e.isAfter(start)) e = e.add(const Duration(days: 1)); // 日をまたぐ
          end = e;
        } else if (action != SuggestionAction.cancel) {
          miss.add('終了時刻が書かれていません');
        }
      }
    }
    if (isShift &&
        action == SuggestionAction.add &&
        _label(body, '休憩|休憩時間') == null) {
      miss.add('休憩時間が書かれていません');
    }
    // 💡 予約番号が無ければ「送信元＋開始日時」を同じ予約の目印にする。
    //   確定メール・前日の案内・取消メールが同じ予約だと分かり、提案が二重にならない。
    //   ⚠️ 日時が変わる「変更」はこの目印では元の予約に当たらない（本人が確認画面で対応する）。
    String two(int v) => v.toString().padLeft(2, '0');
    final entity = reservationNo != null
        ? '$domain#$reservationNo${whens.length > 1 ? '#$n' : ''}'
        : start != null && !allDay
        ? '$domain#at:${start.year}-${two(start.month)}-${two(start.day)}T${two(start.hour)}:${two(start.minute)}'
        : 'msg:${mail.id}#$n';
    return ScheduleSuggestion(
      rulesVersion: kScheduleRulesVersion,
      id: '$accountKey:${mail.id}#$n',
      accountKey: accountKey,
      messageId: mail.id,
      entityKey: entity,
      kind: isShift ? SuggestionKind.shift : SuggestionKind.event,
      action: action,
      title: title.length > 60 ? title.substring(0, 60) : title,
      start: start,
      end: end,
      allDay: allDay,
      location: location.length > 80 ? location.substring(0, 80) : location,
      url: url,
      evidence:
          '$evidence${w == null ? '' : ' / 日時: ${w.day.year}/${w.day.month}/${w.day.day}'}',
      sender: _senderName(mail.from),
      receivedAt: mail.receivedAt,
      missing: miss,
    );
  }

  if (whens.isEmpty) {
    if (action == SuggestionAction.cancel && reservationNo != null) {
      return ScheduleReadResult([make(0, null)]);
    }
    return const ScheduleReadResult([], '日時が読み取れないため対象外');
  }
  if (action != SuggestionAction.cancel &&
      whens.any(
        (w) =>
            (isShift && workTime != null
                ? _readWhen(
                    '${w.day.year}/${w.day.month}/${w.day.day} $workTime',
                    w.day,
                  )?.startMin
                : w.startMin) ==
            null,
      ) &&
      !(!isShift && RegExp(r'終日|一日中').hasMatch(body))) {
    return const ScheduleReadResult([], '開始時刻が読み取れないため対象外');
  }
  if (whens.length > 1 && !isShift && action == SuggestionAction.add) {
    // 予定で日付が複数あるのは、候補日や複数日程のことが多い。1件にして本人に選んでもらう
    final s = make(0, whens.first);
    s.missing.add('日付が${whens.length}つ書かれています。正しい日を選んでください');
    return ScheduleReadResult([s]);
  }
  return ScheduleReadResult([
    for (var i = 0; i < whens.length; i++) make(i, whens[i]),
  ]);
}
