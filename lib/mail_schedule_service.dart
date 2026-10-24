// 💡 「メールから予定を探す」の実行（計画書 §5。読み取りはAIを使わない規則の方式）。
//   Gmail から候補のメールを取る → 端末で読む（mail_schedule_rules.dart）→ 提案として保存。
//   登録はしない（確認画面で本人が承認したものだけ AppState が登録する）。
// ⚠️ 取りこぼし（本文の取得失敗・件数の上限）があったら「どこまで確認したか」を進めない。
//   次回、同じ期間をもう一度確認する。見つかった提案は足すだけなので、そのまま出してよい。
import 'package:shared_preferences/shared_preferences.dart';

import 'app_state.dart';
import 'gmail_service.dart';
import 'mail_schedule_rules.dart';

// Gmail 側の窓口（テストで偽物に差し替える）
abstract interface class ScheduleMailSource {
  Future<GoogleAccessState> ensureAccess();
  String? get scheduleAccountKey;
  Future<({List<ScheduleMail> mails, int failed, bool truncated})> fetchScheduleMails(
      {required DateTime after});
}

class _GmailScheduleSource implements ScheduleMailSource {
  final g = GmailService.instance;
  @override
  Future<GoogleAccessState> ensureAccess() => g.ensureAccess();
  @override
  String? get scheduleAccountKey => g.scheduleAccountKey;
  @override
  Future<({List<ScheduleMail> mails, int failed, bool truncated})> fetchScheduleMails(
          {required DateTime after}) =>
      g.withFreshToken(() => g.fetchScheduleMails(after: after));
}

class MailScanResult {
  final int checked; // 読んだメール
  final int added; // 新しく増えた提案
  final int failed; // 取れなかったメール
  final bool truncated; // 件数の上限で取り切れなかった
  final String? error; // 確認できなかった理由（連携切れなど）
  const MailScanResult({
    this.checked = 0,
    this.added = 0,
    this.failed = 0,
    this.truncated = false,
    this.error,
  });

  bool get complete => error == null && failed == 0 && !truncated;

  String get message {
    if (error != null) return error!;
    final head = added > 0 ? '予定の候補が$added件見つかりました' : '新しい予定の候補はありませんでした';
    if (!complete) {
      return '$head（${truncated ? 'メールが多くて' : '$failed通が取れず、'}最後まで確認できていません。もう一度お試しください）';
    }
    return '$head（$checked通を確認）';
  }
}

// 💡 どこまで確認したか（この端末だけの記録。書き出し・ドライブ同期には入れない）。
//   アカウントごとに分ける（別のアカウントに切り替えたら、そのアカウントは初回の扱い）。
const String _kScanAt = 'local_mail_schedule_scan_at';
const Duration kFirstScanWindow = Duration(days: 30); // 初回は過去30日
const Duration kScanOverlap = Duration(hours: 24); // 次からは前回から24時間重ねて取る

Future<DateTime?> lastScheduleScanAt(String accountKey) async {
  final prefs = await SharedPreferences.getInstance();
  return DateTime.tryParse(prefs.getString('$_kScanAt|$accountKey') ?? '');
}

Future<MailScanResult>? _running;

// 同時に押されても1回にまとめる
Future<MailScanResult> scanScheduleMails(AppState app,
    {ScheduleMailSource? source, DateTime? now}) {
  return _running ??= _scan(app, source ?? _GmailScheduleSource(), now ?? DateTime.now())
      .whenComplete(() => _running = null);
}

Future<MailScanResult> _scan(AppState app, ScheduleMailSource src, DateTime now) async {
  final access = await src.ensureAccess();
  if (access == GoogleAccessState.redirecting) {
    return const MailScanResult(error: 'Google連携を復帰しています…もう一度押してください');
  }
  if (access == GoogleAccessState.needsInteraction) {
    return const MailScanResult(error: 'Googleとの連携を更新してください（設定→Google連携）');
  }
  // ⚠️ どのアカウントか分からないまま始めない（別のアカウントの提案と混ざるため）
  final account = src.scheduleAccountKey;
  if (account == null) {
    return const MailScanResult(error: 'Googleアカウントが分かりません。連携し直してください');
  }
  final last = await lastScheduleScanAt(account);
  final after = last != null ? last.subtract(kScanOverlap) : now.subtract(kFirstScanWindow);

  final ({List<ScheduleMail> mails, int failed, bool truncated}) got;
  try {
    got = await src.fetchScheduleMails(after: after);
  } catch (e) {
    return MailScanResult(error: 'メールを確認できませんでした（$e）');
  }

  final today = DateTime(now.year, now.month, now.day);
  final found = <ScheduleSuggestion>[];
  for (final m in got.mails) {
    for (final s in readScheduleMail(m, accountKey: account).suggestions) {
      // 終わった予定の「追加」は出さない（変更・取消は、登録済みに当たりうるので出す）
      final endsAt = s.end ?? s.start;
      if (s.action == SuggestionAction.add && endsAt != null && endsAt.isBefore(today)) continue;
      found.add(s);
    }
  }
  final added = found.isEmpty ? 0 : app.addScheduleSuggestions(found);
  app.pruneScheduleSuggestions(now);

  final result = MailScanResult(
    checked: got.mails.length,
    added: added,
    failed: got.failed,
    truncated: got.truncated,
  );
  if (result.complete) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kScanAt|$account', now.toIso8601String());
  }
  return result;
}
