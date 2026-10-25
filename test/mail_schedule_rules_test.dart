// メールから予定を規則で読み取るテスト（計画書の段階A「評価セット」＋規則の検証）。
// 💡 メールはすべて架空（実在の人・会社・予約番号・URLを使わない）。
//   読めたかどうかだけでなく、「読めないときに推測で埋めず、確認事項にする」ことを確かめる。
// ⚠️ ここで落ちたら、規則を直す前に「どの書き方を読めなくなったか」を確かめる。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_counter_app/mail_schedule_models.dart';
import 'package:my_counter_app/mail_schedule_rules.dart';

final received = DateTime(2026, 11, 1, 10);

ScheduleMail mail(
  String subject,
  String body, {
  String from = 'サンプル予約 <noreply@example.com>',
  DateTime? at,
  String id = 'm',
}) => ScheduleMail(
  id: id,
  subject: subject,
  from: from,
  receivedAt: at ?? received,
  body: body,
);

ScheduleReadResult read(ScheduleMail m) =>
    readScheduleMail(m, accountKey: 'acct');

// 期待する結果（null の項目は確かめない）
class Expect {
  final int count;
  final SuggestionAction? action;
  final SuggestionKind? kind;
  final DateTime? start;
  final DateTime? end;
  final bool? allDay;
  final String? missing; // 確認事項にこの文字が含まれる
  final String? noMissing; // 確認事項にこの文字が含まれない
  final String? title;
  final String? location;
  const Expect({
    this.count = 1,
    this.action,
    this.kind,
    this.start,
    this.end,
    this.allDay,
    this.missing,
    this.noMissing,
    this.title,
    this.location,
  });
}

final cases = <(String, ScheduleMail, Expect)>[
  // ── 予約・説明会・面接の確定 ──
  (
    '説明会の予約確定（年あり・時刻範囲）',
    mail('【予約確定】オンライン会社説明会', '''
サンプル太郎 様
会社説明会のご予約が確定しました。
■日時：2026年11月12日(木) 14:00〜15:30
■会場：オンライン（Zoom）
参加URL：https://zoom.us/j/0000000000
予約番号：A-1001
'''),
    Expect(
      action: SuggestionAction.add,
      kind: SuggestionKind.event,
      start: DateTime(2026, 11, 12, 14),
      end: DateTime(2026, 11, 12, 15, 30),
      noMissing: '年が',
      location: 'オンライン(Zoom)',
    ),
  ),
  (
    '美容院の予約完了（年なし）',
    mail('ご予約完了のお知らせ', '''
ご予約が完了しました。
ご予約日時：11月20日(金) 18:30〜19:30
店舗：サンプルサロン 架空店
メニュー：カット
'''),
    Expect(
      start: DateTime(2026, 11, 20, 18, 30),
      end: DateTime(2026, 11, 20, 19, 30),
      missing: '年が書かれていません',
      title: 'カット',
    ),
  ),
  (
    '面接日時の確定（終了なし）',
    mail('面接日程確定のご連絡', '''
面接日時が確定しましたのでご連絡いたします。
面接日時：2026年11月15日（日）10時00分
場所：東京都架空区1-2-3 サンプルビル5F
'''),
    Expect(start: DateTime(2026, 11, 15, 10), missing: '終了時刻'),
  ),
  (
    '全角の数字とコロン',
    mail('ご予約が確定しました', '''
日時：２０２６年１１月２２日（日）１３：００～１４：００
'''),
    Expect(start: DateTime(2026, 11, 22, 13), end: DateTime(2026, 11, 22, 14)),
  ),
  (
    'スラッシュの日付',
    mail('予約完了', '''
予約が完了しました。
日時: 2026/11/25(水) 9:30-10:00
'''),
    Expect(
      start: DateTime(2026, 11, 25, 9, 30),
      end: DateTime(2026, 11, 25, 10),
    ),
  ),
  (
    '「14時〜15時半」の書き方',
    mail('セミナーお申し込み完了', '''
お申し込みが完了しました。
開催日時：11月18日(水) 14時〜15時半
'''),
    Expect(
      start: DateTime(2026, 11, 18, 14),
      end: DateTime(2026, 11, 18, 15, 30),
    ),
  ),
  (
    '終日のイベント',
    mail('参加確定のお知らせ', '''
イベントへの参加が確定しました。
開催日：2026年11月28日(土) 終日
会場：架空ホール
'''),
    Expect(start: DateTime(2026, 11, 28), allDay: true),
  ),
  (
    '年末に届いた「1月」の予約は翌年',
    mail('ご予約が確定しました', '''
ご予約日時：1月5日(火) 11:00〜12:00
''', at: DateTime(2026, 12, 20)),
    Expect(start: DateTime(2027, 1, 5, 11), noMissing: '曜日'),
  ),
  (
    '日付と曜日が合わない',
    mail('ご予約が確定しました', '''
日時：2026年11月12日(金) 14:00〜15:00
'''),
    Expect(start: DateTime(2026, 11, 12, 14), missing: '曜日が合いません'),
  ),
  (
    'HTMLの表',
    mail(
      'ご予約確定',
      htmlToText('''
<html><body><p>ご予約が確定しました。</p>
<table><tr><td>日時</td><td>2026年11月30日(月) 16:00〜17:00</td></tr>
<tr><td>場所</td><td>架空クリニック</td></tr></table></body></html>
'''),
    ),
    Expect(start: DateTime(2026, 11, 30, 16), end: DateTime(2026, 11, 30, 17)),
  ),
  (
    '予約と料金が同じメール（金額は登録しない）',
    mail('ご予約完了（お支払い方法のご案内）', '''
ご予約が完了しました。
日時：2026年11月14日(土) 19:00〜21:00
お支払い金額：3,000円（当日現地払い）
'''),
    Expect(start: DateTime(2026, 11, 14, 19)),
  ),

  // ── 単発バイト ──
  (
    '単発バイトの勤務確定（集合と勤務が別）',
    mail('【お仕事確定】イベント設営スタッフ', '''
お仕事が確定しました。
勤務日：2026年11月21日(土)
集合時間：8:30
勤務時間：9:00〜17:00
勤務地：架空メッセ 東ホール
お仕事番号：J-2201
''', from: 'サンプル派遣 <job@example.net>'),
    Expect(
      kind: SuggestionKind.shift,
      start: DateTime(2026, 11, 21, 9),
      end: DateTime(2026, 11, 21, 17),
      missing: '集合は',
    ),
  ),
  (
    '単発バイト：休憩が書かれていれば確認事項に出さない',
    mail('勤務確定のお知らせ', '''
勤務が確定しました。
勤務日：11月23日(月)
勤務時間：10:00〜15:00
休憩：45分
'''),
    Expect(kind: SuggestionKind.shift, noMissing: '休憩時間が'),
  ),
  (
    '単発バイト：日をまたぐ夜勤',
    mail('シフト確定', '''
シフトが確定しました。
勤務日：2026年11月26日(木)
勤務時間：22:00〜翌5:00
'''),
    Expect(
      kind: SuggestionKind.shift,
      start: DateTime(2026, 11, 26, 22),
      end: DateTime(2026, 11, 27, 5),
    ),
  ),
  (
    '単発バイト：1通に2日ぶんの勤務',
    mail('お仕事確定のご連絡', '''
以下のお仕事が確定しました。
勤務日：2026年11月7日(土) 9:00〜18:00
勤務日：2026年11月8日(日) 9:00〜18:00
お仕事番号：J-3300
'''),
    Expect(count: 2, kind: SuggestionKind.shift),
  ),

  // ── 確定ではないもの（要確認で出す） ──
  (
    '申込受付だけ',
    mail('お申し込みを受け付けました', '''
お申し込みを受け付けました。主催者の承認後に確定します。
開催日時：2026年12月3日(木) 18:00〜19:00
'''),
    Expect(count: 0),
  ),
  (
    '抽選への応募',
    mail('抽選受付完了', '''
抽選への応募を受付いたしました。結果は後日お知らせします。
公演日：2026年12月10日(木) 18:30
'''),
    Expect(count: 0),
  ),
  (
    '候補日への回答依頼（日時を決めつけない）',
    mail('面接日程調整のお願い', '''
面接の日程調整をお願いします。以下の候補日からご都合をご回答ください。
候補日：11月10日(火) 10:00 / 11月11日(水) 14:00
'''),
    Expect(count: 0),
  ),
  (
    'リマインドだけ（確定の文が無い）',
    mail('【リマインド】明日はご予約日です', '''
明日はご予約日です。
日時：2026年11月12日(木) 14:00〜15:30
予約番号：A-1001
'''),
    Expect(count: 0),
  ),
  (
    '添付にだけ詳細がある',
    mail('説明会参加確定のお知らせ', '''
説明会への参加が確定しました。詳細は添付のPDFをご確認ください。
'''),
    Expect(count: 0),
  ),

  // ── 変更・取消 ──
  (
    '日程の変更（変更後を読む）',
    mail('ご予約日時変更のお知らせ', '''
ご予約の日時変更が完了しました。
変更前：2026年11月12日(木) 14:00〜15:30
変更後：2026年11月13日(金) 10:00〜11:30
予約番号：A-1001
'''),
    Expect(
      action: SuggestionAction.change,
      start: DateTime(2026, 11, 13, 10),
      end: DateTime(2026, 11, 13, 11, 30),
    ),
  ),
  (
    '予約のキャンセル',
    mail('ご予約キャンセル完了のお知らせ', '''
以下のご予約のキャンセルが完了しました。
日時：2026年11月20日(金) 18:30〜19:30
予約番号：B-2002
'''),
    Expect(action: SuggestionAction.cancel),
  ),
  (
    '開催中止',
    mail('【重要】開催中止のお知らせ', '''
誠に勝手ながら、本イベントは開催中止となりました。
開催日：2026年11月28日(土)
'''),
    Expect(action: SuggestionAction.cancel),
  ),
  (
    '勤務の取消',
    mail('お仕事キャンセルのご連絡', '''
誠に申し訳ございません。以下のお仕事は勤務取消となりました。
勤務日：2026年11月21日(土)
お仕事番号：J-2201
'''),
    Expect(action: SuggestionAction.cancel, kind: SuggestionKind.shift),
  ),

  // ── 出さないもの ──
  (
    '求人の募集広告',
    mail('【新着求人】週1からOK！イベントスタッフ募集', '''
未経験歓迎のお仕事を多数掲載中。勤務日：11月30日 9:00〜18:00 など
'''),
    Expect(count: 0),
  ),
  (
    'キャンペーン',
    mail('秋のキャンペーン開催中', '''
ご予約でポイント2倍！ 期間：11月1日〜11月30日
'''),
    Expect(count: 0),
  ),
  (
    'カード利用のお知らせ',
    mail('カード利用のお知らせ', '''
ご利用日時：2026/11/01 12:34 ご利用金額：1,200円
'''),
    Expect(count: 0),
  ),
  (
    '振込入金のお知らせ',
    mail('振込入金のお知らせ', '''
お客さまの口座へ振込入金がありました。
'''),
    Expect(count: 0),
  ),
  (
    '英語のメール（未対応）',
    mail('Your reservation is confirmed', '''
Your reservation is confirmed for Nov 12, 2:00 PM.
'''),
    Expect(count: 0),
  ),
  // ── 実メールの書き方を架空化して足したもの（2026-10-25 本人のGmailで試し読みして見つけた） ──
  (
    '字の間に空白のあるラベル「【日　時】」と「ご予約いただきありがとう」',
    mail('【サンプル社】会社説明会予約受付完了のお知らせ', '''
この度は会社説明会にご予約いただきありがとうございます。
【日　時】2026年 11月 19日(木) 16:00～17:30
※ご都合が悪くなった場合は、前日までにキャンセルをお願いいたします。
'''),
    Expect(
      start: DateTime(2026, 11, 19, 16),
      end: DateTime(2026, 11, 19, 17, 30),
      noMissing: '候補日',
      title: '会社説明会',
    ),
  ),
  (
    '「イベント：」「会場名：」の書き方（終了時刻なし）',
    mail('ご予約ありがとうございました', '''
この度は＜web会社説明会＞にご予約いただき、誠にありがとうございます。
イベント：web会社説明会
日　時 ：2026/11/14(土) 14:30
会場名：WEB
もしご都合が悪くなった場合は、マイページよりキャンセル・変更の手続きをお願いいたします。
'''),
    Expect(
      start: DateTime(2026, 11, 14, 14, 30),
      title: 'web会社説明会',
      location: 'WEB',
      missing: '終了時刻',
      noMissing: '確定していません',
    ),
  ),
  (
    '飛行機の予約（発 → 着）',
    mail('サンプル航空 予約完了', '''
■ご利用便情報
・2026年12月5日(土) XX 123便 [予約番号：0001]
那覇 発 9:00 → 羽田 着 11:30
ご予約ありがとうございました。
'''),
    Expect(start: DateTime(2026, 12, 5, 9), end: DateTime(2026, 12, 5, 11, 30)),
  ),
  (
    '決済サービスの「支払いを受け付けました」は出さない',
    mail('サンプル決済 - 支払い受付のお知らせ', '''
下記商品について、サンプル決済での支払いを受け付けました。
売上はまだ確定していない状態のため、後ほどキャンセルとなることがあります。
'''),
    Expect(count: 0),
  ),
  (
    '引用の中の古い日時は読まない',
    mail('Re: ご予約が確定しました', '''
ご予約が確定しました。
日時：2026年11月19日(木) 15:00〜16:00

> 日時：2026年10月1日(木) 10:00〜11:00
> 以前のご予約
'''),
    Expect(start: DateTime(2026, 11, 19, 15)),
  ),
];

void main() {
  test('評価セットは30件以上ある', () => expect(cases.length, greaterThanOrEqualTo(30)));

  for (final (name, m, e) in cases) {
    test(name, () {
      final r = read(m);
      expect(r.suggestions, hasLength(e.count), reason: '理由: ${r.skipReason}');
      if (e.count == 0) return;
      final s = r.suggestions.first;
      if (e.action != null) expect(s.action, e.action);
      if (e.kind != null) expect(s.kind, e.kind);
      if (e.start != null) expect(s.start, e.start);
      if (e.end != null) expect(s.end, e.end);
      if (e.allDay != null) expect(s.allDay, e.allDay);
      if (e.missing != null) {
        expect(
          s.missing.join(' / '),
          contains(e.missing),
          reason: '確認事項: ${s.missing}',
        );
      }
      if (e.noMissing != null) {
        expect(
          s.missing.join(' / '),
          isNot(contains(e.noMissing)),
          reason: '確認事項: ${s.missing}',
        );
      }
      if (e.title != null) expect(s.title, e.title);
      if (e.location != null) expect(s.location, e.location);
      // 根拠は必ず付ける（何を見て判断したか本人が分かるように）
      expect(s.evidence, isNotEmpty);
    });
  }

  group('同じ予約の照合', () {
    test('予約番号があれば、確定・変更・取消が同じ予約（entityKey）になる', () {
      final a = read(
        mail(
          'ご予約が確定しました',
          '日時：2026年11月12日(木) 14:00〜15:30\n予約番号：A-1001',
          id: 'm1',
        ),
      );
      final b = read(
        mail(
          'ご予約日時変更のお知らせ',
          'ご予約の日時変更が完了しました。\n変更後：2026年11月13日(金) 10:00〜11:30\n予約番号：A-1001',
          id: 'm2',
        ),
      );
      expect(a.suggestions.single.entityKey, b.suggestions.single.entityKey);
      expect(
        a.suggestions.single.id,
        isNot(b.suggestions.single.id),
        reason: '提案は別（メールが違う）',
      );
    });

    test('同じメールを読み直しても同じ提案ID', () {
      final m = mail('ご予約が確定しました', '日時：2026年11月12日(木) 14:00〜15:30', id: 'm7');
      expect(read(m).suggestions.single.id, read(m).suggestions.single.id);
    });

    test('予約番号が無ければ「送信元＋開始日時」で同じ予約とみなす（前日の案内を二重に出さない）', () {
      final a = read(
        mail('ご予約が確定しました', '日時：2026年11月12日(木) 14:00〜15:30', id: 'x1'),
      );
      final b = read(
        mail(
          '明日の説明会のご案内',
          'ご予約いただいた説明会の前日となりました。\n日時：2026年11月12日(木) 14:00〜15:30',
          id: 'x2',
        ),
      );
      final c = read(
        mail(
          'ご予約が確定しました',
          '日時：2026年11月12日(木) 14:00〜15:30',
          from: '別の会社 <info@another.example>',
          id: 'x3',
        ),
      );
      expect(a.suggestions.single.entityKey, b.suggestions.single.entityKey);
      expect(
        a.suggestions.single.entityKey,
        isNot(c.suggestions.single.entityKey),
        reason: '送信元が違えば別の予約',
      );
    });
  });

  test('会議サービス以外のURLは拾わない（追跡URL・広告URL）', () {
    final r = read(
      mail('ご予約が確定しました', '''
日時：2026年11月12日(木) 14:00〜15:30
詳しくは https://track.example.com/click?id=123 をご覧ください
'''),
    );
    expect(r.suggestions.single.url, isEmpty);
  });
}
