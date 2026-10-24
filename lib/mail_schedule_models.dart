// 💡 メールから見つけた「予定・単発バイトの提案」のデータ（計画書 docs/mail-schedule-proposal-plan-2026-10-25.md）。
//   提案はあくまで候補。本人が承認するまで、予定・シフト・収入・残高には一切入れない。
//   承認・却下の判断は AppState（approveScheduleSuggestion など）で行い、画面は表示と入力だけ。
// ⚠️ メールの全文は持たない。短い根拠（evidence）と元メールの参照（messageId）だけを残す。

enum SuggestionKind { event, shift }

// 追加／変更／取消。変更・取消は「承認済みの予定」に対する別の提案として扱う。
enum SuggestionAction { add, change, cancel }

// pending=確認待ち held=保留 approved=登録済み rejected=今回は登録しない
// expired=期限切れ superseded=新しい提案に置き換わった
enum SuggestionStatus { pending, held, approved, rejected, expired, superseded }

class ScheduleSuggestion {
  // 💡 提案のID。同じメールの同じ予約なら同じID（再取得しても増えない）。
  final String id;
  final String accountKey; // どのGoogleアカウントのメールか
  final String messageId; // 元メールのID（全文は持たない）
  // 💡 予約・開催回の安定ID（予約番号など）。変更・取消を同じ予定に当てるのに使う。
  //   日時は変わりうるので、日時だけでは作らない。
  final String entityKey;
  int version; // 内容が変わるたびに上がる（古い提案で新しい手編集を上書きしないため）
  SuggestionKind kind;
  SuggestionAction action;
  String title;
  DateTime? start;
  DateTime? end;
  bool allDay;
  String location;
  String url;
  String evidence; // 短い根拠（「ご予約が確定しました」など）
  String sender; // 送信元の表示名
  DateTime receivedAt;
  List<String> missing; // 確認事項（「終了時刻が未記載」など）
  SuggestionStatus status;
  // 承認したときの登録先（'event:<id>' / 'shift:<id>'）
  String? targetRef;
  // 💡 見本（架空のデータ）かどうか。本物のメールと混ざらないように区別する
  final bool sample;

  ScheduleSuggestion({
    required this.id,
    required this.accountKey,
    required this.messageId,
    required this.entityKey,
    this.version = 1,
    required this.kind,
    this.action = SuggestionAction.add,
    required this.title,
    this.start,
    this.end,
    this.allDay = false,
    this.location = '',
    this.url = '',
    this.evidence = '',
    this.sender = '',
    required this.receivedAt,
    List<String>? missing,
    this.status = SuggestionStatus.pending,
    this.targetRef,
    this.sample = false,
  }) : missing = missing ?? [];

  bool get isOpen => status == SuggestionStatus.pending || status == SuggestionStatus.held;

  // 💡 登録に足りないもの。終了時刻の無い時間指定の予定は、本人が補うまで登録させない
  //   （カレンダーへ「1時間」と勝手に補うと、根拠のない時刻になる）。
  List<String> get blockers {
    final out = <String>[];
    if (action == SuggestionAction.cancel) return out;
    if (title.trim().isEmpty) out.add('タイトルがありません');
    if (start == null) {
      out.add('日付がわかりません');
    } else if (!allDay) {
      if (end == null) {
        out.add('終了時刻がわかりません');
      } else if (!end!.isAfter(start!)) {
        out.add('終了が開始より前です');
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountKey': accountKey,
        'messageId': messageId,
        'entityKey': entityKey,
        'version': version,
        'kind': kind.name,
        'action': action.name,
        'title': title,
        'start': start?.toIso8601String(),
        'end': end?.toIso8601String(),
        'allDay': allDay,
        'location': location,
        'url': url,
        'evidence': evidence,
        'sender': sender,
        'receivedAt': receivedAt.toIso8601String(),
        'missing': missing,
        'status': status.name,
        'targetRef': targetRef,
        if (sample) 'sample': true,
      };

  static T _enum<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.firstWhere((v) => v.name == name, orElse: () => fallback);

  factory ScheduleSuggestion.fromJson(Map<String, dynamic> j) => ScheduleSuggestion(
        id: j['id'] as String,
        accountKey: j['accountKey'] as String? ?? '',
        messageId: j['messageId'] as String? ?? '',
        entityKey: j['entityKey'] as String? ?? '',
        version: j['version'] as int? ?? 1,
        kind: _enum(SuggestionKind.values, j['kind'], SuggestionKind.event),
        action: _enum(SuggestionAction.values, j['action'], SuggestionAction.add),
        title: j['title'] as String? ?? '',
        start: DateTime.tryParse(j['start'] as String? ?? ''),
        end: DateTime.tryParse(j['end'] as String? ?? ''),
        allDay: j['allDay'] as bool? ?? false,
        location: j['location'] as String? ?? '',
        url: j['url'] as String? ?? '',
        evidence: j['evidence'] as String? ?? '',
        sender: j['sender'] as String? ?? '',
        receivedAt: DateTime.tryParse(j['receivedAt'] as String? ?? '') ?? DateTime(2000),
        missing: [for (final m in (j['missing'] as List? ?? const [])) '$m'],
        status: _enum(SuggestionStatus.values, j['status'], SuggestionStatus.pending),
        targetRef: j['targetRef'] as String?,
        sample: j['sample'] as bool? ?? false,
      );
}

// 💡 予約（entityKey）と、登録した予定・シフトの対応。
//   再通知で予定を増やさない／取消を正しい予定に当てる／消した予定を復活させない、のために使う。
class MailEntityLink {
  final String entityKey;
  final String accountKey;
  String targetRef; // 'event:<id>' / 'shift:<id>'
  int approvedVersion;
  // 本人が予定を消した／取消を承認した。同じ予約の再通知で勝手に復活させない
  bool removed;

  MailEntityLink({
    required this.entityKey,
    required this.accountKey,
    required this.targetRef,
    required this.approvedVersion,
    this.removed = false,
  });

  Map<String, dynamic> toJson() => {
        'entityKey': entityKey,
        'accountKey': accountKey,
        'targetRef': targetRef,
        'approvedVersion': approvedVersion,
        'removed': removed,
      };

  factory MailEntityLink.fromJson(Map<String, dynamic> j) => MailEntityLink(
        entityKey: j['entityKey'] as String? ?? '',
        accountKey: j['accountKey'] as String? ?? '',
        targetRef: j['targetRef'] as String? ?? '',
        approvedVersion: j['approvedVersion'] as int? ?? 1,
        removed: j['removed'] as bool? ?? false,
      );
}

// 💡 登録先のIDは予約の安定IDから決める（同じ予約を何度承認しても同じ予定・シフトになる）。
//   途中で落ちて承認をやり直しても、二重に登録されない。
String mailTargetId(String accountKey, String entityKey) {
  // FNV-1a（32bit）。暗号ではなく、短く安定した識別子が欲しいだけ。
  var h = 0x811c9dc5;
  for (final c in '$accountKey|$entityKey'.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return 'mail-${h.toRadixString(16).padLeft(8, '0')}';
}

// 💡 見本の提案（架空のデータ）。Gmail・AIにつなぐ前に、確認画面を端末で試すためのもの。
//   ⚠️ 実在の人・会社・予約番号を使わない。
List<ScheduleSuggestion> sampleScheduleSuggestions(DateTime now) {
  final base = DateTime(now.year, now.month, now.day).add(const Duration(days: 10));
  DateTime at(int days, int h, [int m = 0]) =>
      DateTime(base.year, base.month, base.day + days, h, m);
  const account = 'sample';
  return [
    ScheduleSuggestion(
      id: 'sample:m1#A-001',
      accountKey: account,
      messageId: 'sample-m1',
      entityKey: 'example-seminar#A-001',
      kind: SuggestionKind.event,
      title: '会社説明会（オンライン）',
      start: at(0, 14),
      end: at(0, 15, 30),
      location: 'オンライン',
      url: 'https://example.com/join',
      evidence: '「ご予約が確定しました」',
      sender: 'サンプル株式会社 採用担当',
      receivedAt: now.subtract(const Duration(days: 1)),
      sample: true,
    ),
    ScheduleSuggestion(
      id: 'sample:m2#B-002',
      accountKey: account,
      messageId: 'sample-m2',
      entityKey: 'example-interview#B-002',
      kind: SuggestionKind.event,
      title: '面接（サンプル商事）',
      start: at(3, 10),
      location: '東京都千代田区（架空）',
      evidence: '「面接日時が確定しました」',
      sender: 'サンプル商事',
      receivedAt: now.subtract(const Duration(days: 2)),
      missing: ['終了時刻が書かれていません'],
      sample: true,
    ),
    ScheduleSuggestion(
      id: 'sample:m3#C-003',
      accountKey: account,
      messageId: 'sample-m3',
      entityKey: 'example-gig#C-003',
      kind: SuggestionKind.shift,
      title: '単発：イベント設営（サンプル）',
      start: at(5, 9),
      end: at(5, 17),
      location: '幕張（架空）',
      evidence: '「勤務が確定しました」',
      sender: 'サンプル派遣',
      receivedAt: now.subtract(const Duration(hours: 5)),
      missing: ['休憩時間が書かれていません'],
      sample: true,
    ),
  ];
}
