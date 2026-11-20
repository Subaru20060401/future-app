import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'card_styles.dart';
import 'finance/billing_dates.dart';
import 'finance/forecast.dart';
import 'japanese_holidays.dart';
import 'workplace_styles.dart';
import 'mail_schedule_models.dart';
export 'mail_schedule_models.dart';
import 'models/calendar_items.dart';
import 'models/money.dart';
import 'models/shift.dart';
import 'models/workplace.dart';
// 💡 データ型は lib/models/ に分けた。今までどおり app_state.dart だけを import すれば使えるよう再 export する。
export 'models/calendar_items.dart';
export 'models/money.dart';
export 'models/shift.dart';
export 'models/workplace.dart';
export 'finance/forecast.dart' show ForecastLine, MonthForecast, Certainty, CertaintyLabel, ForecastKind;
import 'money_format.dart';

// ───────────────────────── CSV取り込み用の補助 ─────────────────────────
// シフトCSVの1行（給与列を「答え」として持ち、設定の逆算に使う）
class _CsvShiftRow {
  final String workplace;
  final DateTime start;
  final DateTime end;
  final int breakMinutes;
  final int hourlyWage;
  final int earnings;

  _CsvShiftRow({
    required this.workplace,
    required this.start,
    required this.end,
    required this.breakMinutes,
    required this.hourlyWage,
    required this.earnings,
  });

  double get hours {
    final m = end.difference(start).inMinutes - breakMinutes;
    return m <= 0 ? 0 : m / 60.0;
  }

  double get nightHours => nightOverlapMinutes(start, end) / 60.0;

  bool get isWeekend =>
      start.weekday == DateTime.saturday || start.weekday == DateTime.sunday;

  // ShiftData.wageEarnings と同じ計算（交通費は含めない）
  int wageWith(double nm, double om, double hm) {
    final h = hours;
    if (h <= 0) return 0;
    var total = hourlyWage * h;
    if (nm > 1.0) total += nightHours * hourlyWage * (nm - 1.0);
    if (om > 1.0 && h > 8) total += (h - 8) * hourlyWage * (om - 1.0);
    if (hm > 1.0 && isWeekend) total += h * hourlyWage * (hm - 1.0);
    return total.round();
  }
}

// 逆算で求めた勤務先の給料設定
class _WageFit {
  final int transportPerDay;
  final double nightMultiplier;
  final double overtimeMultiplier;
  final double holidayMultiplier;

  const _WageFit({
    this.transportPerDay = 0,
    this.nightMultiplier = 1.0,
    this.overtimeMultiplier = 1.0,
    this.holidayMultiplier = 1.0,
  });
}

// CSV取り込みの結果（画面に出す件数のまとめ）
class CsvImportResult {
  final int imported; // 取り込んだ件数
  final int skipped; // 同じシフトが既にあってスキップした件数
  final int failed; // 行として読めなかった件数
  final int mismatched; // 給与を再現できなかった件数

  const CsvImportResult({
    this.imported = 0,
    this.skipped = 0,
    this.failed = 0,
    this.mismatched = 0,
  });
}

// カンマ区切りを1行ぶん分解する（"" のエスケープに対応）
List<String> _splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(c);
      }
    } else if (c == '"') {
      inQuotes = true;
    } else if (c == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(c);
    }
  }
  out.add(buf.toString());
  return out;
}

// 💡 カレンダー連携のフック。実装は lib/google_calendar_sync.dart（Googleカレンダー）。
//   AppState はプラットフォーム依存を持たないよう、この抽象だけ参照する（テストでは null）。
abstract class CalendarSyncHook {
  Future<bool> enableAndSyncAll();
  void upsertShift(DateTime date, ShiftData shift);
  // 💡 待てる版（通知の設定を変えたときに、先のシフトを1件ずつ書き直す）
  Future<void> syncShiftNow(DateTime date, ShiftData shift);
  void upsertEvent(EventData event);
  void deleteEvent(String calendarEventId);
  // 給料日・引き落とし日などの特殊イベント同期。keyは内部管理用(カレンダーIDを返す)。
  // remind=true なら、その日に通知が出るようにする（カレンダー側の既定任せにしない）。
  Future<String?> upsertSpecialEvent({
    required String existingCalId,
    required String title,
    required DateTime date,
    required String description,
    bool remind = false,
    // 💡 通知の時刻を細かく決めたいとき（その日の0時から何分前か）。remind より優先
    List<int>? reminderMinutes,
  });
}

// 💡 シフトの通知をいつ出すか（Googleカレンダーの通知として書き出す）
enum ShiftReminder {
  calendarDefault, // カレンダーの既定のまま（以前の動き）
  none, // 通知しない
  hourBefore, // 1時間前
  eveningBefore, // 前日の21時
  both, // 前日の21時と1時間前
}

// 💡 シフトの開始時刻から、カレンダーの通知（開始の何分前か）を決める。
//   null＝カレンダーの既定に任せる、空＝通知しない。
List<int>? shiftReminderMinutes(ShiftReminder mode, DateTime start) {
  int evening() => start
      .difference(DateTime(start.year, start.month, start.day - 1, 21))
      .inMinutes;
  switch (mode) {
    case ShiftReminder.calendarDefault:
      return null;
    case ShiftReminder.none:
      return const [];
    case ShiftReminder.hourBefore:
      return const [60];
    case ShiftReminder.eveningBefore:
      return [evening()];
    case ShiftReminder.both:
      return [evening(), 60];
  }
}

// 💡 残高不足の通知の時刻（終日の予定なので「その日の0時から何分前か」）。
//   3日前の9時と前日の9時。ずらす・入金するなどの手を打てる余裕を持たせる。
const List<int> kShortfallReminderMinutes = [3 * 1440 - 9 * 60, 1440 - 9 * 60];

// 💡 シフト・予定・やることを日ごとに入れる箱のキー（"2026-10-22"）。
//   画面ごとに作ると書式がずれたときに別の日の箱を見てしまうので、ここ1か所で作る。
String dateKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

// ════════════════════════ AppState ════════════════════════
// 💡 ホームの「確認待ち」に並べる1件。
//   保存はしない。開くたびに未処理の入出金などから組み立てる
//   （金額や状態を二重に持つと、元のデータと食い違うため）。
// 確認待ちの引き落としが、入力した残高に含まれているか（推定）
enum DrawReflection {
  maybeIncluded, // 含まれている可能性がある（引落日が残高を入力した日より前）
  likelyNotIncluded, // まだ含まれていない見込み（引落日が残高を入力した日より後）
  unknown, // 判断できない（同じ日・残高を入力した記録が無い）
}

// 保存の状態（null＝正常）
enum StorageIssue {
  saveFailed, // 直近の保存に失敗した（端末には前の整った状態か、次の起動で戻せる一時保存がある）
  recoveryPending, // 途中で止まった保存を戻せていない（中身は記録から読んだ整った状態。端末の保存は混ざっている）
  unrecoverable, // 戻すための記録が壊れていた（端末の保存が混ざっている可能性。取り込み直しが必要）
}

class StorageWriteFailure implements Exception {
  StorageWriteFailure(this.stage, this.cause);
  final String stage; // どの段階で失敗したか（一時保存・復旧点・保存）
  final Object cause;
  @override
  String toString() => '$stageに失敗しました: $cause';
}

// 💡 取り込み中（ドライブ・バックアップ・貼り付け）は家計データの変更を受け付けない。
//   ⚠️ 受け付けてから取り込みの失敗で巻き戻すと「入力できたのに消えた」になる。変更は始める前に断る。
class DataLockedException implements Exception {
  DataLockedException(this.label);
  final String label; // いま何をしているか（「ドライブから取り込んでいます」など）
  @override
  String toString() => '$label。終わるまで変更できません';
}

/// 取り込みの間だけ持つ鍵。持っている処理（取り込み本体）だけが家計データを書き換えられる。
class DataLock {
  DataLock._(this.label);
  final String label;
}

// 💡 起動時の読み込み用: 戻すべき記録（一時保存・復旧点）を端末に書き戻せなかったときは、
//   その記録の値を優先して読む（混ざった保存を正常なデータとして読まない）。
class _PrefsView {
  _PrefsView(this.prefs, this.overlay);
  final SharedPreferences prefs;
  final Map<String, Object>? overlay;
  Object? _o(String k) => overlay?[k];
  String? getString(String k) => overlay != null && overlay!.containsKey(k) ? _o(k) as String? : prefs.getString(k);
  int? getInt(String k) => overlay != null && overlay!.containsKey(k) ? _o(k) as int? : prefs.getInt(k);
  bool? getBool(String k) => overlay != null && overlay!.containsKey(k) ? _o(k) as bool? : prefs.getBool(k);
  List<String>? getStringList(String k) => overlay != null && overlay!.containsKey(k)
      ? [for (final e in (_o(k) as List)) '$e']
      : prefs.getStringList(k);
}

// 引き落としの請求の月の決まり方
enum BillMonthStatus {
  matched, // 設定の引落日から一意に決まった
  userChosen, // 利用者が選んだ
  unresolved, // 判定できない（日付の月として扱い、確認待ちに出す）
  noSetting, // 引落日の設定が無い（日付の月として扱う）
}

enum HomeNoticeKind {
  draw, // 引き落としの反映待ち
  deposit, // 入金の反映待ち（メールに金額が無いので入力が要る）
  plannedIncome, // 予定入金の受け取り確認
  installmentWithoutCard, // カード未設定の分割払い（予想から漏れる可能性）
  scheduleSuggestion, // メールから見つけた予定・単発バイトの提案（承認するまで何も登録しない）
  bankBillMonthUnknown, // 請求の月を判定できない銀行確定（利用者が選ぶ）
}

class HomeNotice {
  final HomeNoticeKind kind;
  final String title;
  final String detail;
  final DateTime? date;
  final int? amount;
  // 操作に使う元データ（種類に応じてどれか1つ）
  final ({String id, String label, int amount, DateTime date})? draw;
  final DepositNotice? deposit;
  final ({PlannedIncome income, DateTime date})? planned;
  final ScheduleSuggestion? suggestion;
  final Payment? bankRecord;

  const HomeNotice({
    required this.kind,
    required this.title,
    required this.detail,
    this.date,
    this.amount,
    this.draw,
    this.deposit,
    this.planned,
    this.suggestion,
    this.bankRecord,
  });
}

// 💡 日付つきのお金の動き（予想の谷を見つけるためだけに使う）。
//   amount は ＋が入金・−が引き落とし。
class CashEvent {
  final DateTime date;
  final String label;
  final int amount;
  const CashEvent({required this.date, required this.label, required this.amount});
}

class AppState extends ChangeNotifier {
  final Map<String, List<ShiftData>> shifts = {};
  final List<Workplace> workplaces = [];
  final Map<String, List<EventData>> events = {};

  // Appleカレンダー自動連携（ON/OFF）と、その実装フック。
  bool calendarAutoSync = false;
  CalendarSyncHook? calendarSync;
  // 給料日・引き落とし日のカレンダーイベントID（key="payday_WPID_YYYYMM" or "payment_CARDNAME_YYYYMM"）
  final Map<String, String> specialCalendarIds = {};

  // 自動バックアップ
  bool autoBackupEnabled = true;
  DateTime? lastAutoBackupAt;

  // 翌々月の予想残高を表示するか（#3 非表示にできる）
  bool showMonthAfterNext = true;

  // 財布の現金機能を表示するか（設定でON/OFF）
  bool showWalletCash = true;

  // アプリの背景テーマ（グラデーションのキー）。既定はピンク。
  String backgroundTheme = 'pink';

  // 💡 カード別引き落とし日。**初期値をここに埋め込まない**。
  //   埋め込むと (1)既定のカードを二度と削除できない
  //   (2)別端末で消したカードが同期のたびに復活する、という不具合になる。
  //   代わりに、初回起動時だけ下の種をデータとして書き込む。
  Map<String, int> cardPaymentDays = {};

  // 初回起動時にだけ配る初期カード（以後はただのデータ。削除も同期もできる）
  static const Map<String, int> kSeedCardPaymentDays = {
    '三井OLIVE': 26,
    '楽天カード': 29,
    'PayPayカード': 27,
    'Amazonマスター': 26, // 三井と同じ
    'メルカード': 26, // 三井と同じ
  };

  // ───── Googleドライブ同期 ─────
  // 💡 家計データなので「新しい方で黙って上書き」はしない。
  //   dataUpdatedAt（この端末で最後に変更した時刻）と
  //   driveSyncedAt（最後にドライブとそろえた時刻）を比べて
  //   「こちらだけ変わった／向こうだけ変わった／両方変わった」を判定する。
  bool driveSyncEnabled = false;
  // 💡 起動時にGoogleログインを求めるか（ONだとログイン後にドライブから復元される）。
  //   ⚠️ 他人からデータを守る仕組みではない（データはこの端末の中にある）。
  //     端末を他人が触るのを防ぎたいときはパスコードロック（LockService）を使う。
  bool requireGoogleLogin = false;
  DateTime? dataUpdatedAt; // この端末のデータが最後に変わった時刻
  DateTime? driveSyncedAt; // 最後にドライブとそろえた時刻
  DateTime? driveKnownRemoteAt; // そのときのドライブ側の更新時刻

  // 同期の表示に使う端末名（どの端末が書いたか分かるように）
  String get deviceLabel {
    if (kIsWeb) return 'ブラウザ（Web版）';
    return Platform.isIOS ? 'iPhone/iPad' : 'この端末';
  }

  Future<void> markDriveSynced({required DateTime localAt, required DateTime remoteAt}) async {
    driveSyncedAt = localAt;
    driveKnownRemoteAt = remoteAt;
    notifyListeners();
    await _saveDriveSyncState();
  }

  Future<void> setRequireGoogleLogin(bool on) async {
    requireGoogleLogin = on;
    await _saveDriveSyncState();
    notifyListeners();
  }

  Future<void> setDriveSyncEnabled(bool on) async {
    driveSyncEnabled = on;
    await _saveDriveSyncState();
    notifyListeners();
  }

  Future<void> _saveDriveSyncState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_drive_sync_enabled', driveSyncEnabled);
    await prefs.setBool('saved_require_google_login', requireGoogleLogin);
    // ⚠️ saved_data_updated_at（家計データの変更時刻）は saveData の列だけが書く（ここで書くと順序が崩れる）
    await prefs.setString('saved_drive_synced_at', driveSyncedAt?.toIso8601String() ?? '');
    await prefs.setString(
        'saved_drive_remote_at', driveKnownRemoteAt?.toIso8601String() ?? '');
  }

  // 💡 カード別の締め日（1〜28、31＝月末締め）。未設定＝31（従来どおり暦月で集計）。
  //   締め日を月末以外にすると、その月の引き落としは
  //   「前々月の締め日の翌日 〜 前月の締め日」の利用ぶんになる。
  Map<String, int> cardClosingDays = {};
  // 💡 カードごとの自分の画像（アイコン用に縮小した PNG を base64 で）。無いカードは既定のマーク。
  //   キーはカード名（名前を変える・まとめると付け替わる）。書き出し・ドライブ同期にも入る。
  Map<String, String> cardIcons = {};

  final Map<String, List<TodoData>> todos = {};
  List<Payment> payments = [];
  List<Installment> installments = [];
  List<Subscription> subscriptions = [];
  List<Loan> loans = [];
  List<PlannedExpense> plannedExpenses = [];
  final Set<String> paidPlannedExpenseKeys = {};
  // 💡 メールから見つけた予定の提案と、予約⇔登録先の対応（mail_schedule_models.dart）
  List<ScheduleSuggestion> scheduleSuggestions = [];
  final Map<String, MailEntityLink> mailEntityLinks = {};
  List<Withdrawal> withdrawals = [];

  int currentBalance = 0;
  // 財布の中の現金（手動編集）。口座残高とは別に保持し、予想残高の起点に加える。
  int walletCash = 0;
  // #6 残高を最後に編集した日時。これより後のイベント（デビット/引き落とし/給料）だけ
  //    予測に反映する（編集時点の残高には過去分が既に含まれているため二重計上を防ぐ）。
  DateTime? balanceUpdatedAt;
  // 💡 利用者が通帳・アプリの残高を見て「残高そのもの」を入力した時刻。
  //   balanceUpdatedAt（予想のゲート）は入金・引き落としの反映でも進むので、
  //   「この引き落としは入力した残高に含まれているか」の判断には使えない
  //   （1件引いただけで、他の引き落としまで含まれているように見えてしまう）。
  //   旧データには無い（null＝判断できない）。
  DateTime? balanceEnteredAt;

  // カードごとの分割金利（年率%）
  final Map<String, double> cardInterestRates = {};
  double interestRateOf(String card) => cardInterestRates[card] ?? 15.0;
  void setInterestRate(String card, double rate) {
    _ensureEditable();
    cardInterestRates[card] = rate;
    saveData();
    notifyListeners();
  }

  // 初回の全期間取得が済んだか（2回目以降は先月+今月だけ取得）
  bool gmailFirstSyncDone = false;
  void markGmailSynced() {
    _ensureEditable();
    if (!gmailFirstSyncDone) {
      gmailFirstSyncDone = true;
      saveData();
    }
  }

  // 分割へ変換済みの明細（再取得で復活させないため）。
  //   dupKey（カード|金額|日時|種別）は日時・金額が変わると外れるので、
  //   メール由来の一意キー(sourceId)でも照合する（削除の墓石と同じ二重構え）。
  final Set<String> convertedPaymentKeys = {};
  final Set<String> convertedSourceIds = {};

  // 💡 残高へ畳み込み済みのデビット（もう差し引かない）。
  // ⚠️ 基準日(balanceUpdatedAt)は「日付」単位なので、同じ日のデビットは
  //   畳み込んだ後もまだ「基準日より後」と判定される。記録しておかないと
  //   二重に引かれる。キーは削除の墓石と同じ dupKey（取り込みの作り直しで
  //   明細のidが変わっても外れないように）。
  final Set<String> foldedDebitKeys = {};

  // ───── ゴミ箱（削除した支払い）と墓石（更新で復活させない）─────
  // 削除した支払いを退避するフォルダ（PCのゴミ箱と同じ。復元可能）。
  List<Payment> trashedPayments = [];
  // 更新(Gmail取込)で再追加させないための墓石。
  //   sourceId（メール由来の一意キー）と dupKey（カード|金額|日時|種別）の両方で照合。
  final Set<String> deletedSourceIds = {};
  final Set<String> deletedDupKeys = {};

  // 💡 時計を差し替えられるようにする（テストで「今日」を固定するため）。
  //   ⚠️ 計算・判定は必ず clockNow() を使う。DateTime.now() を直接読むと、
  //     テストの日付と食い違い、実行した日によって結果が変わるテストになる。
  //     ID の採番（_id など）だけは時計と無関係に一意であればよいので DateTime.now() のまま。
  AppState({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    loadData();
  }

  final DateTime Function() _clock;

  // いまの日時（注入した時計）
  DateTime clockNow() => _clock();

  // 💡 端末に保存したデータを読み終えたか。
  // ⚠️ 読み終える前の画面は初期値（残高0円・明細なし）なので、そのまま出すと
  //   「0円→実際の金額」と一瞬切り替わって見える。ホームは読み終えるまで待つ。
  //   起動時の同期（Gmail・ドライブ）も、読み終えてから始める（空の状態に重ねないため）。
  bool isLoaded = false;
  final Completer<void> _loaded = Completer<void>();
  Future<void> get ready => _loaded.future;

  String _formatDate(DateTime date) => dateKey(date);

  // 💡 一括追加でも衝突しないユニークID（マイクロ秒＋連番）
  int _idCounter = 0;
  String _id() => '${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

  // Appleカレンダー自動連携のON/OFF。ON時は権限取得＋既存を全同期。
  Future<bool> setCalendarAutoSync(bool on) async {
    _ensureEditable();
    calendarAutoSync = on;
    saveData();
    notifyListeners();
    if (on && calendarSync != null) {
      final ok = await calendarSync!.enableAndSyncAll();
      if (!ok) {
        // 権限が得られなければOFFへ戻す
        calendarAutoSync = false;
        saveData();
        notifyListeners();
      } else {
        await syncPaydaysToCalendar(); // 給料日も書き出す
        await syncShortfallsToCalendar(); // 残高不足の見込みも
      }
      return ok;
    }
    return true;
  }

  // ───── 給料日をGoogleカレンダーへ（「💰 給料日」の通知） ─────
  // ⚠️ 以前の syncSpecialEventsToCalendar はどこからも呼ばれておらず、
  //   設定に「給料日を書き出し」とあるのに一度もイベントが作られていなかった。
  //   さらにイベントIDを保存していなかったので、動いていたら起動のたびに重複していた。
  //   （引き落としの部分は「利用日」まで引き落としとして書く作りだったので、使わずに外した）
  // 💡 キー＝勤務先×労働月。そこに置いたイベントのIDと「置いた日付・内容」を覚える。
  //   ・給料日を変えたら、まだ来ていない給料日のイベントは新しい日付へ移す
  //   ・もう来た給料日（その日付で通知済み）は動かさない（同じ月の通知が二度出るため）
  //   ・日付も内容も同じなら書き直さない（API節約）
  final Map<String, String> specialCalendarSigs = {};
  bool _paydaySyncRunning = false;
  bool _paydaySyncAgain = false;

  // 置いた日付・内容の記録（"2026-10-25|タイトル|説明"）から日付だけ取り出す
  static DateTime? _sigDate(String? sig) =>
      sig == null ? null : DateTime.tryParse(sig.split('|').first);

  Future<void> syncPaydaysToCalendar({DateTime? now}) async {
    if (!calendarAutoSync || calendarSync == null) return;
    // ⚠️ 同時に2回走ると、どちらも「まだ無い」と判断して同じ給料日を2つ作る。
    //   走っている間に頼まれたら、終わってからもう一度だけ回す。
    if (_paydaySyncRunning) {
      _paydaySyncAgain = true;
      return;
    }
    _paydaySyncRunning = true;
    try {
      do {
        _paydaySyncAgain = false;
        await _syncPaydaysOnce(now ?? clockNow());
      } while (_paydaySyncAgain);
    } finally {
      _paydaySyncRunning = false;
    }
  }

  Future<void> _syncPaydaysOnce(DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    final gen = _dataGeneration; // 💡 この回が見ている中身（取り込みで置き換わったら、やり直す）
    // 先月〜3か月先の労働月ぶん（給料日はそれぞれの入金月に来る）
    for (var dm = -1; dm <= 3; dm++) {
      final m = DateTime(now.year, now.month + dm);
      for (final entry in paydaysInMonth(m)) {
        final key = 'payday_${entry.workplace.id}_${DateFormat('yyyyMM').format(m)}';
        final existingId = specialCalendarIds[key] ?? '';
        final placed = _sigDate(specialCalendarSigs[key]);
        // ⚠️ もう来た給料日は動かさない（その日付で通知済み）
        if (existingId.isNotEmpty && placed != null && placed.isBefore(today)) continue;
        final title = '💰 給料日（${entry.workplace.name}）';
        final desc = '${m.month}月分 ¥${yenNum(entry.amount)}';
        final sig = '${dateKey(entry.date)}|$title|$desc';
        if (existingId.isNotEmpty && specialCalendarSigs[key] == sig) continue;
        final calId = await calendarSync!.upsertSpecialEvent(
          existingCalId: existingId,
          title: title,
          date: entry.date,
          description: desc,
          remind: true, // 給料日の当日に通知する
        );
        // 💡 作った予定の ID は、取り込み中なら終わるまで待ってから記録する（捨てると次に重複して作る）
        if (calId != null &&
            !await _recordSpecialEvent(key, calId, sig, gen,
                stillWanted: () => _paydayKeysOf(now).contains(key))) {
          _paydaySyncAgain = true; // 取り込みで中身が変わった → 新しい中身でやり直す
          return;
        }
      }
    }
    if (gen != _dataGeneration) _paydaySyncAgain = true;
  }

  // いまの中身で給料日の通知を置くキー（勤務先×労働月。_syncPaydaysOnce と同じ範囲）
  Set<String> _paydayKeysOf(DateTime now) => {
        for (var dm = -1; dm <= 3; dm++)
          for (final entry in paydaysInMonth(DateTime(now.year, now.month + dm)))
            'payday_${entry.workplace.id}_${DateFormat('yyyyMM').format(DateTime(now.year, now.month + dm))}',
      };

  // 自動の処理（カレンダーへの書き出し）の記録。取り込み中は終わるまで待つ（runWhenEditable）。
  // 戻り値: この回の中身のまま記録できたら true。取り込みで中身が変わっていたら false（呼び出し側はやり直す）。
  // ⚠️ 中身が変わっていたら、作った予定の扱いは取り込んだ中身で決める:
  //   ・取り込んだ中身に同じキーの別の予定がある → こちらで作った予定を消す（二重にしない。取り込んだ方は残す）
  //   ・無い、かつ取り込んだ中身でもそのキーの通知が要る（stillWanted） → 記録する（内容はやり直しで決め直す）
  //   ・無い、かつ要らない（勤務先が消えた・足りるようになった など） → 作った予定を消し、記録しない
  //   ⚠️ 以前は「無ければ記録し、やり直しで片付ける」だったが、給料日にはその片付けが無く、
  //     消した勤務先のキーと通知が残っていた（GPT 再レビュー f8a716c）。片付けに頼らず、ここで判定する。
  Future<bool> _recordSpecialEvent(String key, String calId, String sig, int gen,
          {required bool Function() stillWanted}) =>
      runWhenEditable(() {
        if (gen != _dataGeneration) {
          final existing = specialCalendarIds[key] ?? '';
          if (existing.isNotEmpty && existing != calId) {
            calendarSync?.deleteEvent(calId);
          } else if (existing.isEmpty) {
            if (stillWanted()) {
              specialCalendarIds[key] = calId;
              specialCalendarSigs.remove(key); // 内容は新しい中身で決め直す（やり直しで書き直される）
              saveData();
            } else {
              calendarSync?.deleteEvent(calId);
            }
          }
          return false;
        }
        specialCalendarIds[key] = calId;
        specialCalendarSigs[key] = sig;
        saveData();
        return true;
      });

  // 💡 勤務先を消したら、まだ来ていない給料日のイベントも消す（通知が残らないように）
  void _removePaydayEventsOf(String workplaceId, DateTime today) {
    final prefix = 'payday_${workplaceId}_';
    for (final key in specialCalendarIds.keys.where((k) => k.startsWith(prefix)).toList()) {
      final placed = _sigDate(specialCalendarSigs[key]);
      if (calendarAutoSync && (placed == null || !placed.isBefore(today))) {
        calendarSync?.deleteEvent(specialCalendarIds[key]!);
      }
      specialCalendarIds.remove(key);
      specialCalendarSigs.remove(key);
    }
  }

  // ───── シフト前の通知 ─────
  ShiftReminder shiftReminder = ShiftReminder.calendarDefault;

  List<int>? shiftReminderFor(ShiftData s) => shiftReminderMinutes(shiftReminder, s.start);

  // 💡 変えたら、まだ始まっていないシフトのカレンダー予定を書き直す（通知の時刻を揃える）。
  //   ⚠️ 終わったシフトは触らない（通知済み・API節約）。1件ずつ待つ（まとめて投げると混み合う）。
  Future<void> setShiftReminder(ShiftReminder mode) async {
    shiftReminder = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('saved_shift_reminder', mode.index);
    notifyListeners();
    final sync = calendarSync;
    if (!calendarAutoSync || sync == null) return;
    final now = clockNow();
    for (final entry in shifts.entries) {
      final d = DateTime.tryParse(entry.key);
      if (d == null) continue;
      for (final shift in List<ShiftData>.of(entry.value)) {
        if (shift.start.isAfter(now)) await sync.syncShiftNow(d, shift);
      }
    }
  }

  // ───── 残高不足の通知 ─────
  // 💡 引き落としで残高が足りなくなる見込みの日を、カレンダーに通知付きで置く。
  //   サーバーが無いので、アプリを閉じていても届くのはカレンダーの通知だけ。
  //   ・見込みが無くなったら（入金・残高更新など）まだ来ていない予定は消す
  //   ・不足額が変わったら書き直す。同じ内容なら書かない（API節約）
  //   ・もう来た日は動かさない（通知済み）
  //   ⚠️ タイトルに金額を入れない（ロック画面の通知に出るため）。金額は説明欄へ。
  bool shortfallAlerts = true;
  bool _shortfallSyncRunning = false;
  bool _shortfallSyncAgain = false;

  Future<void> setShortfallAlerts(bool on) async {
    shortfallAlerts = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_shortfall_alerts', on);
    notifyListeners();
    await syncShortfallsToCalendar();
  }

  Future<void> syncShortfallsToCalendar({DateTime? now}) async {
    if (!calendarAutoSync || calendarSync == null) return;
    // ⚠️ 同時に2回走ると同じ日の予定を2つ作る。走っている間は後でもう一度だけ回す。
    if (_shortfallSyncRunning) {
      _shortfallSyncAgain = true;
      return;
    }
    _shortfallSyncRunning = true;
    try {
      do {
        _shortfallSyncAgain = false;
        await _syncShortfallsOnce(now ?? clockNow());
      } while (_shortfallSyncAgain);
    } finally {
      _shortfallSyncRunning = false;
    }
  }

  static const _shortfallPrefix = 'shortfall_';

  // いまの中身で不足の通知を置くキー（_syncShortfallsOnce と同じ）
  Set<String> _shortfallKeysOf() => {
        if (shortfallAlerts)
          for (final day in shortfallDaysAhead())
            '$_shortfallPrefix${DateFormat('yyyyMMdd').format(day.date)}',
      };

  Future<void> _syncShortfallsOnce(DateTime now) async {
    final today = DateTime(now.year, now.month, now.day);
    final gen = _dataGeneration; // 💡 この回が見ている中身（取り込みで置き換わったら、やり直す）
    final wanted = <String>{};
    if (shortfallAlerts) {
      for (final day in shortfallDaysAhead()) {
        final key = '$_shortfallPrefix${DateFormat('yyyyMMdd').format(day.date)}';
        wanted.add(key);
        final existingId = specialCalendarIds[key] ?? '';
        const title = '⚠️ 引き落としで残高が足りない見込み';
        final desc = '${day.labels.join('・')}の引き落としで '
            '¥${yenNum(-day.balance)} 足りない見込みです'
            '（ポケットメイドの予想）。入金や支払いの見直しを。';
        final sig = '${dateKey(day.date)}|$title|$desc';
        if (existingId.isNotEmpty && specialCalendarSigs[key] == sig) continue;
        final calId = await calendarSync!.upsertSpecialEvent(
          existingCalId: existingId,
          title: title,
          date: day.date,
          description: desc,
          reminderMinutes: kShortfallReminderMinutes,
        );
        if (calId != null &&
            !await _recordSpecialEvent(key, calId, sig, gen,
                stillWanted: () => _shortfallKeysOf().contains(key))) {
          _shortfallSyncAgain = true; // 取り込みで中身が変わった → 新しい中身でやり直す
          return;
        }
      }
    }
    // 見込みが無くなった日を片付ける（取り込み中なら終わってから）
    // ⚠️ 「要らない日」はこの回の中身で求めたもの。待っている間に取り込みで中身が変わったら、
    //   取り込んだ中身では必要な通知を消してしまうので片付けず、新しい中身でやり直す（GPT 再レビュー 6880887）。
    await runWhenEditable(() {
      if (gen != _dataGeneration) {
        _shortfallSyncAgain = true;
        return;
      }
      var changed = false;
      for (final key in specialCalendarIds.keys
          .where((k) => k.startsWith(_shortfallPrefix) && !wanted.contains(k))
          .toList()) {
        final placed = _sigDate(specialCalendarSigs[key]);
        // ⚠️ もう来た日は通知済み。予定は記録として残し、管理からだけ外す
        if (placed == null || !placed.isBefore(today)) {
          calendarSync!.deleteEvent(specialCalendarIds[key]!);
        }
        specialCalendarIds.remove(key);
        specialCalendarSigs.remove(key);
        changed = true;
      }
      if (changed) saveData();
    });
  }

  // ───── シフト ─────
  void addShift(DateTime date, ShiftData shift) {
    _ensureEditable();
    shifts.putIfAbsent(_formatDate(date), () => []).add(shift);
    saveData();
    notifyListeners();
    if (calendarAutoSync) calendarSync?.upsertShift(date, shift);
  }

  // 💡 画像から読み取ったシフトをまとめて登録する（確認画面で選んだものだけ）。
  //   給与は勤務先の設定でスナップショットする（AIには計算させない）。
  //   保存と画面の更新は最後に1回。戻り値は「元に戻す」に使う。
  List<({String dateKey, ShiftData shift})> addShiftsBatch(
    Workplace w,
    Iterable<({DateTime date, DateTime start, DateTime end, int breakMinutes})> items,
  ) {
    final added = <({String dateKey, ShiftData shift})>[];
    for (final it in items) {
      final shift = buildShiftFromWorkplace(w, it.date, it.start, it.end,
          breakMinutes: it.breakMinutes);
      final key = _formatDate(it.date);
      shifts.putIfAbsent(key, () => []).add(shift);
      added.add((dateKey: key, shift: shift));
    }
    if (added.isEmpty) return added;
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      for (final a in added) {
        calendarSync?.upsertShift(DateTime.parse(a.dateKey), a.shift);
      }
    }
    return added;
  }

  // そのシフト（同じもの）がまだ登録されているか
  bool hasShift(ShiftData s) => shifts.values.any((l) => l.any((x) => identical(x, s)));

  // 💡 まとめて登録したものだけを取り消す。
  //   ⚠️ 位置（index）ではなく、そのシフト自体で探す（元からあったシフトを巻き込まない）。
  int undoShiftsBatch(List<({String dateKey, ShiftData shift})> added) {
    _ensureEditable();
    var removed = 0;
    final calIds = <String>[];
    for (final a in added) {
      final list = shifts[a.dateKey];
      if (list == null) continue;
      final i = list.indexWhere((x) => identical(x, a.shift));
      if (i < 0) continue;
      final calId = list[i].calendarEventId;
      if (calId != null) calIds.add(calId);
      list.removeAt(i);
      if (list.isEmpty) shifts.remove(a.dateKey);
      removed++;
    }
    if (removed == 0) return 0;
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      for (final id in calIds) {
        calendarSync?.deleteEvent(id);
      }
    }
    return removed;
  }

  void removeShift(String dateKey, int index) {
    _ensureEditable();
    final list = shifts[dateKey];
    final calId = (list != null && index < list.length) ? list[index].calendarEventId : null;
    list?.removeAt(index);
    if (shifts[dateKey]?.isEmpty ?? true) shifts.remove(dateKey);
    saveData();
    notifyListeners();
    if (calendarAutoSync && calId != null) calendarSync?.deleteEvent(calId);
  }

  void updateShift(String dateKey, int index, ShiftData newShift) {
    _ensureEditable();
    final list = shifts[dateKey];
    if (list == null || index < 0 || index >= list.length) return;
    final old = list[index];
    newShift.calendarEventId = old.calendarEventId;
    newShift.id = old.id; // 💡 編集しても同じシフト（メール由来の変更・取消が当てられるように）
    list[index] = newShift;
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      final date = DateTime.tryParse(dateKey) ?? clockNow();
      calendarSync?.upsertShift(date, newShift);
    }
  }

  // 💡 過去のシフトから定型（勤務先＋時刻＋休憩）を新しい順に重複なく抽出。
  //   「履歴から追加」でワンタップ再入力するために使う。
  List<({String? workplaceId, String workplace, int hourlyWage, int startHour, int startMinute, int endHour, int endMinute, int breakMinutes})>
      recentShiftTemplates({int limit = 8}) {
    // 日付キー新しい順に走査
    final keys = shifts.keys.toList()..sort((a, b) => b.compareTo(a));
    final seen = <String>{};
    final out = <({String? workplaceId, String workplace, int hourlyWage, int startHour, int startMinute, int endHour, int endMinute, int breakMinutes})>[];
    for (final k in keys) {
      for (final s in shifts[k]!) {
        final sig = '${s.workplaceId ?? s.workplace}|${s.start.hour}:${s.start.minute}'
            '|${s.end.hour}:${s.end.minute}|${s.breakMinutes}';
        if (!seen.add(sig)) continue;
        out.add((
          workplaceId: s.workplaceId,
          workplace: s.workplace,
          hourlyWage: s.hourlyWage,
          startHour: s.start.hour,
          startMinute: s.start.minute,
          endHour: s.end.hour,
          endMinute: s.end.minute,
          breakMinutes: s.breakMinutes,
        ));
        if (out.length >= limit) return out;
      }
    }
    return out;
  }

  // 💡 複数日のシフトをまとめて追加（繰り返し入力用。保存・通知は1回だけ）
  void addShiftsBulk(Iterable<({DateTime date, ShiftData shift})> entries) {
    _ensureEditable();
    for (final e in entries) {
      shifts.putIfAbsent(_formatDate(e.date), () => []).add(e.shift);
    }
    saveData();
    notifyListeners();
    if (calendarAutoSync) {
      for (final e in entries) {
        calendarSync?.upsertShift(e.date, e.shift);
      }
    }
  }

  // ───── 勤務先マスタ ─────
  String newWorkplaceId() => 'wp-${_id()}';

  Workplace? workplaceById(String? id) {
    if (id == null) return null;
    for (final w in workplaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  void addWorkplace(Workplace w) {
    _ensureEditable();
    w.sortWagePeriods();
    workplaces.add(w);
    saveData();
    notifyListeners();
    syncPaydaysToCalendar(); // 給料日をカレンダーへ（自動連携ONのときだけ動く）
  }

  // 既存の勤務先を丸ごと差し替え（編集画面の「保存する」用）
  void updateWorkplace(Workplace w) {
    _ensureEditable();
    final i = workplaces.indexWhere((e) => e.id == w.id);
    if (i < 0) return;
    w.sortWagePeriods();
    workplaces[i] = w;
    saveData();
    notifyListeners();
    // 💡 給料日を変えたら、まだ来ていない給料日のカレンダー通知を新しい日へ移す
    syncPaydaysToCalendar();
  }

  void removeWorkplace(String id) {
    _ensureEditable();
    _removePaydayEventsOf(id, clockNow());
    workplaces.removeWhere((e) => e.id == id);
    // 削除した勤務先に紐づくデータも掃除（入金の選択肢や集計に残らないように）
    actualSalariesByWp.removeWhere((k, _) => k.endsWith('|$id'));
    paidSalaryKeys.removeWhere((k) => k.startsWith('$id|'));
    saveData();
    notifyListeners();
  }

  // 指定日に適用される給料情報（effectiveFrom <= date で最大のもの。null=最古）
  WagePeriod? wagePeriodFor(Workplace w, DateTime date) {
    if (w.wagePeriods.isEmpty) return null;
    final sorted = [...w.wagePeriods]..sort((a, b) {
        if (a.effectiveFrom == null) return -1;
        if (b.effectiveFrom == null) return 1;
        return a.effectiveFrom!.compareTo(b.effectiveFrom!);
      });
    WagePeriod? result;
    for (final p in sorted) {
      final from = p.effectiveFrom;
      if (from == null || !date.isBefore(from)) {
        result = p; // この区間は date 以前に開始 → 候補
      } else {
        break; // 以降は未来の区間
      }
    }
    return result ?? sorted.first;
  }

  // 勤務先＋勤務日＋時刻から、給料情報をスナップショットした ShiftData を生成。
  // 後から勤務先設定を変えても過去のシフト給与は変わらない。
  ShiftData buildShiftFromWorkplace(
    Workplace w,
    DateTime date,
    DateTime start,
    DateTime end, {
    int breakMinutes = 0,
    int? overrideWage,
  }) {
    final period = wagePeriodFor(w, date);
    return ShiftData(
      workplace: w.name,
      workplaceId: w.id,
      hourlyWage: overrideWage ?? period?.hourlyWage ?? 0,
      start: start,
      end: end,
      breakMinutes: breakMinutes,
      transportPerDay: period?.transportPerDay ?? 0,
      transportMonthlyCap: period?.transportMonthlyCap ?? 0,
      nightMultiplier: period?.nightMultiplier ?? 1.0,
      overtimeMultiplier: period?.overtimeMultiplier ?? 1.0,
      holidayMultiplier: period?.holidayMultiplier ?? 1.0,
    );
  }

  // ───── 予定 ─────
  String newEventId() => 'ev-${_id()}';

  // 予定の追加/更新（idで照合）。開始日が変わってもバケットを移動する。
  void upsertEvent(EventData event) {
    _ensureEditable();
    // 既存idを全バケットから除去
    events.forEach((k, list) => list.removeWhere((x) => x.id == event.id));
    events.removeWhere((k, list) => list.isEmpty);
    final d = event.start ?? clockNow();
    events.putIfAbsent(_formatDate(d), () => []).add(event);
    saveData();
    notifyListeners();
    if (calendarAutoSync) calendarSync?.upsertEvent(event);
  }

  void removeEvent(String dateKey, int index) {
    _ensureEditable();
    final list = events[dateKey];
    final calId = (list != null && index < list.length) ? list[index].calendarEventId : null;
    list?.removeAt(index);
    if (events[dateKey]?.isEmpty ?? true) events.remove(dateKey);
    saveData();
    notifyListeners();
    if (calendarAutoSync && calId != null) calendarSync?.deleteEvent(calId);
  }

  // ───── Todo ─────
  void addTodo(TodoData todo) {
    _ensureEditable();
    final key = _formatDate(todo.deadline);
    todos.putIfAbsent(key, () => []).add(todo);
    saveData();
    notifyListeners();
  }

  void toggleTodo(TodoData todo) {
    _ensureEditable();
    todo.completed = !todo.completed;
    saveData();
    notifyListeners();
  }

  void updateTodo(String oldKey, TodoData todo) {
    _ensureEditable();
    todos[oldKey]?.removeWhere((t) => t.id == todo.id);
    if (todos[oldKey]?.isEmpty ?? false) todos.remove(oldKey);
    addTodo(todo);
  }

  void removeTodo(String dateKey, String id) {
    _ensureEditable();
    todos[dateKey]?.removeWhere((t) => t.id == id);
    if (todos[dateKey]?.isEmpty ?? true) todos.remove(dateKey);
    saveData();
    notifyListeners();
  }

  List<TodoData> get allTodos =>
      todos.values.expand((list) => list).toList()
        ..sort((a, b) => a.deadline.compareTo(b.deadline));

  // ───── カード支払い ─────
  void addPayment({
    required String cardName,
    required int amount,
    required DateTime date,
    PaymentSource source = PaymentSource.manual,
    String note = '', // 利用先（例: Amazonで購入）
  }) {
    _ensureEditable();
    payments.add(Payment(
        id: _id(),
        cardName: cardName,
        amount: amount,
        paymentDate: date,
        source: source,
        note: note.trim()));
    saveData();
    notifyListeners();
  }

  // 💡 メール由来の明細に書いたメモは、次の取り込みで自動データが作り直されると
  //   消えてしまう。sourceId をキーに別で覚えておき、reconcile 後に貼り直す。
  final Map<String, String> paymentNotes = {};

  // ───── Amazonの明細（支払いカードが分からない問題）─────
  // 💡 Amazonの注文・発送メールには「どのカードで払ったか」が書いていない。
  //   既定では Amazonマスター の支出として計上し、
  //   別のカードで払ったと分かったときだけ手で付け替える。
  //   同じカード・同じ日・同じ金額の本物の明細が来たときだけ、
  //   同じ買い物の二重計上になるので infoOnly（記録するが足さない）に落とす。
  // ───── カード名の別名 ─────
  // 💡 銀行の引落確定メールは、カード名を銀行の請求元表記でよこす
  //   （例: 「ミツビシUFJニコス」）。自分が設定で付けた名前（例: 「三菱UFJカード」）
  //   とは一致しないため、同じカードが2つに割れてしまう。
  //   取り込んだ名前 → まとめ先の名前 を覚えて突き合わせる。
  final Map<String, String> cardAliases = {};

  String resolveCardName(String name) => cardAliases[name] ?? name;

  // 💡 大小文字・全角英数・空白・法人略称・ジャックスの銀行表記を吸収する。
  //   類似度は候補の並び順にだけ使い、曖昧な名前では自動統合しない。
  static String billingNameKey(String name) {
    var s = String.fromCharCodes(name.runes.map((r) =>
        r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r)).toLowerCase();
    s = s.replaceAll('ｼﾞｬｯｸｽ', 'jaccs')
        .replaceAll('ｼﾞﾔﾂｸｽ', 'jaccs')
        .replaceAll('ジャックス', 'jaccs')
        .replaceAll('ジヤツクス', 'jaccs')
        .replaceAll(RegExp(r'株式会社|有限会社|\(カ\)|（カ）|㈱'), '');
    return s.replaceAll(RegExp(r'[\s\u3000・（）()\-ー_]'), '');
  }

  static bool billingNamesSimilar(String a, String b) {
    final x = billingNameKey(a);
    final y = billingNameKey(b);
    return x.isNotEmpty && y.isNotEmpty &&
        (x.contains(y) || y.contains(x) ||
         (x.contains('jaccs') && y.contains('jaccs')));
  }

  Loan? loanForBankBillingName(String name) {
    final key = billingNameKey(resolveCardName(name));
    final matches = loans.where((l) =>
        l.bankBillingNames.any((n) => billingNameKey(resolveCardName(n)) == key));
    // ⚠️ 壊れたバックアップ等で複数に紐づいていたら、勝手に一方を消さない。
    return matches.length == 1 ? matches.single : null;
  }

  void linkBankBillingToLoan(String name, String loanId) {
    _ensureEditable();
    final loan = loans.firstWhere((l) => l.id == loanId);
    if (!loan.isFromAccount && !loan.isDownPaymentFromAccount) return;
    final key = billingNameKey(resolveCardName(name));
    for (final l in loans) {
      l.bankBillingNames.removeWhere((n) => billingNameKey(resolveCardName(n)) == key);
    }
    loan.bankBillingNames.add(name);
    saveData();
    notifyListeners();
  }

  void unlinkBankBillingFromLoan(String loanId, String name) {
    _ensureEditable();
    final loan = loans.firstWhere((l) => l.id == loanId);
    loan.bankBillingNames.remove(name);
    // 💡 外したものを次の起動・取り込みで自動的に戻さない。
    loan.autoLinkBankBills = false;
    saveData();
    notifyListeners();
  }

  // ════════════ 引き落としの「請求の月」 ════════════
  // 💡 実際の引落日（銀行確定・請求予定に載っている日付）と、その引き落としが「何月の請求か」は別の概念。
  //   ふだんは同じ月だが、月末払いが休みで翌月にずれると（10/31土 → 11/2）、11/2 の引落は10月の請求。
  //   ⚠️ 日付の月で数えると、11月の請求と取り違えて同じ額を2回引き、11月の請求が消えていた。
  //   決め方（金額では決めない。同じカード・同じ額でも別の請求のことがあるため）:
  //   ・利用者が選んだ月（bankBillMonths）があればそれ
  //   ・設定の引落日から計算した日付が、候補（日付の月・前月）のうち ちょうど1つと一致すれば、その月
  //   ・一致しない／両方と一致する（支払日の設定を変えた、通常と違う振替日など）→ 判定できない。
  //     集計は日付の月で扱い（以前と同じ）、確認待ちに出して利用者に選んでもらい、影響する予想に「要確認」を付ける
  final Map<String, String> bankBillMonths = {}; // 明細のキー → 'yyyy-MM'（利用者が選んだ請求の月）

  String billRecordKey(Payment p) =>
      p.sourceId.isNotEmpty ? p.sourceId : _dupKey(p.cardName, p.amount, p.paymentDate, p.source);

  // 設定から計算した、その請求の月の引落日（ローンは返済日、カードは引落日。未設定は27日）
  DateTime _expectedDrawDate(String label, DateTime billMonth) {
    final loan = loanForBankBillingName(label);
    final day = loan?.payDay ?? cardPaymentDays[label] ?? _drawDayOf(label);
    return drawDateInMonth(day, billMonth);
  }

  ({DateTime month, BillMonthStatus status}) _billMonthOf(String label, DateTime date,
      {String? key}) {
    final dateMonth = DateTime(date.year, date.month);
    final chosen = key == null ? null : bankBillMonths[key];
    if (chosen != null) {
      final m = DateTime.tryParse('$chosen-01');
      if (m != null) return (month: DateTime(m.year, m.month), status: BillMonthStatus.userChosen);
    }
    // 💡 引落日の設定が無いカード（ローンでもない）は、照らし合わせる手がかりが無い。
    //   日付の月として扱い、確認待ちには出さない（出すと設定していないカードの確定がすべて「要確認」になる）。
    //   ⚠️ 未設定のカードは予想でも仮に27日として扱っているので、27日以降が全部休みの月（2月など）に
    //     翌月へずれると、この取り違えが残りうる。引落日を設定すれば判定に乗る。
    if (!cardPaymentDays.containsKey(label) && loanForBankBillingName(label) == null) {
      return (month: dateMonth, status: BillMonthStatus.noSetting);
    }
    final day = DateTime(date.year, date.month, date.day);
    final prev = DateTime(date.year, date.month - 1);
    final candidates = [
      for (final m in [prev, dateMonth])
        if (_expectedDrawDate(label, m) == day) m,
    ];
    if (candidates.length == 1) return (month: candidates.single, status: BillMonthStatus.matched);
    return (month: dateMonth, status: BillMonthStatus.unresolved);
  }

  /// 銀行確定・請求予定の明細が何月の請求か（とその決まり方）
  ({DateTime month, BillMonthStatus status}) billMonthOf(Payment p) =>
      _billMonthOf(p.cardName, p.paymentDate, key: billRecordKey(p));

  bool _isBillOf(Payment p, DateTime billMonth) {
    final m = billMonthOf(p).month;
    return m.year == billMonth.year && m.month == billMonth.month;
  }

  /// 請求の月の候補（日付の前月・日付の月）と、今の設定から計算した各月の引落日（選ぶ画面で見せる）
  List<({DateTime month, DateTime expectedDate})> billMonthCandidatesOf(Payment p) => [
        for (final m in [
          DateTime(p.paymentDate.year, p.paymentDate.month - 1),
          DateTime(p.paymentDate.year, p.paymentDate.month),
        ])
          (month: m, expectedDate: _expectedDrawDate(p.cardName, m)),
      ];

  /// 請求の月を利用者が選ぶ（判定できない銀行確定のため）。null で選択を取り消す。
  void setBankBillMonth(Payment p, DateTime? billMonth) {
    _ensureEditable();
    final key = billRecordKey(p);
    if (billMonth == null) {
      bankBillMonths.remove(key);
    } else {
      bankBillMonths[key] = DateFormat('yyyy-MM').format(billMonth);
    }
    saveData();
    notifyListeners();
  }

  /// 請求の月を判定できない銀行確定（利用者が選んでいないもの）
  List<Payment> get unresolvedBankBills => [
        for (final p in payments)
          if (p.source == PaymentSource.bank && !p.infoOnly &&
              billMonthOf(p).status == BillMonthStatus.unresolved)
            p,
      ];

  // 💡 判定できない銀行確定が影響しうる「カード × 請求の月」（日付の月とその前月）
  Set<String> get _billsNeedingReview => {
        for (final p in unresolvedBankBills) ...{
          '${p.cardName}|${_ym(DateTime(p.paymentDate.year, p.paymentDate.month))}',
          '${p.cardName}|${_ym(DateTime(p.paymentDate.year, p.paymentDate.month - 1))}',
        },
      };

  bool _hasLoanBankBill(Loan loan, DateTime payMonth,
      {DateTime? onDate, int minimumAmount = 0}) => payments.any((p) =>
      p.source == PaymentSource.bank && !p.infoOnly &&
      _isBillOf(p, payMonth) &&
      p.amount >= minimumAmount &&
      (onDate == null || (p.paymentDate.year == onDate.year &&
          p.paymentDate.month == onDate.month && p.paymentDate.day == onDate.day)) &&
      loanForBankBillingName(p.cardName)?.id == loan.id);

  // 💡 既存の行も起動時・取り込み時に照合する。銀行の行は消さず正本として残す。
  //   自動紐づけは名前が一致する場合か、表記が既知のジャックスに限定する。
  //   同社のローンが複数ある場合や、金額・予定日が合わない場合は選んでもらう。
  bool repairLoanBillingLinks() {
    var changed = false;
    for (final p in payments) {
      if (p.source != PaymentSource.bank || p.infoOnly) continue;
      if (loanForBankBillingName(p.cardName) != null) continue;
      final name = resolveCardName(p.cardName);
      if (cardPaymentDays.containsKey(name)) continue;
      final key = billingNameKey(name);
      if (key.isEmpty) continue;
      final candidates = loans.where((l) {
        final lk = billingNameKey(l.name);
        return l.isFromAccount && (lk == key ||
            (key == 'jaccs' && lk.contains('jaccs')));
      }).toList();
      if (candidates.length != 1) continue;
      final l = candidates.single;
      if (!l.autoLinkBankBills) continue;
      final payMonth = DateTime(p.paymentDate.year, p.paymentDate.month);
      final useMonth = DateTime(payMonth.year, payMonth.month - 1);
      final last = DateTime(payMonth.year, payMonth.month + 1, 0).day;
      final expectedDate = nextBusinessDay(DateTime(payMonth.year, payMonth.month,
          l.payDay.clamp(1, last)));
      final actualDate = DateTime(p.paymentDate.year, p.paymentDate.month, p.paymentDate.day);
      final repaymentMatches = expectedDate == actualDate &&
          l.amountIn(useMonth) > 0 && l.amountIn(useMonth) == p.amount;
      final downMatches = l.hasDownPayment && l.isDownPaymentFromAccount &&
          nextBusinessDay(l.downPaymentDate!) == actualDate && l.downPayment == p.amount;
      if (!repaymentMatches && !downMatches) continue;
      l.bankBillingNames.add(name);
      changed = true;
    }
    return changed;
  }

  // 💡 設定に登録されていないカード名で入っている明細（＝割れている候補）。
  List<({String name, int count})> get unregisteredCardNames {
    final counts = <String, int>{};
    for (final p in payments) {
      final n = p.cardName.trim();
      if (n.isEmpty || n == kOtherCard) continue;
      if (cardPaymentDays.containsKey(n)) continue;
      if (loanForBankBillingName(n) != null) continue;
      counts[n] = (counts[n] ?? 0) + 1;
    }
    final out = [for (final e in counts.entries) (name: e.key, count: e.value)];
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }

  // 💡 割れているカード名を1つにまとめる（銀行表記 → 自分が付けた名前）。
  void mergeCardName(String from, String to) => renameOrMergeCard(from, to);

  // 💡 カード名を変える／2枚を1枚にまとめる。
  //   to が未登録なら「名前の変更」（締め日と引き落とし日を引き継ぐ）、
  //   登録済みなら「まとめる」になる。
  // ⚠️ カード名は明細・分割・定期・ローン・予算・重複防止キーに
  //   「文字列として」散らばっている。1か所でも取りこぼすと、
  //   金額が予想から消えたり、削除した明細が次の取り込みで復活したりする。
  //   （test/card_alias_test.dart で全部の行き先を固定している）
  void renameOrMergeCard(String from, String to) {
    _ensureEditable();
    final target = to.trim();
    if (from == target || from.trim().isEmpty || target.isEmpty) return;

    // 未登録の名前へ＝名前の変更。引き落とし日と締め日を持って行く。
    if (!cardPaymentDays.containsKey(target) &&
        cardPaymentDays.containsKey(from)) {
      cardPaymentDays[target] = cardPaymentDays[from]!;
      final closing = cardClosingDays[from];
      if (closing != null) cardClosingDays[target] = closing;
    }

    // 次の取り込みで同じ名前が来ても、まとめ先に寄せる
    cardAliases[from] = target;
    // 前にまとめた名前が from を指していたら、その行き先も付け替える
    for (final k in cardAliases.keys.toList()) {
      if (cardAliases[k] == from) cardAliases[k] = target;
    }

    for (final p in payments) {
      if (p.cardName == from) p.cardName = target;
    }
    for (final i in installments) {
      if (i.cardName == from) i.cardName = target;
    }
    for (final s in subscriptions) {
      if (s.method == from) s.method = target;
    }
    // ローンは「カード払い」のときだけカード名を持つ（'' は口座払い）
    for (final l in loans) {
      if (l.method == from) l.method = target;
      if (l.downPaymentMethod == from) l.downPaymentMethod = target;
    }
    // Amazon明細の付け替え先
    for (final k in amazonCardOverrides.keys.toList()) {
      if (amazonCardOverrides[k] == from) amazonCardOverrides[k] = target;
    }
    // 予算はラベル（＝カード名）がキー。両方にあれば足す
    final budget = budgets.remove(from);
    if (budget != null) budgets[target] = (budgets[target] ?? 0) + budget;
    // 分割の金利（まとめ先に設定があればそちらを優先）
    final rate = cardInterestRates.remove(from);
    if (rate != null) cardInterestRates.putIfAbsent(target, () => rate);
    // ⚠️ 重複防止キーはカード名を含む（_dupKey）。張り替えないと、
    //   削除した明細が復活し、分割へ移した明細がカードに戻る。
    _renameInDupKeys(deletedDupKeys, from, target);
    _renameInDupKeys(convertedPaymentKeys, from, target);

    // 自分の画像: まとめ先に画像が無ければ持って行く（まとめ先の画像があればそれを使う）
    final icon = cardIcons.remove(from);
    if (icon != null) cardIcons.putIfAbsent(target, () => icon);

    // 設定側にも残っていたら消す（まとめ先へ寄せる）
    cardPaymentDays.remove(from);
    cardClosingDays.remove(from);
    saveData();
    _saveCardPaymentDays();
    notifyListeners();
  }

  void _renameInDupKeys(Set<String> keys, String from, String to) {
    final moved = <String>[];
    keys.removeWhere((k) {
      if (!k.startsWith('$from|')) return false;
      moved.add('$to|${k.substring(from.length + 1)}');
      return true;
    });
    keys.addAll(moved);
  }

  static const String kAmazonSourcePrefix = 'amazon#';

  bool isAmazonPayment(Payment p) => p.sourceId.startsWith(kAmazonSourcePrefix);

  // sourceId → 付け替え先のカード名
  final Map<String, String> amazonCardOverrides = {};

  // 💡 同じカード・同じ日・同じ金額の「本物の明細」が既にあるか。
  //   あるならカード会社の通知が来たということなので、手の付け替えは不要になる。
  bool _hasRealChargeLike(String card, DateTime date, int amount,
      {String? exceptId}) {
    final day = _formatDate(date);
    return payments.any((p) =>
        p.id != exceptId &&
        !isAmazonPayment(p) &&
        p.cardName == card &&
        p.amount == amount &&
        _formatDate(p.paymentDate) == day);
  }

  // 💡 Amazonの明細を「実際に使ったカード」へ付け替える。
  //   すでに同じ日・同じ金額の明細がそのカードにあるなら、二重になるので付け替えない。
  //   戻り値: 付け替えたら true、重複していて見送ったら false。
  bool moveAmazonPaymentTo(String paymentId, String cardName) {
    _ensureEditable();
    final i = payments.indexWhere((e) => e.id == paymentId);
    if (i < 0) return false;
    final p = payments[i];
    if (!isAmazonPayment(p)) return false;

    if (_hasRealChargeLike(cardName, p.paymentDate, p.amount, exceptId: p.id)) {
      // カード会社の通知で既に計上済み。付け替えを取り消して情報のみに戻す。
      amazonCardOverrides.remove(p.sourceId);
      p.cardName = 'Amazonマスター';
      p.infoOnly = true;
      saveData();
      notifyListeners();
      return false;
    }

    amazonCardOverrides[p.sourceId] = cardName;
    p.cardName = cardName;
    p.infoOnly = false;
    saveData();
    notifyListeners();
    return true;
  }


  void setPaymentNote(String paymentId, String note) {
    _ensureEditable();
    final i = payments.indexWhere((p) => p.id == paymentId);
    if (i < 0) return;
    final p = payments[i];
    p.note = note.trim();
    if (p.sourceId.isNotEmpty) {
      if (p.note.isEmpty) {
        paymentNotes.remove(p.sourceId);
      } else {
        paymentNotes[p.sourceId] = p.note;
      }
    }
    saveData();
    notifyListeners();
  }

  // 同じカード名・金額・日付の支払いが既にあるか
  bool hasPayment(String cardName, int amount, DateTime date) {
    return payments.any((p) =>
        p.cardName == cardName &&
        p.amount == amount &&
        _formatDate(p.paymentDate) == _formatDate(date));
  }

  String _ym(DateTime d) => '${d.year}-${d.month}';

  // 重複判定キー: カード＋金額＋利用日時＋種別。
  //   利用日時の「時刻」まで含むので、同額・同日でも時刻が違えば別取引として残る。
  //   時刻が無い（00:00）同内容は1件に統合される。
  String _dupKey(String card, int amount, DateTime date, PaymentSource source) =>
      '$card|$amount|${date.toIso8601String()}|${source.index}';

  // 💡 すでに分割払いへ登録済みの決済と一致するか（カード・金額・利用日が同じ）。
  //   分割に移した明細がGmail再取得で復活して二重計上になるのを防ぐ。
  //   ＝分割払いは元の決済そのものなので、カード側にも残ると同じ買い物を2回計上してしまう。
  bool _matchesInstallment(String card, int amount, DateTime date) {
    return installments.any((i) =>
        i.cardName == card &&
        i.totalAmount == amount &&
        i.startDate != null &&
        _formatDate(i.startDate!) == _formatDate(date));
  }

  // 💡 分割払いへ移したはずの決済がカード側にも残っていたら取り除く（二重計上の自己修復）。
  //   旧バージョンで変換した明細は sourceId の記録が無く復活しうるため、
  //   起動時と取り込み時に既存の分割払いと突き合わせて掃除する。手動追加は対象外。
  // ⚠️ 取り込み・起動時の自己修復（repairData）からも呼ぶので、取り込み中でも断らない（保存はしない）
  int cleanupInstallmentDuplicates() {
    if (installments.isEmpty) return 0;
    final before = payments.length;
    payments.removeWhere((p) =>
        p.source != PaymentSource.manual &&
        _matchesInstallment(p.cardName, p.amount, p.paymentDate));
    return before - payments.length;
  }


  // 💡 Gmailの取得結果を正本として、確認できた範囲の自動明細を作り直す。
  //   ・重複は「カード＋金額＋利用日時」で1件に統合
  //   ・銀行確定(bank)が同カード・同月の請求予定(billing)を上書き
  //   ・同日・同額で付け替え先のカード通知と重複したAmazon明細は記録のみ残す
  //   ・支払済み(paid)は引き継ぎ、手動追加(manual)・変換済みは保持
  //   戻り値は (追加, 削除)。
  ({int added, int removed}) reconcilePayments(
      Iterable<({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})> rawItems,
      {DateTime? since, Map<String, DateTime>? mailReceivedAt}) {
    _ensureEditable();
    bool inWindow(DateTime d) => since == null || !d.isBefore(since);
    String mailId(String sourceId) => sourceId.startsWith(kAmazonSourcePrefix)
        ? sourceId
        : sourceId.split('#').first;

    // 💡 銀行表記などの別名を、自分が付けたカード名に寄せてから照合する
    final items = rawItems.map((it) => (
          cardName: resolveCardName(it.cardName),
          amount: it.amount,
          date: it.date,
          source: it.source,
          sourceId: it.sourceId,
          note: it.note,
        )).toList();

    // ⚠️ 請求予定の引落日は受信日より後になる。明細の日付で削除すると、
    //   検索範囲外のメールから作った明細まで消える。受信日時と確認済みIDで範囲を決める。
    //   受信日時の無い旧データは、元メールを再取得できるまで保持する。
    final checkedIds = {
      ...?mailReceivedAt?.keys,
      for (final it in items)
        if (it.sourceId.isNotEmpty) mailId(it.sourceId),
    };
    bool replace(Payment p) {
      if (p.source == PaymentSource.manual) return false;
      if (checkedIds.contains(mailId(p.sourceId))) return true;
      if (mailReceivedAt == null) return inWindow(p.paymentDate);
      return p.mailReceivedAt != null && inWindow(p.mailReceivedAt!);
    }
    final retained = payments.where((p) =>
        p.source != PaymentSource.manual && !replace(p)).toList();

    // 銀行確定があるカード月（請求予定を抑制）
    // 💡 「カード|請求の月」。日付の月ではなく請求の月で比べる（休みで翌月にずれた引落の
    //   銀行確定が、翌月の別の請求予定を消さないように）。
    String billKeyOf(String card, DateTime date, String sourceId) =>
        '$card|${_ym(_billMonthOf(card, date, key: sourceId.isEmpty ? null : sourceId).month)}';
    final bankKeys = <String>{
      for (final p in retained.where((p) => p.source == PaymentSource.bank))
        '${resolveCardName(p.cardName)}|${_ym(billMonthOf(p).month)}',
    };
    for (final it in items.where((e) => e.source == PaymentSource.bank)) {
      bankKeys.add(billKeyOf(it.cardName, it.date, it.sourceId));
    }

    // 望ましい自動集合を構築（重複・変換済み・銀行に上書きされた予測を除外）
    final desired = <({String cardName, int amount, DateTime date, PaymentSource source, String sourceId, String note})>[];
    final seen = <String>{
      // ⚠️ Amazonは後でカード通知と照合する。ここで通知を落とすと正本が入らない。
      for (final p in retained.where((p) => !isAmazonPayment(p)))
        _dupKey(resolveCardName(p.cardName), p.amount, p.paymentDate, p.source),
    };
    for (final it in items) {
      // 💡 取得できた明細は日付にかかわらず追加する。since は既存明細を消す範囲だけ。
      final key = _dupKey(it.cardName, it.amount, it.date, it.source);
      // 💡 分割へ移動済みは復活させない。dupKey（日時・金額が変われば外れる）に加え、
      //   sourceId と「既存の分割払いと一致するか」でも照合して取りこぼしを防ぐ。
      if (convertedPaymentKeys.contains(key)) continue;
      if (it.sourceId.isNotEmpty && convertedSourceIds.contains(it.sourceId)) continue;
      if (_matchesInstallment(it.cardName, it.amount, it.date)) continue;
      // 💡 ユーザーが削除した明細は更新で復活させない（墓石照合）。
      if (deletedDupKeys.contains(key)) continue;
      if (it.sourceId.isNotEmpty && deletedSourceIds.contains(it.sourceId)) continue;
      if (it.source == PaymentSource.billing &&
          bankKeys.contains(billKeyOf(it.cardName, it.date, it.sourceId))) {
        continue; // 銀行確定が優先
      }
      if (!seen.add(key)) continue; // 同内容（同時刻）は1件に統合
      desired.add(it);
    }

    // 💡 手動追加と「同じカード・同じ年月日・同じ金額」の正式取り込み(メール確認)が来たら、
    //   重複しないよう手動の方を削除し、正式の明細に置き換える（メール受信が遅いカード対策）。
    String dayKey(String card, int amount, DateTime d) =>
        '$card|${_formatDate(d)}|$amount';
    final officialDayKeys = <String>{
      for (final it in desired) dayKey(it.cardName, it.amount, it.date),
    };
    payments.removeWhere((p) =>
        p.source == PaymentSource.manual &&
        officialDayKeys.contains(dayKey(p.cardName, p.amount, p.paymentDate)));

    // 既存の自動データ: paid を引き継ぐ
    final paidByKey = <String, bool>{};
    final infoOnlyBySource = <String, bool>{};
    final receivedBySource = <String, DateTime?>{};
    final beforeKeys = <String>{};
    for (final p in payments
        .where((p) => p.source != PaymentSource.manual)) {
      final k = _dupKey(p.cardName, p.amount, p.paymentDate, p.source);
      paidByKey[k] = p.paid;
      if (p.sourceId.isNotEmpty) {
        infoOnlyBySource[p.sourceId] = p.infoOnly;
        receivedBySource[p.sourceId] = p.mailReceivedAt;
      }
      beforeKeys.add(k);
    }

    // 💡 確認できる範囲だけ入れ替え、保持した請求予定も銀行確定があれば除く。
    payments.removeWhere((p) => replace(p) ||
        (p.source == PaymentSource.billing &&
         bankKeys.contains(
             '${resolveCardName(p.cardName)}|${_ym(_billMonthOf(resolveCardName(p.cardName), p.paymentDate, key: p.sourceId.isEmpty ? null : p.sourceId).month)}')));
    for (final it in desired) {
      final k = _dupKey(it.cardName, it.amount, it.date, it.source);
      final card = amazonCardOverrides[it.sourceId] ?? it.cardName;
      payments.add(Payment(
        id: _id(),
        cardName: card,
        amount: it.amount,
        paymentDate: it.date,
        source: it.source,
        paid: paidByKey[k] ?? false,
        sourceId: it.sourceId,
        mailReceivedAt: mailReceivedAt?[mailId(it.sourceId)] ?? receivedBySource[it.sourceId],
        // 手で書いたメモがあれば、メール由来の利用先より優先して残す
        note: paymentNotes[it.sourceId] ?? it.note,
        infoOnly: infoOnlyBySource[it.sourceId] ?? false,
      ));
    }

    // 💡 期間外として保持したAmazon明細も、今回届いたカード通知と突き合わせる。
    //   付け替え時と同じ判定を使い、重複分は記録だけ残す。
    for (final p in payments.where(isAmazonPayment)) {
      if (_hasRealChargeLike(p.cardName, p.paymentDate, p.amount, exceptId: p.id)) {
        amazonCardOverrides.remove(p.sourceId);
        p.cardName = 'Amazonマスター';
        p.infoOnly = true;
      }
    }
    cleanupInstallmentDuplicates(); // 分割へ移した決済が残っていれば取り除く
    repairLoanBillingLinks();
    final desiredKeys = {
      for (final p in payments.where((p) => p.source != PaymentSource.manual))
        _dupKey(p.cardName, p.amount, p.paymentDate, p.source),
    };
    final added = desiredKeys.difference(beforeKeys).length;
    final removed = beforeKeys.difference(desiredKeys).length;
    saveData();
    notifyListeners();
    return (added: added, removed: removed);
  }


  void togglePaid(String id) {
    _ensureEditable();
    final p = payments.firstWhere((e) => e.id == id);
    p.paid = !p.paid;
    saveData();
    notifyListeners();
  }

  // 削除＝ゴミ箱へ退避＋墓石を記録（更新で復活しない）。
  void removePayment(String id) {
    _ensureEditable();
    final idx = payments.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final p = payments[idx];
    trashedPayments.insert(0, p); // 新しい削除を先頭に
    if (p.sourceId.isNotEmpty) deletedSourceIds.add(p.sourceId);
    deletedDupKeys.add(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    payments.removeAt(idx);
    saveData();
    notifyListeners();
  }

  // ゴミ箱から復元（墓石も解除し、再び更新対象に戻す）。
  void restorePayment(String id) {
    _ensureEditable();
    final idx = trashedPayments.indexWhere((e) => e.id == id);
    if (idx < 0) return;
    final p = trashedPayments.removeAt(idx);
    deletedSourceIds.remove(p.sourceId);
    deletedDupKeys.remove(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    payments.add(p);
    saveData();
    notifyListeners();
  }

  // ゴミ箱から完全削除（墓石は残す＝更新でも復活させない）。
  void deleteFromTrash(String id) {
    _ensureEditable();
    trashedPayments.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // ゴミ箱を空にする（墓石は残す）。
  void emptyTrash() {
    _ensureEditable();
    trashedPayments.clear();
    saveData();
    notifyListeners();
  }

  // ───── 分割払い ─────
  void addInstallment({
    required String name,
    required int totalAmount,
    required int count,
    String cardName = '',
    double interestRate = 0,
    DateTime? startDate,
  }) {
    _ensureEditable();
    final start = startDate ?? clockNow();
    // 💡 同一取引の二重登録を防止（カード・総額・回数・利用日が同じものは追加しない）。
    final dup = installments.any((i) =>
        i.cardName == cardName &&
        i.totalAmount == totalAmount &&
        i.installmentCount == count &&
        i.startDate != null &&
        _formatDate(i.startDate!) == _formatDate(start));
    if (dup) return;
    installments.add(Installment(
      id: _id(),
      name: name,
      cardName: cardName,
      totalAmount: totalAmount,
      installmentCount: count,
      remainingMonths: count,
      monthlyAmount: computeInstallmentMonthly(totalAmount, count, interestRate),
      interestRate: interestRate,
      startDate: start,
    ));
    saveData();
    notifyListeners();
  }

  // カード規則を考慮した実効金利（Amazonの2・3回は無料）
  double effectiveRateFor(String cardName, int count) =>
      isInstallmentInterestFree(cardName, count) ? 0.0 : interestRateOf(cardName);

  // 💡 そのカード・回数で分割したときの条件（金利・手数料無料か・月額）。
  //   画面に出す見込みと、保存（変換・編集）の両方がこれを使う。
  //   ⚠️ 以前は「分割払いを編集」の見込みが元のカードの金利で計算していて、
  //     カードを変えると保存後の月額（新しいカードの金利）と食い違っていた。
  ({double rate, bool free, int monthly}) installmentPlanOf(
      String cardName, int principal, int count) {
    final rate = effectiveRateFor(cardName, count);
    return (
      rate: rate,
      free: isInstallmentInterestFree(cardName, count),
      monthly: computeInstallmentMonthly(principal, count, rate),
    );
  }

  // 💡 経過した引落回数から「残り回数」を動的に算出。
  //   利用日(startDate)から引落日ルールで各回の引落日を出し、今日までに過ぎた回数を引く。
  int remainingMonthsOf(Installment i) {
    final start = i.startDate;
    if (start == null) return i.remainingMonths; // 旧データは保存値を使用
    final now = clockNow();
    var paid = 0;
    for (var k = 0; k < i.installmentCount; k++) {
      // 各回の引落日（土日祝・年末年始の調整も各回ごと）。過ぎた回数を「支払済み」に。
      // 💡 予想と同じ規則: k 回目は「利用開始月＋k 月」の利用ぶんとして、その翌月の
      //   カードの引落日（設定の引落日）に落ちる。
      // ⚠️ 以前はカード名から引落日を決め打ちしていた（楽天=27日・三井/Amazon/メル=26日）。
      final d = cardDrawDateOf(i.cardName, DateTime(start.year, start.month + 1 + k));
      if (!d.isAfter(now)) paid++;
    }
    return (i.installmentCount - paid).clamp(0, i.installmentCount);
  }

  // 回数を編集して月額を再計算（金利はカード規則で自動判定）
  void editInstallment(String id, {required int count, String? cardName}) {
    _ensureEditable();
    final inst = installments.firstWhere((e) => e.id == id);
    if (cardName != null) inst.cardName = cardName;
    inst.installmentCount = count;
    inst.remainingMonths = count;
    final plan = installmentPlanOf(inst.cardName, inst.totalAmount, count);
    inst.interestRate = plan.rate;
    inst.monthlyAmount = plan.monthly;
    saveData();
    notifyListeners();
  }

  void removeInstallment(String id) {
    _ensureEditable();
    installments.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // 💡 カード請求を分割払いへ変換（カードからは外す）。金利はそのカードの設定値。
  void convertPaymentToInstallment(String paymentId, int count) {
    _ensureEditable();
    final idx = payments.indexWhere((e) => e.id == paymentId);
    if (idx < 0) return;
    final p = payments[idx];
    if (!canInstallment(p.cardName, p.amount)) return; // 最低金額未満は不可
    final rate = effectiveRateFor(p.cardName, count);
    // 再取得で復活しないよう変換済みとして記録。
    //   dupKey は日時・金額が変わると外れるため、sourceId でも記録する。
    //   （例: Amazonは発送メールの受信日時が日付になるので、再同期で時刻がズレうる）
    convertedPaymentKeys.add(_dupKey(p.cardName, p.amount, p.paymentDate, p.source));
    if (p.sourceId.isNotEmpty) convertedSourceIds.add(p.sourceId);
    addInstallment(
      name: '${p.cardName} (${_formatDate(p.paymentDate)})',
      totalAmount: p.amount,
      count: count,
      cardName: p.cardName,
      interestRate: rate,
      startDate: p.paymentDate,
    );
    payments.removeAt(idx);
    saveData();
    notifyListeners();
  }

  // ───── 定期支払い ─────
  // 💡 startMonth: 最初の利用月。登録画面は今月を初期値にする（null＝未設定は以前の版のデータ用）
  void addSubscription({
    required String title,
    required int amount,
    required int payDay,
    String method = '',
    DateTime? startMonth,
  }) {
    _ensureEditable();
    subscriptions.add(Subscription(
        id: _id(), title: title, amount: amount, payDay: payDay, method: method, startMonth: startMonth));
    saveData();
    notifyListeners();
  }

  // 定期支払いの開始月を変える（null で未設定に戻す＝どの月にも載せる）
  void setSubscriptionStartMonth(String id, DateTime? startMonth) =>
      editSubscription(id, method: subscriptions.firstWhere((e) => e.id == id).method, startMonth: startMonth);

  // 定期支払いの編集画面の保存（支払い方法と開始月を 1 回で保存する）
  void editSubscription(String id, {required String method, required DateTime? startMonth}) {
    _ensureEditable();
    final i = subscriptions.indexWhere((e) => e.id == id);
    if (i < 0) return;
    subscriptions[i].method = method;
    subscriptions[i].startMonth =
        startMonth == null ? null : DateTime(startMonth.year, startMonth.month);
    saveData();
    notifyListeners();
  }

  /// 開始月から、最初に口座から落ちる月（画面の説明用）。
  /// 口座振替・手動払いは開始月そのもの、カード払いは翌月（カードの請求として落ちる）。
  DateTime? subscriptionFirstDrawMonth(String method, DateTime? startMonth) {
    if (startMonth == null) return null;
    final card = method.isNotEmpty && method != kManualPayMethod;
    return DateTime(startMonth.year, startMonth.month + (card ? 1 : 0));
  }

  // 定期支払いの支払い方法を変更（口座振替 / カード名）
  void setSubscriptionMethod(String id, String method) {
    _ensureEditable();
    final i = subscriptions.indexWhere((e) => e.id == id);
    if (i < 0) return;
    subscriptions[i].method = method;
    saveData();
    notifyListeners();
  }

  void removeSubscription(String id) {
    _ensureEditable();
    subscriptions.removeWhere((e) => e.id == id);
    saveData();
    notifyListeners();
  }

  // ───── ATM引き出し ─────
  // 💡 ATM で引き出した＝口座のお金が財布へ移る。口座残高から引き、財布に足す（入出金の履歴にも残す）。
  //   支出の内訳の「ATM」には、これまでどおり引き出した月の支出として出す。
  //   ⚠️ 財布の現金は口座の予想に入らないので、口座の見込みは引き出した分だけ減る。
  void addWithdrawal({required DateTime date, required int amount, String memo = ''}) {
    _ensureEditable();
    final w = Withdrawal(id: _id(), date: date, amount: amount, memo: memo, movedToWallet: amount > 0);
    withdrawals.add(w);
    if (amount > 0) {
      _foldDebitsIntoBalance();
      currentBalance -= amount;
      walletCash += amount;
      balanceUpdatedAt = clockNow();
      _recordBalanceEntry(
        kind: BalanceEntryKind.draw,
        label: 'ATM引き出し',
        amount: amount,
        sourceKey: _atmKey(w.id),
      );
    }
    saveData();
    notifyListeners();
  }

  static String _atmKey(String withdrawalId) => 'atm:$withdrawalId';

  // 💡 引き出しを消したら、口座と財布も元に戻す（登録したときに動かした分だけ）。
  void removeWithdrawal(String id) {
    _ensureEditable();
    final i = withdrawals.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final w = withdrawals.removeAt(i);
    if (w.movedToWallet) {
      _foldDebitsIntoBalance();
      currentBalance += w.amount;
      walletCash -= w.amount;
      balanceUpdatedAt = clockNow();
      balanceHistory.removeWhere((e) => e.sourceKey == _atmKey(w.id));
    }
    saveData();
    notifyListeners();
  }

  void updateBalance(int balance) {
    _ensureEditable();
    // 💡 手で書いた残高は通帳の値＝その時点までのデビットは既に引かれている。
    //   金額は動かさず「済み」とだけ記録する（引くと二重になる）。
    _markDebitsAccounted();
    currentBalance = balance;
    balanceUpdatedAt = clockNow(); // #6 編集日時を記録
    balanceEnteredAt = balanceUpdatedAt;
    saveData();
    notifyListeners();
  }

  // 💡 残高を「増減で」動かす前に、それまでのデビット利用を残高へ畳み込む。
  // ⚠️ 基準日(balanceUpdatedAt)が進むと、それより前のデビットは「反映済み」と
  //   みなされて差し引かれなくなる。畳み込まずに基準日だけ進めると、
  //   使ったはずのデビットが消えて残高が増えて見える。
  //   （手入力の updateBalance では呼ばないこと＝二重に引くため）
  // 💡 いま時点までのデビットを「残高に入っている」ことにする（金額は動かさない）。
  //   手で残高を書き直したときに使う。
  void _markDebitsAccounted() {
    final now = clockNow();
    for (final p in payments) {
      if (!_isDebit(p.cardName)) continue;
      if (p.paymentDate.isAfter(now)) continue; // これから使うぶんは対象外
      foldedDebitKeys.add(_debitKey(p));
    }
  }

  void _foldDebitsIntoBalance() {
    var spent = 0;
    for (final p in payments) {
      if (!_isDebit(p.cardName) || !_afterSnapshot(p.paymentDate)) continue;
      final k = _debitKey(p);
      if (foldedDebitKeys.contains(k)) continue;
      spent += p.amount;
      foldedDebitKeys.add(k); // 二度と引かない
    }
    if (spent > 0) currentBalance -= spent;
  }

  void updateWalletCash(int amount) {
    _ensureEditable();
    walletCash = amount;
    saveData();
    notifyListeners();
  }

  // ════════════ 予定入金 ════════════
  List<PlannedIncome> plannedIncomes = [];
  // 受け取り済みの予定入金（キー: "id|yyyy-MM"）
  final Set<String> receivedPlannedKeys = {};

  String _plannedKey(String id, DateTime date) =>
      '$id|${DateFormat('yyyy-MM').format(date)}';

  void addPlannedIncome(
      {required String title, required int amount, required DateTime date, bool monthly = false}) {
    _ensureEditable();
    plannedIncomes.add(PlannedIncome(
        id: _id(), title: title, amount: amount, date: date, monthly: monthly));
    saveData();
    notifyListeners();
  }

  void updatePlannedIncome(String id,
      {String? title, int? amount, DateTime? date, bool? monthly}) {
    _ensureEditable();
    final i = plannedIncomes.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final p = plannedIncomes[i];
    if (title != null) p.title = title;
    if (amount != null) p.amount = amount;
    if (date != null) p.date = date;
    if (monthly != null) p.monthly = monthly;
    saveData();
    notifyListeners();
  }

  void removePlannedIncome(String id) {
    _ensureEditable();
    plannedIncomes.removeWhere((e) => e.id == id);
    receivedPlannedKeys.removeWhere((k) => k.startsWith('$id|'));
    saveData();
    notifyListeners();
  }

  // 指定月に入る予定の入金（まだ受け取っていないもの）
  List<({PlannedIncome income, DateTime date})> plannedIncomesIn(DateTime month) {
    final out = <({PlannedIncome income, DateTime date})>[];
    for (final p in plannedIncomes) {
      final d = p.dateIn(month);
      if (d == null) continue;
      if (receivedPlannedKeys.contains(_plannedKey(p.id, d))) continue;
      out.add((income: p, date: d));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 指定日の予定入金（カレンダー表示用・受け取り済みも含む）
  List<PlannedIncome> plannedIncomesOnDay(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    return plannedIncomes.where((p) => p.dateIn(day) == day).toList();
  }

  // 予測に足す予定入金（残高編集日より後のものだけ）
  int plannedIncomeForecastIn(DateTime month) => plannedIncomesIn(month)
      .where((e) => _forecastInclude(e.date))
      .fold(0, (s, e) => s + e.income.amount);

  // 予定日が過ぎて、まだ受け取っていない入金
  List<({PlannedIncome income, DateTime date})> get duePlannedIncomes {
    final now = clockNow();
    final today = DateTime(now.year, now.month, now.day);
    final oldest = today.subtract(const Duration(days: 62));
    final out = <({PlannedIncome income, DateTime date})>[];
    for (var back = 0; back < 3; back++) {
      for (final e in plannedIncomesIn(DateTime(now.year, now.month - back))) {
        if (e.date.isAfter(today) || e.date.isBefore(oldest)) continue;
        out.add(e);
      }
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 予定入金を受け取った → 残高に加算して履歴に残す
  void receivePlannedIncome(String id, int amount, DateTime date) {
    _ensureEditable();
    final p = plannedIncomes.firstWhere((e) => e.id == id,
        orElse: () => PlannedIncome(id: '', title: '入金', amount: 0, date: date));
    receivedPlannedKeys.add(_plannedKey(id, date));
    if (amount > 0) {
      _foldDebitsIntoBalance();
      currentBalance += amount;
      balanceUpdatedAt = clockNow();
      _recordBalanceEntry(
        kind: BalanceEntryKind.deposit,
        label: p.title.isEmpty ? '予定入金' : p.title,
        amount: amount,
      );
    }
    saveData();
    notifyListeners();
  }

  // 予定入金を「受け取らなかった」ことにする（残高は変えない）
  void skipPlannedIncome(String id, DateTime date) {
    _ensureEditable();
    receivedPlannedKeys.add(_plannedKey(id, date));
    saveData();
    notifyListeners();
  }

  // ════════════ 残高の増減履歴 ════════════
  List<BalanceEntry> balanceHistory = [];

  // 💡 給料を受け取り済みの「勤務先×支払月」（キー: "wpId|yyyy-MM"）。
  //   入金の選択肢から、もう入金済みのバイトを外すために使う。
  final Set<String> paidSalaryKeys = {};
  // この月までの給料はすべて受け取り済みとみなす（初期移行用）。
  DateTime? salaryPaidThroughMonth;

  String _paidKey(String wpId, DateTime payDate) =>
      '$wpId|${DateFormat('yyyy-MM').format(payDate)}';

  // その勤務先の、その支払月の給料をもう受け取っているか
  bool isSalaryPaid(String wpId, DateTime payDate) {
    final through = salaryPaidThroughMonth;
    if (through != null) {
      final m = DateTime(payDate.year, payDate.month);
      if (!m.isAfter(DateTime(through.year, through.month))) return true;
    }
    return paidSalaryKeys.contains(_paidKey(wpId, payDate));
  }

  // 入金の選択肢に出す勤務先（もう受け取った分は除く）
  List<Workplace> workplacesAwaitingSalary(DateTime payDate) =>
      workplaces.where((w) => !isSalaryPaid(w.id, payDate)).toList();

  void _recordBalanceEntry({
    required BalanceEntryKind kind,
    required String label,
    required int amount,
    String? workplaceId,
    String? sourceKey,
  }) {
    balanceHistory.insert(
      0,
      BalanceEntry(
        id: _id(),
        kind: kind,
        label: label,
        amount: amount,
        at: clockNow(),
        balanceAfter: currentBalance,
        workplaceId: workplaceId,
        sourceKey: sourceKey,
      ),
    );
    // 履歴が増えすぎないよう直近300件まで
    if (balanceHistory.length > 300) {
      balanceHistory = balanceHistory.sublist(0, 300);
    }
  }

  // 💡 入出金の履歴に並べるものを1本化する。
  //   デビットは口座から即時に出ていくお金なのに、残高そのものを書き換えない
  //   （予想の起点で差し引く方式）ため、履歴に出てこなかった。
  // ⚠️ デビットを BalanceEntry として保存してはいけない。
  //   Gmailの取り込みは「自動明細の作り直し」なので、明細が変わったときに
  //   履歴だけが残ってズレる。表示のたびに明細から作ること。
  List<LedgerRow> balanceLedger() {
    final out = <LedgerRow>[
      for (final e in balanceHistory)
        LedgerRow(
          at: e.at,
          label: e.label,
          amount: e.amount,
          isDeposit: e.kind == BalanceEntryKind.deposit,
          entry: e,
          balanceAfter: e.balanceAfter,
        ),
      for (final p in payments)
        if (_isDebit(p.cardName) && !p.infoOnly)
          LedgerRow(
            at: p.paymentDate,
            label: p.note.isEmpty ? p.cardName : '${p.cardName}（${p.note}）',
            amount: p.amount,
            isDeposit: false,
          ),
    ];
    out.sort((a, b) => b.at.compareTo(a.at)); // 新しい順
    return out;
  }

  // 💡 過去の入金・引き落としを履歴だけに書き足す（残高は変えない）。
  //   履歴機能を付ける前に反映した分を、後から記録として残すために使う。
  void addPastBalanceEntry({
    required BalanceEntryKind kind,
    required String label,
    required int amount,
    required DateTime at,
    String? workplaceId,
  }) {
    _ensureEditable();
    if (amount <= 0) return;
    balanceHistory.add(BalanceEntry(
      id: _id(),
      kind: kind,
      label: label,
      amount: amount,
      at: at,
      balanceAfter: currentBalance, // 残高は動かさない（記録のみ）
      workplaceId: workplaceId,
    ));
    balanceHistory.sort((a, b) => b.at.compareTo(a.at)); // 新しい順
    saveData();
    notifyListeners();
  }

  // 💡 履歴を取り消して残高を元に戻す（入力ミスの修正用）。
  //   元の通知も未処理に戻すので、もう一度入力し直せる。
  void undoBalanceEntry(String entryId) {
    _ensureEditable();
    final i = balanceHistory.indexWhere((e) => e.id == entryId);
    if (i < 0) return;
    final e = balanceHistory[i];
    _foldDebitsIntoBalance();
    currentBalance -= e.signedAmount; // 反映を打ち消す
    balanceUpdatedAt = clockNow();
    balanceHistory.removeAt(i);
    final key = e.sourceKey;
    // 💡 ATM 引き出しの取り消し: 財布に足した分も戻し、引き出しの記録も消す（口座だけ戻ると二重になる）
    if (key != null && key.startsWith('atm:')) {
      final wi = withdrawals.indexWhere((w) => _atmKey(w.id) == key);
      if (wi >= 0) {
        final w = withdrawals.removeAt(wi);
        if (w.movedToWallet) walletCash -= w.amount;
      }
    }
    if (key != null && key.isNotEmpty) {
      handledDrawIds.remove(key);
      handledDepositIds.remove(key);
      pendingDeposits.removeWhere((d) => d.sourceId == key);
      // PayPayの出金を受け取り済みにしていたら、未着に戻す（予想にまた入る）
      receivedTransfers.removeWhere((_, src) => src == key);
    }
    // 給料入金の取り消しなら「受け取り済み」も解除
    final wp = e.workplaceId;
    if (wp != null) {
      paidSalaryKeys.remove(_paidKey(wp, e.at));
      paidSalaryKeys.removeWhere((k) => k.startsWith('$wp|'));
    }
    saveData();
    notifyListeners();
  }

  // ════════════ 口座への入金 ════════════
  // 未処理の入金通知（アプリ起動時にポップアップで金額を聞く）
  List<DepositNotice> pendingDeposits = [];
  // 入力済み/スキップ済みのメールID（同じ通知を何度も出さない）
  final Set<String> handledDepositIds = {};

  // ───── PayPayからの出金（口座への入金予定） ─────
  final List<PayPayTransfer> paypayTransfers = [];
  // 💡 受け取り済みにした出金 → そのとき反映した入金の識別子（取り消しで戻すため）
  final Map<String, String> receivedTransfers = {};

  // 💡 口座として追っているのは三井住友銀行だけ（それ以外への出金は残高に関係しない）
  static bool _isTrackedBank(String bank) => bank.contains('三井住友');

  // 💡 Gmailから読んだ出金を足す。
  // ⚠️ 取り込みの「作り直し」はしない（取得に失敗したときに消えないよう、足すだけ）。
  //   同じ取引番号は1件として扱う。古いもの（振込予定日から120日超）は掃除する。
  void addPayPayTransfers(Iterable<PayPayTransfer> list) {
    _ensureEditable();
    var changed = false;
    for (final t in list) {
      if (!_isTrackedBank(t.bank)) continue;
      if (paypayTransfers.any((e) => e.id == t.id)) continue;
      paypayTransfers.add(t);
      changed = true;
    }
    final oldest = clockNow().subtract(const Duration(days: 120));
    final before = paypayTransfers.length;
    paypayTransfers.removeWhere((t) => t.scheduledDate.isBefore(oldest));
    receivedTransfers.removeWhere((id, _) => !paypayTransfers.any((t) => t.id == id));
    if (changed || before != paypayTransfers.length) {
      saveData();
      notifyListeners();
    }
  }

  // 💡 保存・書き出しから読み戻す（端末の保存とドライブ同期の両方で使う）。
  //   置き換え（マージしない）。古いバックアップには項目が無いので空になる。
  void _loadTransfers(Object? list, Object? received) {
    paypayTransfers
      ..clear()
      ..addAll([
        for (final e in (list is List ? list : const []))
          if (e is Map<String, dynamic>) PayPayTransfer.fromJson(e),
      ].whereType<PayPayTransfer>());
    receivedTransfers
      ..clear()
      ..addAll({
        if (received is Map)
          for (final e in received.entries) '${e.key}': '${e.value}',
      });
  }

  // まだ受け取っていない出金（振込予定日の順）
  List<PayPayTransfer> get pendingTransfers {
    final out = paypayTransfers.where((t) => !receivedTransfers.containsKey(t.id)).toList();
    out.sort((a, b) => a.scheduledDate.compareTo(b.scheduledDate));
    return out;
  }

  // 💡 n月に口座へ入る予定の出金（予想に足すぶん）。
  //   残高を書いた日より後に振り込まれる予定のものだけ（それ以前は残高に入っている）。
  List<PayPayTransfer> transfersForecastIn(DateTime month) => pendingTransfers
      .where((t) =>
          t.scheduledDate.year == month.year &&
          t.scheduledDate.month == month.month &&
          _forecastInclude(t.scheduledDate))
      .toList();

  int transferForecastIn(DateTime month) =>
      transfersForecastIn(month).fold(0, (s, t) => s + t.amount);

  // 💡 銀行の「振込入金のお知らせ」が、どの出金の着金かを推定する。
  //   受付日〜振込予定日の3日後までに届いた入金通知を、予定日が近いものと結びつける。
  //   （予定日は「前後」なので幅を持たせる）
  PayPayTransfer? transferForDeposit(DepositNotice n) {
    final d = DateTime(n.date.year, n.date.month, n.date.day);
    PayPayTransfer? best;
    for (final t in pendingTransfers) {
      final from = DateTime(t.acceptedAt.year, t.acceptedAt.month, t.acceptedAt.day);
      final to = t.scheduledDate.add(const Duration(days: 3));
      if (d.isBefore(from) || d.isAfter(to)) continue;
      if (best == null ||
          (t.scheduledDate.difference(d).inDays.abs() <
              best.scheduledDate.difference(d).inDays.abs())) {
        best = t;
      }
    }
    return best;
  }

  // 💡 入金を口座残高へ加算する（手入力・通知どちらも共通）。
  //   残高の編集日時も更新するので、この入金が予想残高で二重計上されない。
  void addDeposit(int amount,
      {String? workplaceId, DateTime? date, String? sourceKey, String? label}) {
    _ensureEditable();
    if (amount == 0) return;
    _foldDebitsIntoBalance();
    currentBalance += amount;
    balanceUpdatedAt = clockNow();
    final d = date ?? clockNow();
    // バイトの給料として入力された場合は、その労働月の実給料にも反映する
    final w = workplaceById(workplaceId);
    if (w != null) {
      setActualSalaryOfWorkplace(workMonthForPayday(w, d), w.id, amount);
      paidSalaryKeys.add(_paidKey(w.id, d)); // この月はもう受け取った
    }
    _recordBalanceEntry(
      kind: BalanceEntryKind.deposit,
      label: w?.name ?? label ?? 'その他の入金',
      amount: amount,
      workplaceId: w?.id,
      sourceKey: sourceKey,
    );
    saveData();
    notifyListeners();
  }

  // 給料日(payDate)に受け取る給料は、どの月の労働分か
  DateTime workMonthForPayday(Workplace w, DateTime payDate) =>
      DateTime(payDate.year, payDate.month - w.paydayMonthOffset);

  // 💡 その日が給料日にあたる勤務先（土日ズレを見込んで前後 tolerance 日まで許容）。
  //   入金通知のポップアップで「どのバイトの給料か」を推測するために使う。
  List<Workplace> workplacesWithPaydayNear(DateTime date, {int tolerance = 3}) {
    final matched = <({Workplace w, int diff})>[];
    final target = DateTime(date.year, date.month, date.day);
    for (final w in workplaces) {
      // 土日祝の調整を反映した「実際の給料日」と比べる
      final payday = w.paydayIn(DateTime(date.year, date.month));
      final diff = target.difference(payday).inDays.abs();
      if (diff <= tolerance) matched.add((w: w, diff: diff));
    }
    matched.sort((a, b) => a.diff.compareTo(b.diff)); // 近い順
    return matched.map((e) => e.w).toList();
  }

  // メールから見つけた入金通知を取り込む（処理済み・既存は無視）
  int addDepositNotices(Iterable<({String sourceId, DateTime date})> notices) {
    _ensureEditable();
    var added = 0;
    for (final n in notices) {
      if (n.sourceId.isEmpty) continue;
      if (handledDepositIds.contains(n.sourceId)) continue;
      if (pendingDeposits.any((e) => e.sourceId == n.sourceId)) continue;
      pendingDeposits.add(DepositNotice(sourceId: n.sourceId, date: n.date));
      added++;
    }
    if (added > 0) {
      pendingDeposits.sort((a, b) => a.date.compareTo(b.date));
      saveData();
      notifyListeners();
    }
    return added;
  }

  // 入金通知に金額を入力して残高へ反映
  void applyDepositNotice(String sourceId, int amount,
      {String? workplaceId, String? transferId}) {
    _ensureEditable();
    final idx = pendingDeposits.indexWhere((e) => e.sourceId == sourceId);
    final date = idx >= 0 ? pendingDeposits[idx].date : clockNow();
    if (idx >= 0) pendingDeposits.removeAt(idx);
    handledDepositIds.add(sourceId);
    // 💡 PayPayの出金の着金なら「受け取り済み」にする。
    //   ⚠️ しないと、予定日がまだ先のとき予想でもう一度足してしまう。
    if (transferId != null) receivedTransfers[transferId] = sourceId;
    addDeposit(amount,
        workplaceId: workplaceId,
        date: date,
        sourceKey: sourceId,
        label: transferId != null ? 'PayPayからの入金' : null);
  }

  // ════════════ 口座からの引き落とし ════════════
  // 反映済み/スキップ済みの引き落としID（同じものを何度も聞かない）
  final Set<String> handledDrawIds = {};

  // 💡 まだ口座残高に反映していない引き落とし。
  //   ・銀行の引き落とし事前お知らせ（金額つき）で、引き落とし日が過ぎたもの
  //   ・口座振替の定期支払いで、支払日が過ぎたもの
  //   残高を編集した日より後のものだけが対象（それ以前は残高に反映済みとみなす）。
  List<({String id, String label, int amount, DateTime date})> get pendingDraws {
    final out = <({String id, String label, int amount, DateTime date})>[];
    final now = clockNow();
    final today = DateTime(now.year, now.month, now.day);

    // 💡 対象は「直近2か月以内に引き落とし日が過ぎたもの」。
    //   残高の編集日では絞らない（入金を反映すると編集日が今日になり、
    //   それ以前の引き落としが消えてしまうため）。重複は handledDrawIds で防ぐ。
    final oldest = today.subtract(const Duration(days: 62));
    bool inWindow(DateTime d) => !d.isAfter(today) && !d.isBefore(oldest);

    // ① 銀行確定の引き落とし（カードごと・金額はメールに載っている）
    final bankDone = <String>{}; // 「カード|yyyy-MM」= 事前お知らせが来ている
    for (final p in payments) {
      if (p.source != PaymentSource.bank) continue;
      // 💡 請求の月で記録する（休みで翌月にずれた引落の確定が、翌月の別の請求を隠さないように）
      bankDone.add('${p.cardName}|${DateFormat('yyyy-MM').format(billMonthOf(p).month)}');
      if (!inWindow(p.paymentDate)) continue;
      final id = 'bank:${p.sourceId.isNotEmpty ? p.sourceId : _dupKey(p.cardName, p.amount, p.paymentDate, p.source)}';
      if (handledDrawIds.contains(id)) continue;
      out.add((id: id, label: p.cardName, amount: p.amount, date: p.paymentDate));
    }

    // ①' 事前お知らせメールが来ていないカードは、設定した引き落とし日で知らせる。
    //   金額は前月の利用合計から見込みで出す（ダイアログで直せる）。
    // 💡 日付・金額は予想と同じ規則（cardDrawDateOf・cardBillAmountOf）。締め日が月末以外のカードは
    //   締め期間で集計し、分割払い・カード払いのローン・頭金も合算する（以前は暦月の利用合計だけ）。
    //   ⚠️ 予想のゲート（残高を書いた日）はここでは使わない。確認待ちは「処理したか」で消える。
    for (final card in cardPaymentDays.keys) {
      if (_excludedFromDraw(card)) continue; // デビットなどは口座の引き落としではない
      for (var back = 0; back < 4; back++) {
        final m = DateTime(now.year, now.month - back); // 請求の月
        final date = cardDrawDateOf(card, m); // 土日祝・年末年始は翌営業日
        if (!inWindow(date)) continue;
        final ym = DateFormat('yyyy-MM').format(m); // 請求の月
        if (bankDone.contains('$card|$ym')) continue; // 事前お知らせ優先
        final amount = cardBillAmountOf(card, m);
        if (amount <= 0) continue;
        // ⚠️ ID は「請求の月」。休みで翌月にずれた引落（10/31→11/2 など）も、翌月分と別の ID になる。
        //   ずれていない引落は以前と同じ ID（引落日の月＝請求の月）なので、処理済みの記録はそのまま効く。
        //   ⚠️ 以前の版で「ずれた引落」を処理した記録（引落日の月の ID）は、翌月の別の請求と同じ文字列なので
        //     ここでは使わない（使うと翌月の正当な請求まで処理済みに見える）。そのため、ずれた引落が
        //     一度だけ再び出ることがあるが、「入力した残高に含まれている可能性」が表示され、
        //     基本の操作は「残高はそのまま確認」なので二重には引かれにくい。
        final id = 'card:$card:$ym';
        if (handledDrawIds.contains(id)) continue;
        out.add((id: id, label: '$card（予定）', amount: amount, date: date));
      }
    }

    // ② 口座振替＋手動払いの定期支払い（直近3か月ぶんを確認）。
    //   カード払いはカード請求に含まれるので対象外。
    //   一度「引く」か「スキップ」した月は handledDrawIds に入り、二度と出ない。
    for (final sub in subscriptions.where((e) => !e.isCardPayment)) {
      for (var back = 0; back < 3; back++) {
        final m = DateTime(now.year, now.month - back);
        // 💡 開始月より前の月は払っていない（口座振替・手動払いは、利用した月に払う）
        if (!sub.isUsedIn(m)) continue;
        // 💡 予想（subscriptionDrawsIn）と同じく、休みなら翌営業日（以前はそのままの日付だった）
        final date = drawDateInMonth(sub.payDay, m);
        if (!inWindow(date)) continue;
        final id = 'sub:${sub.id}:${DateFormat('yyyy-MM').format(m)}';
        if (handledDrawIds.contains(id)) continue;
        final label = sub.isManualPay ? '${sub.title}（手動）' : sub.title;
        out.add((id: id, label: label, amount: sub.amount, date: date));
      }
    }

    out.sort((a, b) => a.date.compareTo(b.date)); // 古い順
    return out;
  }

  // 💡 入金などで残高の基準日が進んだら、予想から外れてしまう未処理の引き落とし。
  // ⚠️ 予想は「基準日より後」の引き落としだけを引く。未処理のまま入金を反映すると
  //   基準日が今日に進み、日付の過ぎた引き落としが予想からも残高からも抜ける
  //   （画面は壊れず、予想が実際より多く見えるだけなので気づけない）。
  //   入金を反映する前に、これを先に確認してもらう。
  List<({String id, String label, int amount, DateTime date})>
      get drawsAtRiskOnSnapshotAdvance =>
          pendingDraws.where((d) => _forecastInclude(d.date)).toList();

  // 💡 ホームの「確認待ち」。重要な順（＝処理すべき順）に並べる。
  //   引き落としを入金より先に置く（上の drawsAtRiskOnSnapshotAdvance の理由）。
  List<HomeNotice> get homeNotices {
    final out = <HomeNotice>[];
    for (final d in pendingDraws) {
      out.add(HomeNotice(
        kind: HomeNoticeKind.draw,
        title: '引き落としの確認：${d.label}',
        detail: '${d.date.month}/${d.date.day} の引き落とし・${switch (drawReflectionOf(d.date)) {
          DrawReflection.maybeIncluded => '入力した残高に含まれている可能性があります',
          DrawReflection.likelyNotIncluded => 'まだ残高に入っていない見込みです',
          DrawReflection.unknown => '残高に入っているか確かめてください',
        }}',
        date: d.date,
        amount: d.amount,
        draw: d,
      ));
    }
    for (final n in [...pendingDeposits]..sort((a, b) => a.date.compareTo(b.date))) {
      // 💡 PayPayの出金の着金と見られるなら、金額まで分かっているのでそう出す
      final t = transferForDeposit(n);
      out.add(HomeNotice(
        kind: HomeNoticeKind.deposit,
        title: t != null ? 'PayPayからの入金' : '入金がありました',
        detail: t != null
            ? '${n.date.month}/${n.date.day} の振込入金（PayPayの出金 ${t.acceptedAt.month}/${t.acceptedAt.day}受付）'
            : '${n.date.month}/${n.date.day} の振込入金。金額を入れて反映します',
        date: n.date,
        amount: t?.amount,
        deposit: n,
      ));
    }
    for (final e in duePlannedIncomes) {
      out.add(HomeNotice(
        kind: HomeNoticeKind.plannedIncome,
        title: '予定入金の確認：${e.income.title.isEmpty ? '入金' : e.income.title}',
        detail: '${e.date.month}/${e.date.day} の予定です。受け取ったか確認してください',
        date: e.date,
        amount: e.income.amount,
        planned: e,
      ));
    }
    // 💡 請求の月を判定できない銀行確定（直近62日）。利用者が選ぶまで、影響する予想は「要確認」
    final recentFrom = DateTime(clockNow().year, clockNow().month, clockNow().day)
        .subtract(const Duration(days: 62));
    for (final p in unresolvedBankBills) {
      if (p.paymentDate.isBefore(recentFrom)) continue;
      out.add(HomeNotice(
        kind: HomeNoticeKind.bankBillMonthUnknown,
        title: 'どの月の請求か確認してください：${p.cardName}',
        detail: '${p.paymentDate.month}/${p.paymentDate.day} の引落確定（設定の引落日と合いません）',
        date: p.paymentDate,
        amount: p.amount,
        bankRecord: p,
      ));
    }
    final noCard = installmentsWithoutCard.where((i) => remainingMonthsOf(i) > 0);
    if (noCard.isNotEmpty) {
      out.add(HomeNotice(
        kind: HomeNoticeKind.installmentWithoutCard,
        title: 'カード未設定の分割払いが${noCard.length}件あります',
        detail: 'どのカードの請求に入るか決めると、予想が正確になります',
      ));
    }
    // 💡 予定の提案は、お金の確認待ちの後ろに置く（入出金の確認を埋もれさせない）。
    //   変更・取消を先に、そのあと新しい予定を日付順に。保留中はホームに出さない。
    for (final sg in pendingScheduleSuggestions) {
      out.add(HomeNotice(
        kind: HomeNoticeKind.scheduleSuggestion,
        title: switch (sg.action) {
          SuggestionAction.add => sg.kind == SuggestionKind.shift
              ? '勤務の確定が見つかりました：${sg.title}'
              : '予定が見つかりました：${sg.title}',
          SuggestionAction.change => '予定の変更：${sg.title}',
          SuggestionAction.cancel => '予定の取消：${sg.title}',
        },
        detail: [
          scheduleWhenLabel(sg),
          if (sg.location.isNotEmpty) sg.location,
          if (sg.sample) '見本',
        ].join('／'),
        date: sg.start,
        suggestion: sg,
      ));
    }
    return out;
  }

  // ───── メールから見つけた予定の提案 ─────
  // 💡 承認するまで、予定・シフト・収入・残高には何も入れない。
  //   登録・状態の更新は必ずここを通す（画面から addShift と状態更新を別々に呼ばない）。

  // ホームに出す提案（保留を除く）。変更・取消が先、そのあと開始日の順
  List<ScheduleSuggestion> get pendingScheduleSuggestions {
    final list =
        scheduleSuggestions.where((s) => s.status == SuggestionStatus.pending).toList();
    int rank(ScheduleSuggestion s) => s.action == SuggestionAction.add ? 1 : 0;
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return (a.start ?? DateTime(9999)).compareTo(b.start ?? DateTime(9999));
    });
    return list;
  }

  // 「11月12日 14:00〜15:30」のような日時の見出し
  static String scheduleWhenLabel(ScheduleSuggestion s) {
    final st = s.start;
    if (st == null) return '日時未定';
    final d = '${st.month}月${st.day}日';
    if (s.allDay) return '$d（終日）';
    String hm(DateTime t) => '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    final e = s.end;
    if (e == null) return '$d ${hm(st)}〜（終了未定）';
    final nextDay = e.day != st.day || e.month != st.month;
    return '$d ${hm(st)}〜${nextDay ? '翌' : ''}${hm(e)}';
  }

  String _linkKey(String accountKey, String entityKey) => '$accountKey|$entityKey';

  void _setMailEntityLinks(List raw) {
    mailEntityLinks
      ..clear()
      ..addAll({
        for (final e in raw)
          if (e is Map<String, dynamic>)
            _linkKey('${e['accountKey'] ?? ''}', '${e['entityKey'] ?? ''}'):
                MailEntityLink.fromJson(e),
      });
  }

  // 💡 新しい提案を受け取る。同じID（同じメールの同じ予約）は増やさない。
  //   ・確認待ち／保留のものは中身を新しくする（版を上げる）
  //   ・登録済み・却下済みのものは触らない（同じ通知で再提案しない）
  //   ・本人が消した予約の「追加」は復活させない
  //   戻り値は新しく増えた件数。
  int addScheduleSuggestions(Iterable<ScheduleSuggestion> incoming) {
    _ensureEditable();
    final alreadyOpen = scheduleSuggestions.where((s) => s.isOpen).map((s) => s.id).toSet();
    final ordered = incoming.toList()..sort((a, b) {
      final byTime = a.receivedAt.compareTo(b.receivedAt);
      if (byTime != 0) return byTime;
      return a.action.index.compareTo(b.action.index);
    });
    for (final sg in ordered) {
      final link = mailEntityLinks[_linkKey(sg.accountKey, sg.entityKey)];
      if (sg.action == SuggestionAction.add && link != null && link.removed) continue;
      bool sameEntity(ScheduleSuggestion o) =>
          o.id != sg.id && o.accountKey == sg.accountKey && o.entityKey == sg.entityKey;
      if (sg.action == SuggestionAction.add) {
        // 💡 不要にした同じ予約を、別メールのリマインドで再提案しない。
        if (scheduleSuggestions.any((o) => sameEntity(o) &&
            o.action == SuggestionAction.add && o.status == SuggestionStatus.rejected)) {
          continue;
        }
        if (scheduleSuggestions.any((o) => sameEntity(o) &&
            o.action == SuggestionAction.cancel &&
            !o.receivedAt.isBefore(sg.receivedAt))) {
          continue;
        }
        // 💡 同じ予約の前日案内・リマインドは、新しい提案にしない（登録済み、または確認待ちが既にある）
        if (link != null && !link.removed) continue;
        if (scheduleSuggestions.any((o) =>
            sameEntity(o) && o.action == SuggestionAction.add && o.isOpen)) {
          continue;
        }
      }
      if (sg.action != SuggestionAction.add && (link == null || link.removed)) {
        // 💡 取消は照合用の履歴に残す。取り消す相手が無い通知は確認待ちに出さない。
        if (sg.action == SuggestionAction.cancel) {
          for (final o in scheduleSuggestions.where((o) =>
              sameEntity(o) && o.action == SuggestionAction.add &&
              o.isOpen && !o.receivedAt.isAfter(sg.receivedAt))) {
            o.status = SuggestionStatus.superseded;
          }
          sg.status = SuggestionStatus.superseded;
        } else {
          continue;
        }
      }
      final i = scheduleSuggestions.indexWhere((e) => e.id == sg.id);
      if (i < 0) {
        scheduleSuggestions.add(sg);
        continue;
      }
      final old = scheduleSuggestions[i];
      if (!old.isOpen &&
          !(old.status == SuggestionStatus.superseded &&
              old.rulesVersion < sg.rulesVersion)) {
        continue;
      }
      sg
        ..version = old.version + 1
        ..status = old.isOpen ? old.status : sg.status;
      scheduleSuggestions[i] = sg;
    }
    saveData();
    notifyListeners();
    // ⚠️ 同じ取得内で取り消された候補を「見つかった件数」に含めない。
    return scheduleSuggestions.where((s) => s.isOpen && !alreadyOpen.contains(s.id)).length;
  }

  int retireOldScheduleSuggestions() {
    var count = 0;
    for (final s in scheduleSuggestions) {
      if (!s.sample && s.status == SuggestionStatus.pending &&
          s.rulesVersion < kScheduleRulesVersion) {
        s.status = SuggestionStatus.superseded;
        count++;
      }
    }
    return count;
  }

  // 💡 再解析で対象外になったメールの未操作候補も下げる。
  void reconcileScheduleScan(String account, Set<String> messageIds,
      List<ScheduleSuggestion> found) {
    final valid = found.map((s) => s.id).toSet();
    for (final s in scheduleSuggestions) {
      if (!s.sample && s.accountKey == account &&
          s.status == SuggestionStatus.pending &&
          messageIds.contains(s.messageId) && !valid.contains(s.id)) {
        s.status = SuggestionStatus.superseded;
      }
    }
  }

  void holdScheduleSuggestion(String id) => _setSuggestionStatus(id, SuggestionStatus.held);
  void rejectScheduleSuggestion(String id) =>
      _setSuggestionStatus(id, SuggestionStatus.rejected);

  // 💡 本人の操作で保留・不要から確認待ちへ戻す。登録済みや取消履歴は戻さない。
  void reopenScheduleSuggestion(String id) {
    _ensureEditable();
    final s = scheduleSuggestions.where((e) => e.id == id).firstOrNull;
    if (s == null || (s.status != SuggestionStatus.held &&
        s.status != SuggestionStatus.rejected)) {
      return;
    }
    s.status = SuggestionStatus.pending;
    saveData();
    notifyListeners();
  }

  void _setSuggestionStatus(String id, SuggestionStatus st) {
    _ensureEditable();
    final s = scheduleSuggestions.where((e) => e.id == id).firstOrNull;
    if (s == null || !s.isOpen) return;
    s.status = st;
    saveData();
    notifyListeners();
  }

  // 💡 確認画面で直した内容を提案に書き戻す（承認の前に呼ぶ）。版を上げる。
  void editScheduleSuggestion(
    String id, {
    required String title,
    required DateTime? start,
    required DateTime? end,
    required bool allDay,
    required String location,
  }) {
    _ensureEditable();
    final s = scheduleSuggestions.where((e) => e.id == id).firstOrNull;
    if (s == null || !s.isOpen) return;
    s
      ..title = title.trim()
      ..start = start
      ..end = allDay ? null : end
      ..allDay = allDay
      ..location = location.trim()
      ..version = s.version + 1;
    saveData();
    notifyListeners();
  }

  // 💡 処理済みの提案の履歴は、予定の終わりから90日で消す（2026-10-25 本人と決めた目安）。
  //   確認待ち・保留は消さない。予約⇔登録先の対応（mailEntityLinks）は残すので、
  //   消した予約を復活させない仕組みは期間に関係なく効く。
  static const Duration kSuggestionHistoryKeep = Duration(days: 90);

  int pruneScheduleSuggestions(DateTime now) {
    _ensureEditable();
    final limit = now.subtract(kSuggestionHistoryKeep);
    final before = scheduleSuggestions.length;
    scheduleSuggestions.removeWhere((s) {
      if (s.isOpen) return false;
      final last = s.end ?? s.start ?? s.receivedAt;
      return last.isBefore(limit);
    });
    final removed = before - scheduleSuggestions.length;
    if (removed > 0) {
      saveData();
      notifyListeners();
    }
    return removed;
  }

  // 💡 見本の提案（架空の説明会・面接・単発バイト）を入れる機能は 2026-11 に削除した。
  //   残っている未承認の見本は、起動時と取り込み時に片付ける（repairData → _removeSampleSuggestions）。
  //   ⚠️ 見本かどうかは sample の印だけで決める。「面接」などのタイトルで消すと、本物の予定まで消える。
  //     承認済みの見本（本人が登録した予定・シフトにつながっている）は、記録として残す。
  //   保存はしない（呼び出し側がまとめて保存する）。何度走らせても同じ結果。
  int _removeSampleSuggestions() {
    final before = scheduleSuggestions.length;
    scheduleSuggestions.removeWhere((s) => s.sample && s.status != SuggestionStatus.approved);
    return before - scheduleSuggestions.length;
  }

  ({String dateKey, int index})? _findShiftById(String id) {
    for (final e in shifts.entries) {
      final i = e.value.indexWhere((s) => s.id == id);
      if (i >= 0) return (dateKey: e.key, index: i);
    }
    return null;
  }

  ({String dateKey, int index})? _findEventById(String id) {
    for (final e in events.entries) {
      final i = e.value.indexWhere((x) => x.id == id);
      if (i >= 0) return (dateKey: e.key, index: i);
    }
    return null;
  }

  // 💡 提案を承認して、予定またはシフトとして登録する。戻り値は「できなかった理由」（null＝登録した）。
  //   ・登録先のIDは予約の安定IDから決める。途中で落ちてやり直しても、同じ予定・シフトに上書きされる
  //   ・シフトは勤務先を選び、休憩を本人が入れてから（給与は勤務先の設定で計算。AIには計算させない）
  //   ・変更・取消は、先に登録した予定／シフトにだけ当てる。見つからなければ何もしない
  //   as: 予定として／シフトとして、の本人の選択（提案の種類と違ってもよい）
  String? approveScheduleSuggestion(
    String id, {
    SuggestionKind? as,
    String? workplaceId,
    int? breakMinutes,
  }) {
    _ensureEditable();
    final s = scheduleSuggestions.where((e) => e.id == id).firstOrNull;
    if (s == null) return '提案が見つかりません';
    if (!s.isOpen) return 'この提案はもう処理済みです';
    final kind = as ?? s.kind;
    final key = _linkKey(s.accountKey, s.entityKey);
    final link = mailEntityLinks[key];

    if (s.blockers.isNotEmpty) return s.blockers.first;

    if (s.action == SuggestionAction.add) {
      final targetId = mailTargetId(s.accountKey, s.entityKey);
      if (kind == SuggestionKind.event) {
        upsertEvent(EventData(
          id: targetId,
          title: s.title.trim(),
          location: s.location,
          url: s.url,
          memo: [
            if (s.sender.isNotEmpty) '${s.sender}からのメール',
            if (s.evidence.isNotEmpty) s.evidence,
          ].join('\n'),
          allDay: s.allDay,
          start: s.start,
          end: s.allDay ? null : s.end,
        ));
      } else {
        final w = workplaceById(workplaceId);
        if (w == null) return '勤務先を選んでください';
        if (breakMinutes == null || breakMinutes < 0) return '休憩時間を入れてください';
        if (s.allDay || s.end == null) return '勤務の開始・終了時刻が必要です';
        final day = DateTime(s.start!.year, s.start!.month, s.start!.day);
        final shift = buildShiftFromWorkplace(w, day, s.start!, s.end!,
            breakMinutes: breakMinutes)
          ..id = targetId;
        final at = _findShiftById(targetId);
        if (at != null) {
          updateShift(at.dateKey, at.index, shift);
        } else {
          addShift(day, shift);
        }
      }
      mailEntityLinks[key] = MailEntityLink(
        entityKey: s.entityKey,
        accountKey: s.accountKey,
        targetRef: '${kind.name}:$targetId',
        approvedVersion: s.version,
      );
      s.targetRef = '${kind.name}:$targetId';
    } else {
      // 変更・取消は、登録済みの予定／シフトに当てる
      if (link == null || link.removed) {
        return s.action == SuggestionAction.cancel
            ? '取り消す予定が見つかりません（まだ登録していないか、もう消してあります）'
            : '変更する予定が見つかりません（先に元の予定を登録してください）';
      }
      final sep = link.targetRef.indexOf(':');
      final type = link.targetRef.substring(0, sep);
      final targetId = link.targetRef.substring(sep + 1);
      if (type == SuggestionKind.event.name) {
        final at = _findEventById(targetId);
        if (at == null) return '登録した予定が見つかりません（手で消した可能性があります）';
        if (s.action == SuggestionAction.cancel) {
          removeEvent(at.dateKey, at.index);
          link.removed = true;
        } else {
          final e = events[at.dateKey]![at.index];
          if (s.title.trim().isNotEmpty) e.title = s.title.trim();
          e
            ..start = s.start
            ..end = s.allDay ? null : s.end
            ..allDay = s.allDay;
          if (s.location.isNotEmpty) e.location = s.location;
          upsertEvent(e);
        }
      } else {
        final at = _findShiftById(targetId);
        if (at == null) return '登録したシフトが見つかりません（手で消した可能性があります）';
        if (s.action == SuggestionAction.cancel) {
          removeShift(at.dateKey, at.index);
          link.removed = true;
        } else {
          if (s.allDay || s.end == null) return '勤務の開始・終了時刻が必要です';
          final old = shifts[at.dateKey]![at.index];
          final w = workplaceById(old.workplaceId);
          final day = DateTime(s.start!.year, s.start!.month, s.start!.day);
          final moved = w != null
              ? buildShiftFromWorkplace(w, day, s.start!, s.end!,
                  breakMinutes: breakMinutes ?? old.breakMinutes,
                  overrideWage: old.hourlyWage)
              : ShiftData(
                  workplace: old.workplace,
                  hourlyWage: old.hourlyWage,
                  start: s.start!,
                  end: s.end!,
                  breakMinutes: breakMinutes ?? old.breakMinutes,
                );
          if (dateKey(day) == at.dateKey) {
            updateShift(at.dateKey, at.index, moved);
          } else {
            // 日付が変わったら箱を移す（IDとカレンダーの予定は同じまま）
            moved
              ..id = old.id
              ..calendarEventId = old.calendarEventId;
            final list = shifts[at.dateKey]!..removeAt(at.index);
            if (list.isEmpty) shifts.remove(at.dateKey);
            addShift(day, moved);
          }
        }
      }
      link.approvedVersion = s.version;
      s.targetRef = link.targetRef;
    }
    s.status = SuggestionStatus.approved;
    // 同じ予約・同じ種類の、まだ開いている古い提案は置き換わったことにする
    for (final o in scheduleSuggestions) {
      if (!identical(o, s) &&
          o.isOpen &&
          o.accountKey == s.accountKey &&
          o.entityKey == s.entityKey &&
          o.action == s.action) {
        o.status = SuggestionStatus.superseded;
      }
    }
    saveData();
    notifyListeners();
    return null;
  }

  // 💡 ホームに出す「今日・直近の予定」（シフトと予定をまとめて時刻順）。
  //   終わったものは出さない。終日の予定はその日の先頭に置く。
  List<({DateTime start, DateTime? end, String title, bool isShift, bool allDay})>
      upcomingSchedule({int days = 3, DateTime? from}) {
    final now = from ?? clockNow();
    final today = DateTime(now.year, now.month, now.day);
    final out = <({DateTime start, DateTime? end, String title, bool isShift, bool allDay})>[];
    for (var i = 0; i < days; i++) {
      final day = today.add(Duration(days: i));
      final key = dateKey(day);
      for (final s in shifts[key] ?? const <ShiftData>[]) {
        if (s.end.isBefore(now)) continue;
        out.add((start: s.start, end: s.end, title: s.workplace, isShift: true, allDay: false));
      }
      for (final e in events[key] ?? const <EventData>[]) {
        final start = e.allDay || e.start == null ? day : e.start!;
        final end = e.end;
        if (!e.allDay && end != null && end.isBefore(now)) continue;
        out.add((start: start, end: e.allDay ? null : end, title: e.title, isShift: false, allDay: e.allDay));
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  // 💡 引き落としを口座残高から引く（残高の編集日時も更新するので二重計上しない）
  // 💡 確認待ちの引き落としを残高から引く。戻り値: 実際に引いたら true。
  // ⚠️ 同じ引き落とし（同じ ID）は一度だけ。処理済みなら何もしない（連打・古い画面からの再操作・
  //   再起動後の再操作で二重に引かない）。判定は画面ではなくここで行う。
  bool applyDraw(String id, int amount, {String? label}) {
    _ensureEditable();
    if (handledDrawIds.contains(id)) return false;
    if (amount != 0) {
      _foldDebitsIntoBalance();
      currentBalance -= amount;
      balanceUpdatedAt = clockNow();
      _recordBalanceEntry(
        kind: BalanceEntryKind.draw,
        label: label ?? '引き落とし',
        amount: amount,
        sourceKey: id,
      );
    }
    handledDrawIds.add(id);
    saveData();
    notifyListeners();
    return true;
  }

  // 引き落としを「確認した」にする（残高は変えない。同じものは二度と出さない）。
  // 💡 入力した残高に含まれている可能性があるときの基本の操作。戻り値: 状態を変えたら true。
  bool skipDraw(String id) {
    _ensureEditable();
    if (!handledDrawIds.add(id)) return false;
    saveData();
    notifyListeners();
    return true;
  }

  // 💡 確認待ちの引き落としが、利用者が入力した残高に含まれているか（推定）。
  //   ⚠️ 前後関係だけで「反映済み」とは断定しない。表示も「可能性」「見込み」と言う。
  //   ・引落日が、残高を入力した日より前 → 含まれている可能性がある（基本は「残高はそのまま確認」）
  //   ・引落日が、残高を入力した日より後 → まだ含まれていない見込み
  //   ・同じ日・残高を入力した記録が無い → 判断できない（利用者に聞く）
  DrawReflection drawReflectionOf(DateTime drawDate) {
    final at = balanceEnteredAt;
    if (at == null) return DrawReflection.unknown;
    final d = DateTime(drawDate.year, drawDate.month, drawDate.day);
    final b = DateTime(at.year, at.month, at.day);
    if (d.isBefore(b)) return DrawReflection.maybeIncluded;
    if (d.isAfter(b)) return DrawReflection.likelyNotIncluded;
    return DrawReflection.unknown;
  }

  // 💡 未反映の見込みの引き落としだけをまとめて引く（含まれている可能性があるもの・判断できないものは引かない）。
  //   戻り値: 引いた件数と金額。
  ({int count, int amount}) applyLikelyNotIncludedDraws() {
    _ensureEditable();
    var count = 0, amount = 0;
    for (final d in List.of(pendingDraws)) {
      if (drawReflectionOf(d.date) != DrawReflection.likelyNotIncluded) continue;
      if (applyDraw(d.id, d.amount, label: d.label)) {
        count++;
        amount += d.amount;
      }
    }
    return (count: count, amount: amount);
  }

  // 未反映の引き落としをまとめてスキップ（過去分の一括整理用）
  void skipAllDraws() {
    _ensureEditable();
    for (final d in pendingDraws) {
      handledDrawIds.add(d.id);
    }
    saveData();
    notifyListeners();
  }

  // 口座からの支払いを手入力で引く（引き落とし・現金払いなど）
  void subtractFromBalance(int amount, {String label = '手入力'}) {
    _ensureEditable();
    if (amount == 0) return;
    _foldDebitsIntoBalance();
    currentBalance -= amount;
    balanceUpdatedAt = clockNow();
    _recordBalanceEntry(
      kind: BalanceEntryKind.draw,
      label: label,
      amount: amount,
    );
    saveData();
    notifyListeners();
  }

  // 入金通知をスキップ（残高は変えない。同じ通知は二度と出さない）
  void skipDepositNotice(String sourceId) {
    _ensureEditable();
    pendingDeposits.removeWhere((e) => e.sourceId == sourceId);
    handledDepositIds.add(sourceId);
    saveData();
    notifyListeners();
  }

  // ════════════════ 集計・残高予測 ════════════════

  // 指定月のシフト一覧を集める
  List<ShiftData> _shiftsInMonth(DateTime month) {
    final prefix = DateFormat('yyyy-MM').format(month);
    final out = <ShiftData>[];
    shifts.forEach((dateStr, list) {
      if (dateStr.startsWith(prefix)) out.addAll(list);
    });
    return out;
  }

  // 勤務先キー（workplaceId 優先、無ければ名前）
  String _shiftKey(ShiftData s) => s.workplaceId ?? 'name:${s.workplace}';

  // シフト群を勤務先ごとに集計し、交通費の月上限を適用した金額を返す。
  // 返り値: 勤務先キー → 給与合計（賃金＋上限適用後の交通費）
  Map<String, int> _aggregateByWorkplace(Iterable<ShiftData> list) {
    final wage = <String, int>{};
    final transport = <String, int>{};
    final cap = <String, int>{};
    for (final s in list) {
      final k = _shiftKey(s);
      wage[k] = (wage[k] ?? 0) + s.wageEarnings;
      transport[k] = (transport[k] ?? 0) + s.transportPerDay;
      if (s.transportMonthlyCap > 0 && s.transportMonthlyCap > (cap[k] ?? 0)) {
        cap[k] = s.transportMonthlyCap;
      }
    }
    final result = <String, int>{};
    for (final k in {...wage.keys, ...transport.keys}) {
      var t = transport[k] ?? 0;
      final c = cap[k] ?? 0;
      if (c > 0 && t > c) t = c; // 月上限を適用
      result[k] = (wage[k] ?? 0) + t;
    }
    return result;
  }

  // 指定月のシフト給与合計（交通費の月上限を適用）。＝給料見込み。
  int salaryOf(DateTime month) =>
      _aggregateByWorkplace(_shiftsInMonth(month)).values.fold(0, (s, v) => s + v);

  // 指定月の総労働時間（実働の合計・休憩除く）
  double workHoursOf(DateTime month) =>
      _shiftsInMonth(month).fold(0.0, (s, e) => s + e.workHours);

  // 指定月・勤務先名ごとの総労働時間（収入内訳の凡例用。ラベル＝勤務先名）
  double workHoursOfWorkplace(DateTime month, String workplaceName) =>
      _shiftsInMonth(month)
          .where((s) => (workplaceById(s.workplaceId)?.name ?? s.workplace) == workplaceName)
          .fold(0.0, (sum, s) => sum + s.workHours);

  // #3 指定月の勤務先ごとの収入詳細（キー・名前・色・見込み・実給料・労働時間）。
  List<({String key, String name, int colorValue, int estimated, int? actual, double hours})>
      incomeByWorkplaceOf(DateTime month) {
    final monthShifts = _shiftsInMonth(month);
    final est = _aggregateByWorkplace(monthShifts);
    final hoursByKey = <String, double>{};
    final nameByKey = <String, String>{};
    final colorByKey = <String, int>{};
    for (final s in monthShifts) {
      final k = _shiftKey(s);
      hoursByKey[k] = (hoursByKey[k] ?? 0) + s.workHours;
      final w = workplaceById(s.workplaceId);
      nameByKey[k] = w?.name ?? s.workplace;
      colorByKey[k] = w?.colorValue ?? 0xFF9E9E9E;
    }
    final out = <({String key, String name, int colorValue, int estimated, int? actual, double hours})>[];
    est.forEach((k, amount) {
      out.add((
        key: k,
        name: nameByKey[k] ?? k.replaceFirst('name:', ''),
        colorValue: colorByKey[k] ?? 0xFF9E9E9E,
        estimated: amount,
        actual: actualSalaryOfWorkplace(month, k),
        hours: hoursByKey[k] ?? 0,
      ));
    });
    // シフトが無い登録勤務先も「実給料を手入力」できるよう含める（4月以前など）
    for (final w in workplaces) {
      if (out.any((e) => e.key == w.id)) continue;
      out.add((
        key: w.id,
        name: w.name,
        colorValue: w.colorValue,
        estimated: 0,
        actual: actualSalaryOfWorkplace(month, w.id),
        hours: 0,
      ));
    }
    out.sort((a, b) {
      final c = b.estimated.compareTo(a.estimated);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return out;
  }

  // ───── 予算（カテゴリ別の月上限。カテゴリ名＝支出内訳のラベル）─────
  final Map<String, int> budgets = {};
  void setBudget(String category, int amount) {
    _ensureEditable();
    if (amount <= 0) {
      budgets.remove(category);
    } else {
      budgets[category] = amount;
    }
    saveData();
    notifyListeners();
  }

  // 予算が設定されたカテゴリの、指定月の予算と実績。over=超過。
  List<({String label, int budget, int spent, bool over})> budgetStatus(DateTime month) {
    final spentByLabel = {for (final e in expenseBreakdownOf(month)) e.label: e.amount};
    final out = <({String label, int budget, int spent, bool over})>[];
    budgets.forEach((label, budget) {
      final spent = spentByLabel[label] ?? 0;
      out.add((label: label, budget: budget, spent: spent, over: spent > budget));
    });
    out.sort((a, b) => (b.spent / b.budget).compareTo(a.spent / a.budget));
    return out;
  }

  // 今月に予算超過しているカテゴリ
  List<({String label, int budget, int spent, bool over})> get overBudgetThisMonth =>
      budgetStatus(clockNow()).where((e) => e.over).toList();

  // ───── 目標貯金（目標額＋目標年月）─────
  int goalAmount = 0; // 0 = 未設定
  DateTime? goalDate; // 目標年月（その月末までに達成したい）
  void setGoal(int amount, DateTime? date) {
    _ensureEditable();
    goalAmount = amount;
    goalDate = date;
    saveData();
    notifyListeners();
  }

  // 月あたりの純増ペース（来月末 − 今月末）。収入(給料日入金)−支出の見込み。
  int get monthlyNetPace => nextMonthBalance - thisMonthBalance;

  // 目標到達の予測。目標未設定なら null。
  ({int goal, DateTime date, int monthsLeft, int pace, int projected, bool achievable, int requiredMonthly})?
      savingsForecast() {
    if (goalAmount <= 0 || goalDate == null) return null;
    final now = clockNow();
    final monthsLeft =
        ((goalDate!.year - now.year) * 12 + (goalDate!.month - now.month)).clamp(0, 600);
    final pace = monthlyNetPace;
    final projected = currentBalance + pace * monthsLeft;
    final required = monthsLeft > 0
        ? ((goalAmount - currentBalance) / monthsLeft).ceil()
        : (goalAmount - currentBalance);
    return (
      goal: goalAmount,
      date: goalDate!,
      monthsLeft: monthsLeft,
      pace: pace,
      projected: projected,
      achievable: projected >= goalAmount,
      requiredMonthly: required,
    );
  }

  // ───── 実給料（手入力）─────
  // 旧: 月合計（yyyy-MM → 金額）。後方互換のため残す。
  final Map<String, int> actualSalaries = {};
  // 新: 勤務先別（"yyyy-MM|wpKey" → 金額）。#3
  final Map<String, int> actualSalariesByWp = {};

  String _ymKey(DateTime m) => DateFormat('yyyy-MM').format(m);
  String _wpSalKey(DateTime m, String wpKey) => '${_ymKey(m)}|$wpKey';

  // 月合計の実給料（勤務先別が入っていればその合計、無ければ旧・月合計）
  int? actualSalaryOf(DateTime month) {
    final byWp = _actualByWpTotal(month);
    if (byWp != null) return byWp;
    return actualSalaries[_ymKey(month)];
  }

  // その月に勤務先別の実給料が1件でも入力されていれば合計を返す（なければ null）
  int? _actualByWpTotal(DateTime month) {
    final keys = _aggregateByWorkplace(_shiftsInMonth(month)).keys;
    int total = 0;
    bool any = false;
    for (final k in keys) {
      final v = actualSalariesByWp[_wpSalKey(month, k)];
      if (v != null) {
        any = true;
        total += v;
      } else {
        // 実給料が未入力の勤務先は見込みで補完
        total += _salaryByWorkplaceOf(month)[k] ?? 0;
      }
    }
    return any ? total : null;
  }

  // #3 勤務先別の実給料を設定
  int? actualSalaryOfWorkplace(DateTime month, String wpKey) =>
      actualSalariesByWp[_wpSalKey(month, wpKey)];
  void setActualSalaryOfWorkplace(DateTime month, String wpKey, int? amount) {
    _ensureEditable();
    final key = _wpSalKey(month, wpKey);
    if (amount == null || amount <= 0) {
      actualSalariesByWp.remove(key);
    } else {
      actualSalariesByWp[key] = amount;
    }
    saveData();
    notifyListeners();
  }

  // 勤務先別の見込み給与（その月）
  Map<String, int> _salaryByWorkplaceOf(DateTime month) =>
      _aggregateByWorkplace(_shiftsInMonth(month));
  int estimatedSalaryOfWorkplace(DateTime month, String wpKey) =>
      _salaryByWorkplaceOf(month)[wpKey] ?? 0;
  // 勤務先別の手取り（実給料があればそれ、無ければ見込み）
  int takeHomeOfWorkplace(DateTime month, String wpKey) =>
      actualSalaryOfWorkplace(month, wpKey) ??
      estimatedSalaryOfWorkplace(month, wpKey);

  // 指定月の収入内訳（勤務先ごと。円グラフ用）。金額>0のみ・降順。
  List<({String label, int amount, int colorValue})> incomeBreakdownOf(DateTime month) {
    final monthShifts = _shiftsInMonth(month);
    final agg = _aggregateByWorkplace(monthShifts);
    // 勤務先マスタが見つからない場合はシフトの勤務先名を表示名に使う。
    final nameByKey = <String, String>{};
    final colorByKey = <String, int>{};
    for (final s in monthShifts) {
      final k = _shiftKey(s);
      final w = workplaceById(s.workplaceId);
      nameByKey[k] = w?.name ?? s.workplace;
      colorByKey[k] = w?.colorValue ?? 0xFF9E9E9E;
    }
    final out = <({String label, int amount, int colorValue})>[];
    agg.forEach((key, amount) {
      if (amount <= 0) return;
      out.add((
        label: nameByKey[key] ?? key.replaceFirst('name:', ''),
        amount: amount,
        colorValue: colorByKey[key] ?? 0xFF9E9E9E,
      ));
    });
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 指定月の支出内訳（カード別＋定期＋分割＋ATM。円グラフ用）。金額>0のみ・降順。
  // 💡 月ごとの支出（利用月ベース）のカード分のソース。
  //   三井住友銀行の「口座引き落とし事前お知らせ」は引落日＝利用月の翌月。
  //   よって 月Mの支出 ＝ 翌月(M+1)に引き落とされる銀行確定額（1ヶ月戻して計上）。
  //   銀行確定がまだ無い先月・今月は、その月の支払い管理（利用通知/請求予定/手動）で代替。
  //   いずれも手修正した金額がそのまま反映される。
  // その月の支出が銀行確定（事前お知らせ）で確定しているか。
  //   ＝翌月(M+1)に引き落とされる bank 明細が存在するか。
  bool isExpenseConfirmedByBank(DateTime month) {
    final nextMonth = DateTime(month.year, month.month + 1);
    return payments.any((p) => p.source == PaymentSource.bank && _isBillOf(p, nextMonth));
  }

  // 💡 その月（利用月）の請求が銀行の引落確定で決まっているカードと、その確定額。
  Map<String, int> _bankConfirmedTotalsOf(DateTime month) {
    final nextMonth = DateTime(month.year, month.month + 1);
    final bank = <String, int>{};
    for (final p in payments) {
      if (p.source == PaymentSource.bank && _isBillOf(p, nextMonth)) {
        bank[p.cardName] = (bank[p.cardName] ?? 0) + p.amount;
      }
    }
    return bank;
  }

  // 💡 そのカードの請求が銀行確定で決まっているか。
  //   確定額には分割払い・カード払いのローン・定期が既に含まれるので、足すと二重計上になる。
  // ⚠️ 判定は必ずカードごと。isExpenseConfirmedByBank（どれか1枚でも確定したか）で
  //   止めると、三井OLIVEの確定メールが1通来ただけで、まだ確定していない
  //   楽天や三菱の分割払いまで予想から消える（実際に起きた）。
  bool isCardConfirmedByBank(String cardName, DateTime month) =>
      _isConfirmedIn(cardName, _bankConfirmedTotalsOf(month));

  bool _isConfirmedIn(String cardName, Map<String, int> bank) =>
      bank.containsKey(cardName) || _coveredByOliveBank(cardName, bank);

  // 💡 Amazonマスターは三井住友(OLIVE)発行で、引き落としはOLIVEの請求に含まれる。
  //   OLIVEの銀行確定があるときはAmazon分を別計上しない（二重計上防止）。
  //   デビット/Vポイントペイは即時・プリペイドなので対象外（別枠のまま残す）。
  bool _coveredByOliveBank(String cardName, Map<String, int> bank) {
    if (!cardName.contains('Amazon')) return false;
    return bank.keys.any((k) =>
        !k.contains('デビット') &&
        !k.contains('ポイントペイ') &&
        (k.contains('OLIVE') || k.contains('三井')));
  }

  Map<String, int> paymentTotalsByCardOf(DateTime month) {
    bool sameYm(DateTime d, DateTime m) => d.year == m.year && d.month == m.month;
    final nextMonth = DateTime(month.year, month.month + 1);
    final result = <String, int>{};

    // ① 翌月に引き落とされる銀行確定（＝この月の利用分）
    final bank = <String, int>{};
    for (final p in payments) {
      if (p.source == PaymentSource.bank && _isBillOf(p, nextMonth)) {
        bank[p.cardName] = (bank[p.cardName] ?? 0) + p.amount;
      }
    }

    if (bank.isNotEmpty) {
      // 💡 銀行確定があるカードは、その確定額を正本にする（手動・利用通知も含んだ総額）。
      result.addAll(bank);
      // 💡 まだ確定していないカード（メルカード等）は消さず、その月の非bank明細
      //   （利用通知/請求予定/手動）で計上を続ける。確定したら上の確定額に置き換わる。
      for (final p in payments) {
        if (p.source == PaymentSource.bank) continue;
        if (p.infoOnly) continue; // 記録だけの明細は合計に足さない
        if (!sameYm(p.paymentDate, month)) continue;
        if (bank.containsKey(p.cardName)) continue; // 確定済み＝確定額が正本
        if (_coveredByOliveBank(p.cardName, bank)) continue; // Amazonは三井OLIVEの確定に含まれる
        result[p.cardName] = (result[p.cardName] ?? 0) + p.amount;
      }
      return result;
    }

    // ② 銀行確定が無い月（先月・今月）：その月の支払い管理（銀行確定以外）で代替
    // 💡 ここに infoOnly の除外が無かったため、確定メールが届くまでの期間だけ
    //   Amazonの買い物が二重計上されていた。
    for (final p in payments) {
      if (p.infoOnly) continue;
      if (p.source != PaymentSource.bank && sameYm(p.paymentDate, month)) {
        result[p.cardName] = (result[p.cardName] ?? 0) + p.amount;
      }
    }
    return result;
  }

  // 指定月の分割払いの月額合計（分割後の月額・金利込み）。
  // 💡 利用月ベース: 利用開始月(startDateの月)を1回目として、その月から installmentCount か月ぶん計上。
  //   （引き落とし月ではなく利用月で集計。例: 4月利用→4月の支出に表示）
  int installmentTotalOf(DateTime month) {
    int total = 0;
    final now = clockNow();
    for (final i in installments) {
      total += i.amountIn(month, now: now);
    }
    return total;
  }

  // 💡 分割払いの月額を、組んだカードごとに分ける。
  //   実際の引き落としは「分割払い」という独立した請求ではなく、
  //   それぞれのカードの請求に含まれて、そのカードの引き落とし日に落ちるため。
  Map<String, int> installmentTotalByCardOf(DateTime month) {
    final out = <String, int>{};
    final now = clockNow();
    for (final i in installments) {
      final card = i.cardName.trim();
      if (card.isEmpty) continue; // カード未設定は割り当てられない
      final amount = i.amountIn(month, now: now);
      if (amount > 0) out[card] = (out[card] ?? 0) + amount;
    }
    return out;
  }

  // 💡 そのカードの請求に合算されるぶん（分割払い・カード払いのローン・頭金）。
  //   月末締めのカードは expenseBreakdownOf の中で足されているので、
  //   こちらは締め期間で集計するカード（締め日が月末以外）のために使う。
  // ⚠️ 銀行の引落確定が来ている月は確定額が正本。足すと二重計上になる。
  int cardFoldedExtrasOf(String cardName, DateTime useMonth) {
    if (isCardConfirmedByBank(cardName, useMonth)) return 0;
    return (installmentTotalByCardOf(useMonth)[cardName] ?? 0) +
        (loanTotalByCardOf(useMonth)[cardName] ?? 0) +
        (downPaymentByCardOf(useMonth)[cardName] ?? 0);
  }

  // 💡 支払い画面の一覧の合計。表示中の明細（記録のみを除く）と、そのカードの請求に合算される分割払い。
  //   ・検索で絞っているときは明細の合計だけ（分割は足さない）
  //   ・カードで絞っているときはそのカードの分割（銀行確定済みなら確定額に含まれるので 0）
  //   ・絞っていないときは、確定していないカードの分割の合計（installmentFoldedInto）
  //   ⚠️ 以前は画面の中で同じ判定を書いていた（確定済みの判定を画面が複製していた）。
  ({int shownTotal, int installmentPart}) paymentListTotals({
    required DateTime month,
    required Iterable<Payment> shown,
    String? card,
    bool searching = false,
  }) {
    final shownTotal = shown.where((p) => !p.infoOnly).fold(0, (s, p) => s + p.amount);
    final installmentPart = searching
        ? 0
        : (card == null
            ? installmentFoldedInto(month)
            : (isCardConfirmedByBank(card, month)
                ? 0
                : (installmentTotalByCardOf(month)[card] ?? 0)));
    return (shownTotal: shownTotal, installmentPart: installmentPart);
  }

  // 💡 「うち分割払い」の注記に出す額＝実際にカードへ足し込んだ分割払いの合計。
  //   確定済みのカードは確定額の中に入っていて内訳が分からないので数えない
  //   （注記が合計より大きくなる、という食い違いを出さないため）。
  int installmentFoldedInto(DateTime month) {
    final bank = _bankConfirmedTotalsOf(month);
    var total = 0;
    installmentTotalByCardOf(month).forEach((card, amount) {
      if (!_isConfirmedIn(card, bank)) total += amount;
    });
    return total;
  }

  // 💡 カードが設定されていない分割払い（古いデータ）。
  //   どのカードにも足せないため、そのままだと予想から消えてしまう。
  //   別枠で残して、カードを設定するよう促す。
  int unassignedInstallmentTotalOf(DateTime month) {
    var total = 0;
    final now = clockNow();
    for (final i in installments) {
      if (i.cardName.trim().isNotEmpty) continue;
      total += i.amountIn(month, now: now);
    }
    return total;
  }

  // カード未設定のまま残っている分割払い（設定を促すために一覧で使う）
  List<Installment> get installmentsWithoutCard =>
      installments.where((i) => i.cardName.trim().isEmpty).toList();

  // 💡 利用月の支出（①）。カード・定期・ローン・分割・ATM を、月 M に使ったお金として集計する。
  //   残高のゲートは使わない（残高を書き直しても過去の支出は変わらない）。
  //   fromSettings は「明細の記録ではなく、今の設定（定期・分割・ローン）から計算したぶん」。
  //   定期には開始日が無いので、過去の月の定期は今の設定からの推定になる。
  List<({String label, int amount, int colorValue, int fromSettings})> _expenseItemsOf(
      DateTime month) {
    final totals = Map<String, int>.from(paymentTotalsByCardOf(month));
    final settings = <String, int>{};
    final bank = _bankConfirmedTotalsOf(month);

    // 💡 分割払い・カード払いのローン・頭金はカードの請求に含めて落ちるので、
    //   カードの金額に足し込む。そのカードが銀行確定済みなら確定額に既に
    //   含まれているため足さない（二重計上）。⚠️ 判定はカードごと。
    void fold(Map<String, int> byCard) {
      byCard.forEach((card, amount) {
        if (_isConfirmedIn(card, bank)) return;
        totals[card] = (totals[card] ?? 0) + amount;
        settings[card] = (settings[card] ?? 0) + amount;
      });
    }

    fold(installmentTotalByCardOf(month));
    fold(loanTotalByCardOf(month));
    fold(downPaymentByCardOf(month));

    final out = <({String label, int amount, int colorValue, int fromSettings})>[];
    totals.forEach((card, amount) {
      if (amount > 0) {
        out.add((
          label: card,
          amount: amount,
          colorValue: cardColorOf(card).toARGB32(),
          fromSettings: settings[card] ?? 0,
        ));
      }
    });

    // カードが決まっていない分割は足せないので、消さずに別枠で残す
    // 💡 どのカードの請求に入っているか分からないので、ここだけは
    //   「どれか1枚でも確定したら出さない」のまま（確定額に入っているかもしれないため）。
    //   カードを設定すればカードごとの判定に乗る。
    if (!isExpenseConfirmedByBank(month)) {
      final unassigned = unassignedInstallmentTotalOf(month);
      if (unassigned > 0) {
        out.add((
          label: '分割払い（カード未設定）',
          amount: unassigned,
          colorValue: Colors.deepOrange.toARGB32(),
          fromSettings: unassigned,
        ));
      }
    }
    // 💡 口座から直接引かれるローンは、返済日が個別なので1本ずつ出す
    for (final l in activeLoansIn(month)) {
      if (!l.isFromAccount) continue;
      // 💡 この利用月の翌月に銀行確定があれば、手動の予定額は足さない。
      if (_hasLoanBankBill(l, DateTime(month.year, month.month + 1))) continue;
      final amount = l.amountIn(month);
      out.add((
        label: l.name,
        amount: amount,
        colorValue: Colors.indigo.toARGB32(),
        fromSettings: amount,
      ));
    }
    final subTotal = subscriptionTotalOf(month);
    if (subTotal > 0) {
      out.add((
        label: '定期支払い',
        amount: subTotal,
        colorValue: Colors.purple.toARGB32(),
        fromSettings: subTotal,
      ));
    }
    final atm = withdrawalsOf(month);
    if (atm > 0) {
      out.add((label: 'ATM', amount: atm, colorValue: Colors.brown.toARGB32(), fromSettings: 0));
    }
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  List<({String label, int amount, int colorValue})> expenseBreakdownOf(DateTime month) => [
        for (final e in _expenseItemsOf(month))
          (label: e.label, amount: e.amount, colorValue: e.colorValue),
      ];

  /// 利用月の支出の合計と、そのうち今の設定から計算したぶん（推定）。
  ({int total, int fromSettings}) expenseSummaryOf(DateTime month) {
    var total = 0, settings = 0;
    for (final e in _expenseItemsOf(month)) {
      total += e.amount;
      settings += e.fromSettings;
    }
    return (total: total, fromSettings: settings);
  }

  /// 年間支出（利用月の支出を 1〜12 月ぶん足したもの）と、そのうち設定から計算したぶん。
  /// 💡 12 月の利用は翌年 1 月に引き落とされても、その年（12 月）の支出に入る。
  ({int total, int fromSettings}) expenseSummaryOfYear(int year) {
    var total = 0, settings = 0;
    for (var m = 1; m <= 12; m++) {
      final s = expenseSummaryOf(DateTime(year, m));
      total += s.total;
      settings += s.fromSettings;
    }
    return (total: total, fromSettings: settings);
  }

  // 支払い種別の表示名（明細詳細のサブ情報用）
  String sourceLabelOf(PaymentSource s) {
    switch (s) {
      case PaymentSource.manual:
        return '手動';
      case PaymentSource.usage:
        return '利用';
      case PaymentSource.billing:
        return '請求予定';
      case PaymentSource.bank:
        return '銀行確定';
    }
  }

  // 💡 指定月・指定カテゴリ（支出内訳のラベル）の個々の明細。合計は expenseBreakdownOf と一致。
  List<({String title, String subtitle, int amount})> expenseDetailOf(DateTime month, String label) {
    final out = <({String title, String subtitle, int amount})>[];
    bool sameYm(DateTime d, DateTime m) => d.year == m.year && d.month == m.month;

    if (label == '定期支払い') {
      // 💡 合計（subscriptionTotalOf）と同じ判定で並べる（開始月・銀行確定済みのカード）
      for (final s in subscriptionsUsedIn(month)) {
        out.add((title: s.title, subtitle: '毎月${s.payDay}日', amount: s.amount));
      }
    } else if (label == '分割払い（カード未設定）') {
      // 💡 合計（unassignedInstallmentTotalOf）と同じ判定で並べる
      final now = clockNow();
      for (final i in installments) {
        if (i.cardName.trim().isNotEmpty) continue;
        final amount = i.amountIn(month, now: now);
        if (amount > 0) {
          out.add((title: i.name, subtitle: i.countLabelIn(month), amount: amount));
        }
      }
    } else if (label == '分割払い') {
      // ⚠️ 合計（installmentTotalOf）と同じ判定で並べる。以前は開始日の無い旧データを
      //   合計には入れて内訳からは外していたので、内訳を足しても合計に届かなかった。
      final now = clockNow();
      for (final i in installments) {
        final amount = i.amountIn(month, now: now);
        if (amount > 0) {
          out.add((title: i.name, subtitle: i.countLabelIn(month), amount: amount));
        }
      }
    } else if (loans.any((l) => l.isFromAccount && l.name == label &&
        !_hasLoanBankBill(l, DateTime(month.year, month.month + 1)))) {
      for (final l in loans.where((e) => e.isFromAccount && e.name == label &&
          !_hasLoanBankBill(e, DateTime(month.year, month.month + 1)))) {
        final n = l.countIn(month);
        if (n == 0) continue;
        out.add((
          title: l.name,
          subtitle: '$n/${l.totalCount}回目 ・ 毎月${l.payDay}日',
          amount: l.amountForCount(n),
        ));
      }
    } else if (label == 'ATM') {
      for (final w in withdrawals) {
        if (sameYm(w.date, month)) {
          out.add((
            title: 'ATM引き出し',
            subtitle: '${DateFormat('M/d').format(w.date)}${w.memo.isNotEmpty ? ' ・ ${w.memo}' : ''}',
            amount: w.amount,
          ));
        }
      }
    } else {
      // カード：paymentTotalsByCardOf と同じ抽出ロジックで、そのカードの明細を返す。
      final nextMonth = DateTime(month.year, month.month + 1);
      // 💡 集計 paymentTotalsByCardOf と同じルール（合計と明細を一致させる）:
      //   ・このカードに銀行確定がある → 確定明細だけ（手動/利用通知は確定額に含まれる）
      //   ・まだ確定していない       → その月の非bank明細（利用通知/請求予定/手動）
      final cardHasBank = payments.any((p) =>
          p.cardName == label &&
          p.source == PaymentSource.bank &&
          _isBillOf(p, nextMonth));
      for (final p in payments) {
        if (p.cardName != label) continue;
        final belongs = cardHasBank
            ? (p.source == PaymentSource.bank && _isBillOf(p, nextMonth))
            : (p.source != PaymentSource.bank && sameYm(p.paymentDate, month));
        if (!belongs) continue;
        if (p.infoOnly) continue; // 記録のみ（他カードで計上済み）は合計に入っていない
        out.add((
          title: p.note.isNotEmpty ? p.note : sourceLabelOf(p.source),
          subtitle: '${sourceLabelOf(p.source)} ・ ${DateFormat('M/d').format(p.paymentDate)}',
          amount: p.amount,
        ));
      }
      // 💡 このカードで組んだ分割払いの当月ぶん。カードの請求に含めて落ちるので、
      //   合計にも足してあり、明細にも出す（銀行確定済みなら確定額に含まれるので出さない）。
      // 💡 このカードの請求に合算されるもの（分割払い・カード払いのローン・頭金）。
      //   合計（expenseBreakdownOf の fold）と同じ判定で並べる。銀行確定済みなら確定額に含まれるので出さない。
      // ⚠️ 以前は分割払いだけを出していて、ローン・頭金は合計にだけ入っていた（内訳を足しても届かない＝B5）。
      if (!_isConfirmedIn(label, _bankConfirmedTotalsOf(month))) {
        // ⚠️ 合計（installmentTotalByCardOf）と同じ判定で並べる（開始日の無い旧データも出す）
        final now = clockNow();
        for (final inst in installments.where((e) => e.cardName.trim() == label)) {
          final amount = inst.amountIn(month, now: now);
          if (amount > 0) {
            out.add((
              title: '分割: ${inst.name}',
              subtitle: '分割 ${inst.countLabelIn(month)}',
              amount: amount,
            ));
          }
        }
        for (final l in loans) {
          if (!l.isCardPayment || l.method != label || !l.isActiveIn(month)) continue;
          out.add((
            title: 'ローン: ${l.name}',
            subtitle: '${l.countIn(month)}/${l.totalCount}回目',
            amount: l.amountIn(month),
          ));
        }
        for (final l in loans) {
          final d = l.downPaymentDate;
          if (!l.hasDownPayment || l.isDownPaymentFromAccount || l.downPaymentMethod != label) {
            continue;
          }
          if (d!.year != month.year || d.month != month.month) continue;
          out.add((
            title: '頭金: ${l.name}',
            subtitle: '${d.month}/${d.day}',
            amount: l.downPayment,
          ));
        }
      }
    }
    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 💡 指定月・指定勤務先の収入明細（円グラフの収入詳細用）。シフト1件ごと。
  List<({String title, String subtitle, int amount})> incomeDetailOf(DateTime month, String label) {
    final out = <({String title, String subtitle, int amount})>[];
    for (final s in _shiftsInMonth(month)) {
      final name = workplaceById(s.workplaceId)?.name ?? s.workplace;
      if (name != label) continue;
      final d = s.start;
      out.add((
        title: '${d.month}/${d.day}（${s.workHours.toStringAsFixed(1)}h）',
        subtitle:
            '${TimeOfDay.fromDateTime(s.start).hour}:${s.start.minute.toString().padLeft(2, '0')}'
            '〜${TimeOfDay.fromDateTime(s.end).hour}:${s.end.minute.toString().padLeft(2, '0')}',
        amount: s.earnings,
      ));
    }
    out.sort((a, b) {
      // 日付順（古い→新しい）
      return a.title.compareTo(b.title);
    });
    return out;
  }

  // ───── 年間集計（過去データの振り返り・年収計算用）─────
  // データが存在する年の一覧（新しい順）
  List<int> get dataYears {
    final years = <int>{};
    for (final k in shifts.keys) {
      final y = int.tryParse(k.split('-').first);
      if (y != null) years.add(y);
    }
    for (final p in payments) {
      years.add(p.paymentDate.year);
    }
    final list = years.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  // 💡 扶養・社保の「壁」。学生/主婦バイトの働き方の目安。
  static const List<({int amount, String label})> incomeWalls = [
    (amount: 1030000, label: '103万（所得税）'),
    (amount: 1060000, label: '106万（社保・大企業）'),
    (amount: 1300000, label: '130万（社保扶養）'),
    (amount: 1500000, label: '150万（配偶者特別控除）'),
  ];

  // 指定年の年収に対する「次の壁」と残り金額。全部超えていれば nextWall=null。
  ({int income, ({int amount, String label})? nextWall, int remaining}) incomeWallStatus(int year) {
    final income = salaryOfYear(year);
    for (final w in incomeWalls) {
      if (income < w.amount) {
        return (income: income, nextWall: w, remaining: w.amount - income);
      }
    }
    return (income: income, nextWall: null, remaining: 0);
  }

  // 指定年の給与合計（年収・見込み）。交通費の月上限は月ごとに適用するため月単位で合算。
  int salaryOfYear(int year) {
    int total = 0;
    for (var m = 1; m <= 12; m++) {
      total += salaryOf(DateTime(year, m));
    }
    return total;
  }

  // #2 見込み年収（＝salaryOfYear のエイリアス）
  int estimatedSalaryOfYear(int year) => salaryOfYear(year);

  // #2 実年収（実給料を入力した月だけ合計。未入力の月は計上しない）
  int actualSalaryOfYear(int year) {
    int total = 0;
    for (var m = 1; m <= 12; m++) {
      final month = DateTime(year, m);
      // 勤務先別の実入力分のみ合計
      final keys = _salaryByWorkplaceOf(month).keys;
      for (final k in keys) {
        final v = actualSalariesByWp[_wpSalKey(month, k)];
        if (v != null) total += v;
      }
      // 旧・月合計の実給料も加算（勤務先別が無い場合）
      if (keys.every((k) => actualSalariesByWp[_wpSalKey(month, k)] == null)) {
        final old = actualSalaries[_ymKey(month)];
        if (old != null) total += old;
      }
    }
    return total;
  }

  // #2 実給料が1件でも入力されている年か
  bool hasActualSalaryInYear(int year) {
    for (var m = 1; m <= 12; m++) {
      final month = DateTime(year, m);
      if (actualSalaries[_ymKey(month)] != null) return true;
      for (final k in _salaryByWorkplaceOf(month).keys) {
        if (actualSalariesByWp[_wpSalKey(month, k)] != null) return true;
      }
    }
    return false;
  }

  // 直近 months か月の月次推移（収入＝給料見込み・支出＝支出内訳合計）。古い順。
  List<({DateTime month, int income, int expense})> monthlyTrend(int months) {
    final now = clockNow();
    final out = <({DateTime month, int income, int expense})>[];
    for (var i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i);
      final income = salaryOf(m);
      final expense = expenseBreakdownOf(m).fold(0, (s, e) => s + e.amount);
      out.add((month: m, income: income, expense: expense));
    }
    return out;
  }

  // 指定年の総支出（各月の支出内訳合計を12か月ぶん。円グラフ中央の年支出用）
  int expenseOfYear(int year) => expenseSummaryOfYear(year).total;

  // 定期支払い（毎月固定）合計
  int get subscriptionTotal =>
      subscriptions.fold(0, (sum, s) => sum + s.amount);

  // 💡 指定月の支出に載せる定期支払いの合計。
  //   カード払いの定期は、その月が銀行確定していればカードの引き落とし額に既に含まれるので除く
  //   （分割払いと同じ二重計上対策）。口座振替の定期は常に計上する。
  //   開始月より前の月には載せない（開始月が未設定なら、従来どおりどの月にも載せる）。
  int subscriptionTotalOf(DateTime month) =>
      subscriptionsUsedIn(month).fold(0, (sum, s) => sum + s.amount);

  // 指定月の支出（利用月）に載せる定期支払い。subscriptionTotalOf と支出の明細で同じものを使う。
  List<Subscription> subscriptionsUsedIn(DateTime month) {
    // ⚠️ 判定は定期ごとの支払いカード単位。どれか1枚の確定で全部止めると、
    //   まだ確定していないカードで払っている定期まで予想から消える。
    final bank = _bankConfirmedTotalsOf(month);
    return subscriptions
        .where((s) => s.isUsedIn(month))
        .where((s) => !s.isCardPayment || !_isConfirmedIn(s.method, bank))
        .toList();
  }

  // ───── ローン ─────
  // 💡 口座から直接引かれるローンは、返済日が個別なので1本ずつのスライスにする。
  //   （まとめて1つにすると、分割払いで起きたのと同じ「引き落とし日のズレ」が出る）
  List<Loan> activeLoansIn(DateTime month) =>
      loans.where((l) => l.isActiveIn(month)).toList();

  // カード払いのローンは、そのカードの請求に含めて落ちる
  Map<String, int> loanTotalByCardOf(DateTime month) {
    final out = <String, int>{};
    for (final l in loans) {
      if (!l.isCardPayment || !l.isActiveIn(month)) continue;
      out[l.method] = (out[l.method] ?? 0) + l.amountIn(month);
    }
    return out;
  }

  void addLoan({
    required String name,
    required int principal,
    required int totalCount,
    required DateTime startMonth,
    double interestRate = 0,
    int payDay = 27,
    String method = '',
    int monthlyOverride = 0,
    int firstPaymentAmount = 0,
  }) {
    _ensureEditable();
    loans.add(Loan(
      id: _id(),
      name: name.trim(),
      principal: principal,
      totalCount: totalCount < 1 ? 1 : totalCount,
      startMonth: DateTime(startMonth.year, startMonth.month),
      interestRate: interestRate,
      payDay: payDay.clamp(1, 31),
      method: method,
      monthlyOverride: monthlyOverride,
      firstPaymentAmount: firstPaymentAmount,
    ));
    repairLoanBillingLinks();
    saveData();
    notifyListeners();
  }

  void updateLoan(Loan loan) {
    _ensureEditable();
    repairLoanBillingLinks();
    saveData();
    notifyListeners();
  }

  // ───── 予定支出（一時的な出費）─────
  // 💡 ローンの月々や定期支払いと違い、決まった日に一度だけ出ていく。
  //   引き落としの「n月＝n-1月の利用ぶん」の月ズレは当てはまらないので、
  //   その日付の月にそのまま引く。
  String _plannedExpenseKey(String id, DateTime date) =>
      '$id|${DateFormat('yyyy-MM').format(date)}';

  void addPlannedExpense(
      {required String title,
      required int amount,
      required DateTime date,
      bool monthly = false}) {
    _ensureEditable();
    plannedExpenses.add(PlannedExpense(
        id: _id(), title: title.trim(), amount: amount, date: date, monthly: monthly));
    saveData();
    notifyListeners();
  }

  void removePlannedExpense(String id) {
    _ensureEditable();
    plannedExpenses.removeWhere((e) => e.id == id);
    paidPlannedExpenseKeys.removeWhere((k) => k.startsWith('$id|'));
    saveData();
    notifyListeners();
  }

  void updatePlannedExpense(String id, {
    required String title,
    required int amount,
    required DateTime date,
    required bool monthly,
  }) {
    _ensureEditable();
    final expense = plannedExpenses.firstWhere((e) => e.id == id);
    expense
      ..title = title.trim()
      ..amount = amount
      ..date = date
      ..monthly = monthly;
    saveData();
    notifyListeners();
  }

  // 支払い済みにする（残高からは既に引かれているので、予想では二重に引かない）
  // 💡 予定日より前に払ったとき用。予定日を過ぎていれば、残高を書き直した時点で
  //   二重計上ゲート（_forecastInclude）が外すので、ここを使わなくても二重にはならない。
  void markPlannedExpensePaid(String id, DateTime date) {
    _ensureEditable();
    paidPlannedExpenseKeys.add(_plannedExpenseKey(id, date));
    saveData();
    notifyListeners();
  }

  // 払い済みを取り消す（押し間違えたとき）
  void unmarkPlannedExpensePaid(String id, DateTime date) {
    _ensureEditable();
    paidPlannedExpenseKeys.remove(_plannedExpenseKey(id, date));
    saveData();
    notifyListeners();
  }

  bool isPlannedExpensePaid(String id, DateTime date) =>
      paidPlannedExpenseKeys.contains(_plannedExpenseKey(id, date));

  // 💡 次に来る、まだ払っていない回の予定日（今日以降。1年先まで探す）。
  //   毎月の予定支出は、今月分を払い済みにすると来月分になる。
  DateTime? nextUnpaidPlannedExpenseDate(PlannedExpense e, {DateTime? now}) {
    final n = now ?? clockNow();
    final today = DateTime(n.year, n.month, n.day);
    for (var dm = 0; dm <= 12; dm++) {
      final d = e.dateIn(DateTime(n.year, n.month + dm));
      if (d == null || d.isBefore(today)) continue;
      if (isPlannedExpensePaid(e.id, d)) continue;
      return d;
    }
    return null;
  }

  // その月に出ていく予定の出費（まだ払っていないもの）
  List<({PlannedExpense expense, DateTime date})> plannedExpensesIn(DateTime month) {
    final out = <({PlannedExpense expense, DateTime date})>[];
    for (final e in plannedExpenses) {
      final d = e.dateIn(month);
      if (d == null) continue;
      if (paidPlannedExpenseKeys.contains(_plannedExpenseKey(e.id, d))) continue;
      out.add((expense: e, date: d));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 💡 その月に一度だけ出ていくお金（ローンの頭金＋予定支出）。
  //   月々の返済や定期費用と違って、実際の日付の月にそのまま引く。
  List<({String label, int amount, DateTime date})> oneTimeExpensesIn(DateTime month) {
    final out = <({String label, int amount, DateTime date})>[];
    for (final l in loans) {
      final d = l.downPaymentDate;
      if (!l.hasDownPayment || !l.isDownPaymentFromAccount) continue;
      if (d!.year != month.year || d.month != month.month) continue;
      // ⚠️ 頭金は日付どおりの月。翌月の請求では消さない。
      if (_hasLoanBankBill(l, month, onDate: nextBusinessDay(d),
          minimumAmount: l.downPayment)) {
        continue;
      }
      out.add((label: '${l.name} 頭金', amount: l.downPayment, date: d));
    }
    for (final e in plannedExpensesIn(month)) {
      out.add((label: e.expense.title, amount: e.expense.amount, date: e.date));
    }
    out.sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  // 予想に入れるぶん（残高を書いた日より後のものだけ＝二重に引かない）
  int oneTimeExpenseForecastIn(DateTime month) => oneTimeExpensesIn(month)
      .where((e) => _forecastInclude(e.date))
      .fold(0, (s, e) => s + e.amount);

  // カード払いの頭金は、そのカードの請求に含まれて落ちる
  Map<String, int> downPaymentByCardOf(DateTime month) {
    final out = <String, int>{};
    for (final l in loans) {
      final d = l.downPaymentDate;
      if (!l.hasDownPayment || l.isDownPaymentFromAccount) continue;
      if (d!.year != month.year || d.month != month.month) continue;
      out[l.downPaymentMethod] = (out[l.downPaymentMethod] ?? 0) + l.downPayment;
    }
    return out;
  }

  void removeLoan(String id) {
    _ensureEditable();
    loans.removeWhere((l) => l.id == id);
    saveData();
    notifyListeners();
  }

  // 指定月のATM引き出し合計
  int withdrawalsOf(DateTime month) {
    final prefix = DateFormat('yyyy-MM').format(month);
    return withdrawals
        .where((w) => DateFormat('yyyy-MM').format(w.date) == prefix)
        .fold(0, (sum, w) => sum + w.amount);
  }

  // 💡 給料日までのズレ（月）。勤務先の paydayMonthOffset の最頻値（無ければ翌月=1）。
  //   締日締め→給料日に入金、を予測へ反映するために使う。
  int get paydayOffsetMonths {
    if (workplaces.isEmpty) return 1;
    final counts = <int, int>{};
    for (final w in workplaces) {
      counts[w.paydayMonthOffset] = (counts[w.paydayMonthOffset] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  // その月の手取り（実給料があればそれ、無ければ給料見込み）
  int takeHomeOf(DateTime month) => actualSalaryOf(month) ?? salaryOf(month);

  // 指定月に「給料日として入金される」見込み額。＝給料日offsetぶん前の労働月の手取り。
  int incomeArrivingIn(DateTime payMonth) {
    final wm = DateTime(payMonth.year, payMonth.month - paydayOffsetMonths);
    return takeHomeOf(wm);
  }

  // ────── #5 #6 デビット即時引き落とし ──────
  bool _isDebit(String card) => card.contains('デビット');

  // #6 スナップショット日より「後」のイベントだけ予測へ反映するための判定。
  //   基準日が無い（未編集）なら過去全部を引くと誤るので false（反映しない）。
  bool _afterSnapshot(DateTime d) {
    final since = balanceUpdatedAt;
    if (since == null) return false;
    return d.isAfter(DateTime(since.year, since.month, since.day));
  }

  // #5 #6 残高編集後に使ったデビット（即時口座引落）のうち、まだ残高に入っていない合計。
  int debitsAfterSnapshot() => payments
      .where((p) =>
          _isDebit(p.cardName) &&
          _afterSnapshot(p.paymentDate) &&
          !foldedDebitKeys.contains(_debitKey(p)))
      .fold(0, (s, p) => s + p.amount);

  String _debitKey(Payment p) =>
      _dupKey(p.cardName, p.amount, p.paymentDate, p.source);

  // #5 #6 実効的な現在残高＝編集時の残高 − 編集後に使ったデビット。
  int get effectiveBalance => currentBalance - debitsAfterSnapshot();

  String _wpKeyOf(Workplace w) => w.id;

  // 💡 予想残高の引き落としソース判定：口座から実際に引き落とされないものは除外。
  bool _excludedFromDraw(String label) =>
      label.contains('デビット') ||
      label.contains('ポイントペイ') ||
      label == 'ATM';

  // 二重計上防止ゲート：日付が「残高を編集した日」より後なら予想へ反映（true）。
  //   基準日が無ければ従来どおり全部反映（true）。
  bool _forecastInclude(DateTime d) {
    final since = balanceUpdatedAt;
    if (since == null) return true;
    return d.isAfter(DateTime(since.year, since.month, since.day));
  }

  // 引き落とし項目の「引き落とし日(日)」を推定（ゲート判定用）。
  // 💡 そのカードの、その月の実際の引き落とし日。
  //   設定した日が土日祝なら翌営業日にずれる（カードの引き落としは後ろ倒しが一般的）。
  DateTime cardDrawDateOf(String cardName, DateTime month) =>
      drawDateInMonth(cardPaymentDays[cardName] ?? 27, month);

  int _drawDayOf(String label) {
    final card = cardPaymentDays[label];
    if (card != null) return card;
    // ローンは名前がそのままラベルになる。自分の返済日で落ちる。
    for (final l in loans) {
      if (l.isFromAccount && l.name == label) return l.payDay;
    }
    if (label == '定期支払い' && subscriptions.isNotEmpty) {
      return subscriptions.map((s) => s.payDay).reduce((a, b) => a < b ? a : b);
    }
    return 27; // 分割など、日付が無いものは月末寄りの27日とみなす
  }

  // 💡 n月にその項目が口座から引き落とされる日。
  //   銀行の引落確定が来ていれば、そこに載っている実際の日付を使う。
  //   無ければ設定した引き落とし日（土日祝なら翌営業日）。
  // ⚠️ 反映済みかどうか（残高の基準日より前か）の判定はこの日付で行う。
  //   設定日で判定すると、実際の日付とズレたとき「残高から引いたのに予想でも
  //   また引く」二重計上や、逆に「まだ落ちていないのに予想から消える」が起きる。
  DateTime drawDateOf(String label, DateTime payMonth) {
    DateTime? bankDate;
    for (final p in payments) {
      if (p.source != PaymentSource.bank || p.cardName != label) continue;
      if (!_isBillOf(p, payMonth)) continue; // 請求の月で選ぶ（日付は実際の引落日のまま）
      final d = DateTime(p.paymentDate.year, p.paymentDate.month, p.paymentDate.day);
      if (bankDate == null || d.isAfter(bankDate)) bankDate = d;
    }
    if (bankDate != null) return bankDate; // ⚠️ 確定の日付は再調整しない
    return drawDateInMonth(_drawDayOf(label), payMonth);
  }

  // 💡 この日に使ったら、どの引き落とし日に入るか（手入力の画面と明細の詳細で見せる）。
  //   締め日・引落日が設定されていないカードは null（推測で日付を出さない）。
  //   ⚠️ 計算（drawBreakdownOf / cardClosingPeriodOf）と同じ決まりにすること：
  //     月末締め … 利用月の翌月
  //     n日締め  … n日までの利用は翌月、n+1日以降は翌々月
  DateTime? drawDateForUsage(String cardName, DateTime usageDate) {
    if (!cardPaymentDays.containsKey(cardName)) return null;
    final payMonth =
        payMonthOfUsage(closingDay: closingDayOf(cardName), usageDate: usageDate);
    return drawDateOf(cardName, payMonth);
  }

  // n月に口座から引き落とされる支出の内訳。＝ n-1月の「月ごとの支出詳細」から
  //   デビット/Vポイント/ATMを除き、編集日より後の引き落としだけを残す。
  List<({String label, int amount, int colorValue})> drawBreakdownOf(DateTime payMonth) {
    final useMonth = DateTime(payMonth.year, payMonth.month - 1);

    // 二重計上ゲート（引き落とし日が残高の編集日より後か）
    bool afterEdit(String label) => _forecastInclude(drawDateOf(label, payMonth));

    final out = <({String label, int amount, int colorValue})>[];

    // 💡 締め日を月末以外にしたカードは、暦月ではなく締め期間で集計する。
    //   （月末締めのカードと定期/分割は従来どおり「前月の支出詳細」を使う）
    final byPeriod = <String>{};
    for (final card in cardPaymentDays.keys) {
      if (isMonthEndClosing(card) || _excludedFromDraw(card)) continue;
      byPeriod.add(card);
      if (!afterEdit(card)) continue;
      // ⚠️ 締め期間で集計するのは「利用明細」だけ。分割払い・カード払いのローン・
      //   頭金は月ごとに積まれるので、ここで足さないと丸ごと消える
      //   （注記には「うち分割払い」と出るのに合計に入っていない状態になる）。
      final amount = cardBillAmountOf(card, payMonth);
      if (amount <= 0) continue;
      out.add((label: card, amount: amount, colorValue: cardColorOf(card).toARGB32()));
    }

    for (final e in expenseBreakdownOf(useMonth)) {
      if (byPeriod.contains(e.label)) continue; // 締め期間で集計済み
      if (_excludedFromDraw(e.label)) continue;
      if (e.label == '定期支払い') continue; // 下で 1 件ずつ足す
      if (!afterEdit(e.label)) continue;
      out.add(e);
    }
    // ⚠️ 定期はまとめて1行だが、支払日は1件ずつ違う。まとめた行の日付（いちばん早い支払日）で
    //   判断すると、早い定期が過ぎただけで、まだ落ちていない月末の定期まで消えていた。
    //   1件ずつの引き落とし日で、残高を書き直した日より後のものだけ足す。
    // ⚠️ 前月の支出に「定期支払い」が有るかでは決めない。口座振替の定期は利用した月に落ちるので、
    //   開始月（その月が最初の利用）の引き落としが、前月に定期が無いせいで消えていた。
    if (!_excludedFromDraw('定期支払い')) {
      final subAmount = subscriptionDrawsIn(payMonth).fold(0, (s, d) => s + d.amount);
      if (subAmount > 0) {
        out.add((label: '定期支払い', amount: subAmount, colorValue: Colors.purple.toARGB32()));
      }
    }

    out.sort((a, b) => b.amount.compareTo(a.amount));
    return out;
  }

  // 💡 そのカードの payMonth の請求額（ゲートなし）。予想（drawBreakdownOf）と確認待ち（pendingDraws）が使う。
  //   ・締め日が月末以外 … 締め期間の利用（銀行確定があれば確定額）＋分割・カード払いのローン・頭金
  //   ・月末締め … 前月の支出（expenseBreakdownOf）のそのカードの額（同じものを合算済み）
  int cardBillAmountOf(String card, DateTime payMonth) {
    final useMonth = DateTime(payMonth.year, payMonth.month - 1);
    if (!isMonthEndClosing(card)) {
      // ⚠️ 締め期間で集計するのは「利用明細」だけ。分割払い・カード払いのローン・
      //   頭金は月ごとに積まれるので、ここで足さないと丸ごと消える。
      return cardUsageInClosingPeriod(card, payMonth) + cardFoldedExtrasOf(card, useMonth);
    }
    return expenseBreakdownOf(useMonth)
        .where((e) => e.label == card)
        .fold(0, (s, e) => s + e.amount);
  }

  // 💡 payMonth に口座から落ちる定期支払い（1件ずつ、その引き落とし日つき）。
  //   ・口座振替・手動払い … 定期の支払日（休みなら翌営業日）
  //   ・カード払い … そのカードの引き落とし日（カードの請求として落ちるため）
  //   どれを含めるかは subscriptionTotalOf と同じ（カード払いで銀行確定済みのカードは、
  //   確定額に含まれるので除く。開始月より前の利用は載せない）。残高を書き直した日より前に落ちたものも除く（二重計上ゲート）。
  List<({String title, int amount, DateTime date})> subscriptionDrawsIn(DateTime payMonth) {
    final useMonth = DateTime(payMonth.year, payMonth.month - 1);
    final bank = _bankConfirmedTotalsOf(useMonth);
    final out = <({String title, int amount, DateTime date})>[];
    for (final s in subscriptions) {
      if (s.isCardPayment && _isConfirmedIn(s.method, bank)) continue;
      // 💡 開始月＝最初の利用月。口座振替・手動払いは利用した月に、カード払いは翌月に口座から落ちる
      if (!s.isUsedIn(s.isCardPayment ? useMonth : payMonth)) continue;
      final date = s.isCardPayment
          ? cardDrawDateOf(s.method, payMonth)
          : drawDateInMonth(s.payDay, payMonth);
      if (!_forecastInclude(date)) continue;
      out.add((title: s.title, amount: s.amount, date: date));
    }
    return out;
  }

  // n月に引き落とされる合計（＝ n-1月の支出詳細・除外分とゲート済みを除く）。
  int drawnInMonth(DateTime payMonth) =>
      drawBreakdownOf(payMonth).fold(0, (s, e) => s + e.amount);

  // 💡 n月の引き落としのうち、分割払いぶんはいくらか（参考表示用）。
  //   各カードの金額に既に含まれているので、合計には足さないこと。
  int installmentPartOfDraw(DateTime payMonth) =>
      installmentFoldedInto(DateTime(payMonth.year, payMonth.month - 1));

  // 予想用：n月に入金される給料のうち、給料日が編集日より後の勤務先分のみ。
  //   （既に受け取って残高に反映済みの給料を二重に足さない）
  int incomeForecastIn(DateTime payMonth) {
    if (balanceUpdatedAt == null || workplaces.isEmpty) {
      // 基準日なし→従来どおり（予定入金は足す）
      return incomeArrivingIn(payMonth) + plannedIncomeForecastIn(payMonth);
    }
    int total = 0;
    for (final w in workplaces) {
      final wm = DateTime(payMonth.year, payMonth.month - w.paydayMonthOffset);
      final payDate = w.paydayIn(payMonth); // 土日祝の調整を反映
      if (_forecastInclude(payDate)) total += takeHomeOfWorkplace(wm, w.id);
    }
    total += plannedIncomeForecastIn(payMonth); // 予定入金も足す
    return total;
  }

  // 財布の現金（機能ONのときだけ表示する）。
  // ⚠️ 口座の予想には入れない（財布のお金は口座の引き落としに使えないため）。表示だけに使う。
  int get effectiveWalletCash => showWalletCash ? walletCash : 0;

  // ════════════ 残高の予想（1 つの行の並びから全部を作る） ════════════
  // 💡 月末の金額・内訳・日ごとの並び・最低残高・足りなくなる日は、すべて forecastMonths の行から作る。
  //   規則（何をいつ引くか）は材料の関数（incomeForecastIn と同じ分岐・transfersForecastIn・
  //   drawBreakdownOf・subscriptionDrawsIn・oneTimeExpensesIn）にあり、ここは行に並べるだけ。
  //   ⚠️ 以前は「起点＋入金−引き落とし−一度きり」が 7 か所に書かれていた。
  //     足し引きを増やすときは _forecastLinesOf にだけ足す（lib/finance/forecast.dart）。
  //   計算中に保存・通知・状態の変更はしない（読み取りだけ）。

  // 今月の起点＝デビット調整済みの口座残高。
  // ⚠️ 財布の現金は足さない（口座の残高の予想なので。以前は財布を足していて、財布の表示を切り替えると
  //   月末・最低残高・足りない日・不足の通知まで変わっていた）。
  int get forecastStart => effectiveBalance;

  /// 今月から [count] か月ぶんの予想（[0] が今月）。
  /// 💡 行は「実際の日付の月」に入れる。引落日・給料日が休みで月をまたぐと
  ///   （月末払いの 10/31 土 → 11/2、12/31 → 1/4、1日払いの給料が前営業日へ など）、
  ///   元の月の月末予想ではなく、実際に動く月の予想に入る。
  ///   ⚠️ 以前は元の月で引いていたので、日ごとの並び（谷）と月末予想が食い違っていた。
  ///   ・前月分の行は、今月以降にずれ込んだものだけ拾う（前月中の動きは今まで通り予想に入れない）
  ///   ・今月分で、日付が今月より前にずれたものは今月に入れる（まだ残高に入っていない可能性があるため。
  ///     残高を書いた日より前のものは、行を作る時点でゲートが外している）
  List<MonthForecast> forecastMonths({int count = 3}) {
    final now = clockNow();
    final first = DateTime(now.year, now.month, 1);
    int bucketOf(DateTime d) =>
        (d.year - first.year) * 12 + (d.month - first.month); // 0 = 今月
    final buckets = List.generate(count, (_) => <ForecastLine>[]);
    // 今月以降の分を先に、前月からずれ込んだ分を後に並べる（今月の並びを今までと同じにするため）
    for (final s in [for (var i = 0; i <= count; i++) i, -1]) {
      final source = DateTime(first.year, first.month + s, 1);
      for (final l in _forecastLinesOf(source)) {
        var b = bucketOf(l.date);
        if (s >= 0 && b < 0) b = 0; // 今月以降の分が前月の日付にずれた → 今月に入れる
        if (b < 0 || b >= count) continue;
        // 入金のまとめ名は、入った月で決める（今月だけ「編集後」）
        buckets[b].add(l.kind == ForecastKind.income
            ? ForecastLine(
                kind: l.kind,
                label: l.label,
                group: b == 0 ? '給料入金（編集後）' : '給料入金',
                amount: l.amount,
                date: l.date,
                certainty: l.certainty,
                needsReview: l.needsReview,
              )
            : l);
      }
    }
    final out = <MonthForecast>[];
    var start = forecastStart;
    for (var i = 0; i < count; i++) {
      final f = MonthForecast(
          month: DateTime(first.year, first.month + i, 1), start: start, lines: buckets[i]);
      out.add(f);
      start = f.end;
    }
    return out;
  }

  // 💡 実給料が入っていれば確定、無ければシフトからの見込み
  Certainty _salaryCertainty(DateTime workMonth, String? wpKey) {
    if (wpKey != null) {
      return actualSalaryOfWorkplace(workMonth, wpKey) != null
          ? Certainty.confirmed
          : Certainty.estimated;
    }
    final keys = _salaryByWorkplaceOf(workMonth).keys;
    final allActual = keys.isNotEmpty &&
        keys.every((k) => actualSalariesByWp[_wpSalKey(workMonth, k)] != null);
    final legacy = keys.every((k) => actualSalariesByWp[_wpSalKey(workMonth, k)] == null) &&
        actualSalaries[_ymKey(workMonth)] != null;
    return allActual || legacy ? Certainty.confirmed : Certainty.estimated;
  }

  // 💡 その月の引き落としが銀行の引落確定で決まっているか（カード・口座払いローン）
  Certainty _drawCertainty(String label, DateTime payMonth) {
    final useMonth = DateTime(payMonth.year, payMonth.month - 1);
    if (cardPaymentDays.containsKey(label) || payments.any((p) => p.cardName == label)) {
      return isCardConfirmedByBank(label, useMonth) ? Certainty.confirmed : Certainty.estimated;
    }
    if (label == '分割払い（カード未設定）') return Certainty.estimated;
    return Certainty.scheduled; // 口座払いのローンなど、自分で登録したもの
  }

  // 予想の行（その月ぶん）。並び順: 入金 → 予定入金 → PayPay → 引き落とし（金額の大きい順）→ 一度きり
  List<ForecastLine> _forecastLinesOf(DateTime m) {
    final out = <ForecastLine>[];
    final lastDay = DateTime(m.year, m.month + 1, 0).day;
    final isThisMonth = () {
      final n = clockNow();
      return n.year == m.year && n.month == m.month;
    }();
    final incomeGroup = isThisMonth ? '給料入金（編集後）' : '給料入金';

    // ── 入金（incomeForecastIn と同じ分岐） ──
    if (balanceUpdatedAt == null || workplaces.isEmpty) {
      // 💡 勤務先ごとに分けられない経路。日付は給料日に寄せる
      //   （勤務先があればいちばん早い給料日、無ければ既定の25日）。
      final amount = incomeArrivingIn(m);
      if (amount != 0) {
        final dates = [for (final w in workplaces) w.paydayIn(m)]..sort();
        final wm = DateTime(m.year, m.month - paydayOffsetMonths);
        out.add(ForecastLine(
          kind: ForecastKind.income,
          label: '給料',
          group: incomeGroup,
          amount: amount,
          date: dates.isEmpty ? DateTime(m.year, m.month, 25 > lastDay ? lastDay : 25) : dates.first,
          certainty: _salaryCertainty(wm, null),
        ));
      }
    } else {
      for (final w in workplaces) {
        final wm = DateTime(m.year, m.month - w.paydayMonthOffset);
        final payDate = w.paydayIn(m);
        if (!_forecastInclude(payDate)) continue;
        final amount = takeHomeOfWorkplace(wm, w.id);
        if (amount == 0) continue;
        out.add(ForecastLine(
          kind: ForecastKind.income,
          label: w.name,
          group: incomeGroup,
          amount: amount,
          date: payDate,
          certainty: _salaryCertainty(wm, w.id),
        ));
      }
    }
    for (final e in plannedIncomesIn(m)) {
      if (!_forecastInclude(e.date)) continue;
      out.add(ForecastLine(
        kind: ForecastKind.income,
        label: e.income.title,
        group: incomeGroup,
        amount: e.income.amount,
        date: e.date,
        certainty: Certainty.scheduled,
      ));
    }
    // PayPayからの出金（振込予定日に入る）
    for (final t in transfersForecastIn(m)) {
      out.add(ForecastLine(
        kind: ForecastKind.transfer,
        label: 'PayPayからの入金',
        group: 'PayPayからの入金（${t.scheduledDate.month}/${t.scheduledDate.day}頃）',
        amount: t.amount,
        date: t.scheduledDate,
        certainty: Certainty.scheduled,
      ));
    }

    // ── 引き落とし（drawBreakdownOf がゲート済み。日付と確からしさを付ける） ──
    final review = _billsNeedingReview;
    for (final e in drawBreakdownOf(m)) {
      final group = drawLabelOf(e.label, m);
      if (e.label == '定期支払い') {
        // 定期は1件ずつの引き落とし日に置く（まとめた日付にすると谷の日がずれる）
        for (final d in subscriptionDrawsIn(m)) {
          out.add(ForecastLine(
            kind: ForecastKind.draw,
            label: '定期: ${d.title}',
            group: group,
            amount: -d.amount,
            date: d.date,
            certainty: Certainty.scheduled,
          ));
        }
        continue;
      }
      out.add(ForecastLine(
        kind: ForecastKind.draw,
        label: e.label,
        group: group,
        amount: -e.amount,
        date: drawDateOf(e.label, m), // 判定と同じ日付に置く
        certainty: _drawCertainty(e.label, m),
        // 💡 請求の月を判定できない銀行確定があるカードは、その前後の請求を「要確認」にする
        needsReview: review.contains('${e.label}|${_ym(m)}'),
      ));
    }

    // ── 一度きりの出費（頭金・予定支出。月ズレさせず日付どおり） ──
    for (final e in oneTimeExpensesIn(m)) {
      if (!_forecastInclude(e.date)) continue;
      out.add(ForecastLine(
        kind: ForecastKind.oneTime,
        label: e.label,
        group: '${e.label}（${e.date.month}/${e.date.day}）',
        amount: -e.amount,
        date: e.date,
        certainty: Certainty.scheduled,
      ));
    }
    return out;
  }

  // 今月末・来月末・翌々月末の予想残高
  int get thisMonthBalance => forecastMonths(count: 1)[0].end;
  int get nextMonthBalance => forecastMonths(count: 2)[1].end;
  int get monthAfterNextBalance => forecastMonths(count: 3)[2].end;

  // ────── 予想の谷（月末と月末のあいだ） ──────
  // 💡 月末の予想は「その月の引き落としを全部引いた後」なので、
  //   月末を越えてから次の給料日までに落ちるぶん（例：10日引き落としのカード）で
  //   足りなくなる谷が見えない。日付に並べ直して、いちばん減る日を出す。
  List<CashEvent> cashEventsAhead({int monthsAhead = 2}) => [
        for (final l in linesByDate(forecastMonths(count: monthsAhead + 1)))
          CashEvent(date: l.date, label: l.label, amount: l.amount),
      ];

  // 日付順の予想の行（確からしさつき）。次の引き落としの一覧などに使う
  List<ForecastLine> forecastLinesAhead({int monthsAhead = 2}) =>
      linesByDate(forecastMonths(count: monthsAhead + 1));

  // 💡 これから口座から出ていくもの（今日から [days] 日以内、日付順）。ホームの「次の引き落とし」。
  //   予想と同じ行なので、金額・日付・確定／見込みは月末の予想と一致する。
  List<ForecastLine> upcomingOutflows({int days = 30}) {
    final n = clockNow();
    final today = DateTime(n.year, n.month, n.day);
    final until = today.add(Duration(days: days));
    return [
      for (final l in forecastLinesAhead())
        if (l.amount < 0 && !l.date.isBefore(today) && l.date.isBefore(until)) l,
    ];
  }

  // 💡 残高を書いてから何日たったか（未入力なら null）。古い残高は予想もずれるので画面で知らせる。
  int? get daysSinceBalanceUpdate {
    final at = balanceUpdatedAt;
    if (at == null) return null;
    final n = clockNow();
    return DateTime(n.year, n.month, n.day)
        .difference(DateTime(at.year, at.month, at.day))
        .inDays;
  }

  // 💡 今日から先で、残高がいちばん少なくなる日とそのときの残高。
  ({DateTime date, int balance})? lowestBalanceAhead({int monthsAhead = 2}) => lowestBalance(
        start: forecastStart,
        events: forecastLinesAhead(monthsAhead: monthsAhead),
        today: clockNow(),
      );

  // 💡 残高が足りなくなる日と、その日の引き落とし。
  //   最低残高（＝いちばん低い1日）だけだと「どの引き落としで割ったか」が分からず、
  //   どれを遅らせればいいか判断できないので、割る日を全部返す。
  List<({DateTime date, int balance, List<String> labels})> shortfallDaysAhead(
          {int monthsAhead = 2}) =>
      shortfallDays(
        start: forecastStart,
        events: forecastLinesAhead(monthsAhead: monthsAhead),
        today: clockNow(),
      );


  Future<void> setShowMonthAfterNext(bool on) async {
    showMonthAfterNext = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_show_month_after_next', on);
    notifyListeners();
  }

  Future<void> setShowWalletCash(bool on) async {
    showWalletCash = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_show_wallet_cash', on);
    notifyListeners();
  }

  Future<void> setBackgroundTheme(String key) async {
    backgroundTheme = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_background_theme', key);
    notifyListeners();
  }

  // ────── 給料日ヘルパー ──────
  // 指定月(workMonth)の給料日を全勤務先分返す。#4 金額は勤務先ごとの手取り。
  List<({DateTime date, Workplace workplace, int amount})> paydaysInMonth(DateTime month) {
    final result = <({DateTime date, Workplace workplace, int amount})>[];
    for (final w in workplaces) {
      final payMonth = DateTime(month.year, month.month + w.paydayMonthOffset);
      final payDate = w.paydayIn(payMonth); // 土日祝は設定に応じて前後にズラす
      // #4 その勤務先・その労働月の手取りのみ（月総額ではない）
      final amount = takeHomeOfWorkplace(month, _wpKeyOf(w));
      if (amount > 0) result.add((date: payDate, workplace: w, amount: amount));
    }
    return result;
  }

  // 表示範囲（前後N月）の全給料日を返す。
  List<({DateTime date, Workplace workplace, int amount})> paydaysNear(DateTime center, {int before = 2, int ahead = 3}) {
    final result = <({DateTime date, Workplace workplace, int amount})>[];
    for (var dm = -before; dm <= ahead; dm++) {
      result.addAll(paydaysInMonth(DateTime(center.year, center.month + dm)));
    }
    return result;
  }

  // 指定日付の給料日エントリを返す（カレンダー表示用）。
  List<({Workplace workplace, int amount, DateTime date})> paydaysOnDay(DateTime date) {
    return paydaysNear(date).where((e) =>
      e.date.year == date.year && e.date.month == date.month && e.date.day == date.day
    ).toList();
  }

  // 💡 カレンダー: その日に口座から落ちるカードの請求（カード別）。
  //   請求額と実際の引落日は予想と同じもの（cardBillAmountOf・drawDateOf・請求の月の判定）を使う。
  //   ・締め日が月末以外のカードは締め期間、分割・カード払いのローン・頭金も合算した額
  //   ・休みで翌月にずれた引落（10/31土 → 11/2）は、ずれた先の日に出す
  //   ・銀行確定があれば確定（日付も確定の日付）
  //   ⚠️ 予想のゲート（残高を書いた日）は使わない。残高を書く前の引落もカレンダーには残す。
  //   ⚠️ 以前は前月の暦月の利用合計だけで、締め期間・分割・ずれた引落を見ていなかった。
  List<({String cardName, int amount, bool isConfirmed})> cardPaymentSummaryOnDay(DateTime date) {
    final day = DateTime(date.year, date.month, date.day);
    final months = [DateTime(day.year, day.month - 1), DateTime(day.year, day.month)];
    final result = <({String cardName, int amount, bool isConfirmed})>[];
    final shown = <String>{};

    // 設定したカード（請求の月ごとに、予想と同じ額）。まだ利用が無ければ 0 円で引落日だけ出す
    for (final card in cardPaymentDays.keys) {
      if (_excludedFromDraw(card)) continue;
      for (final m in months) {
        if (drawDateOf(card, m) != day) continue;
        final confirmed = payments.any((p) =>
            p.source == PaymentSource.bank && !p.infoOnly && p.cardName == card && _isBillOf(p, m));
        result.add((cardName: card, amount: cardBillAmountOf(card, m), isConfirmed: confirmed));
        shown.add(card);
      }
    }
    // 設定していない名前の銀行確定（ローンの請求元など）は、確定の日にその額を出す
    final bankOnly = <String, int>{};
    for (final p in payments) {
      if (p.source != PaymentSource.bank || p.infoOnly || shown.contains(p.cardName)) continue;
      if (DateTime(p.paymentDate.year, p.paymentDate.month, p.paymentDate.day) != day) continue;
      bankOnly[p.cardName] = (bankOnly[p.cardName] ?? 0) + p.amount;
    }
    bankOnly.forEach((card, amount) {
      result.add((cardName: card, amount: amount, isConfirmed: true));
    });
    return result;
  }

  void setCardPaymentDay(String cardName, int day) {
    _ensureEditable();
    cardPaymentDays[cardName] = day;
    _saveCardPaymentDays();
    notifyListeners();
  }

  // 💡 カード設定の保存も、ふつうの保存（saveData）の列を通す。
  // ⚠️ 以前はここだけ SharedPreferences に直接書いていたため、ふつうの保存の途中で設定を変えると、
  //   後から書かれた古い値で上書きされ、再起動すると変更前の引落日に戻っていた（GPT 実装レビュー P1）。
  //   保存の入口は saveData 1 つにする（一時保存・直列化・失敗の扱いがそろう）。
  Future<void> _saveCardPaymentDays() => saveData();

  // 💡 カード選択に出す一覧。設定で登録したカードに加え、
  //   既存の明細・分割・定期に出てくるカード名も拾う。
  //   （設定で追加したのに選べない／過去データのカードが選べない、を防ぐ）
  static const String kOtherCard = 'その他';

  List<String> get cardChoices {
    final out = <String>[];
    void add(String? name) {
      final n = (name ?? '').trim();
      if (n.isEmpty || n == kOtherCard) return;
      if (!out.contains(n)) out.add(n);
    }

    for (final k in cardPaymentDays.keys) {
      add(k);
    }
    for (final p in payments) {
      add(p.cardName);
    }
    for (final i in installments) {
      add(i.cardName);
    }
    for (final s in subscriptions) {
      if (s.isCardPayment) add(s.method);
    }
    out.add(kOtherCard); // 「その他」は必ず最後
    return out;
  }

  // カードの締め日（未設定＝31＝月末締め）
  int closingDayOf(String cardName) => cardClosingDays[cardName] ?? 31;

  bool isMonthEndClosing(String cardName) => isMonthEndClosingDay(closingDayOf(cardName));

  // 💡 カードを設定から外す。明細は消さない（過去の記録は残す）。
  //   cardChoices は明細に出てくるカード名も拾うので、過去データの表示は壊れない。
  void removeCard(String cardName) {
    _ensureEditable();
    cardPaymentDays.remove(cardName);
    cardClosingDays.remove(cardName);
    _saveCardPaymentDays();
    notifyListeners();
  }

  /// カードのアイコン（自分の画像）。null なら既定のマーク。
  String? cardIconOf(String cardName) => cardIcons[cardName];

  /// 自分の画像を設定する（[pngBase64] が null なら既定のマークに戻す）。保存まで成功したら true。
  /// ⚠️ 保存に失敗したら（容量不足など）、メモリを前のアイコンに戻して false を返す。
  ///   保存は「全部そろったときだけ有効」なので、端末の家計データ・元のアイコンは壊れない。
  Future<bool> setCardIcon(String cardName, String? pngBase64) async {
    _ensureEditable();
    final before = cardIcons[cardName];
    if (pngBase64 == null || pngBase64.isEmpty) {
      cardIcons.remove(cardName);
    } else {
      cardIcons[cardName] = pngBase64;
    }
    notifyListeners();
    try {
      await saveData();
      return true;
    } catch (_) {
      if (before == null) {
        cardIcons.remove(cardName);
      } else {
        cardIcons[cardName] = before;
      }
      notifyListeners();
      // 💡 戻した状態で保存し直す（これも失敗したら storageIssue のまま。前の整った保存は残っている）
      try {
        await saveData();
      } catch (_) {}
      return false;
    }
  }

  void setCardClosingDay(String cardName, int day) {
    _ensureEditable();
    cardClosingDays[cardName] = day.clamp(1, 31);
    _saveCardPaymentDays();
    notifyListeners();
  }

  // 締め日の表示用ラベル
  String closingLabelOf(String cardName) =>
      isMonthEndClosing(cardName) ? '月末締め' : '${closingDayOf(cardName)}日締め';

  // 💡 内訳に出す表示名。締め日が月末以外のカードは対象期間も添える
  //   （「なぜこの金額なのか」が分からなくなるため）。
  String drawLabelOf(String label, DateTime payMonth) {
    if (!cardPaymentDays.containsKey(label) || isMonthEndClosing(label)) return label;
    final r = cardClosingPeriodOf(label, payMonth);
    return '$label（${r.start.month}/${r.start.day}〜${r.end.month}/${r.end.day}利用）';
  }

  // 💡 payMonth に引き落とされる利用の対象期間。
  //   締め日 C なら「前々月C日の翌日 〜 前月C日」。
  //   月末締め(31)ならちょうど前月1日〜前月末日になり、従来の暦月集計と一致する。
  ({DateTime start, DateTime end}) cardClosingPeriodOf(String cardName, DateTime payMonth) =>
      closingPeriod(closingDay: closingDayOf(cardName), payMonth: payMonth);

  // 💡 締め期間で集計したカード利用額。
  //   銀行の引落確定メールが来ている月は、その確定額を正本にする（従来と同じ扱い）。
  int cardUsageInClosingPeriod(String cardName, DateTime payMonth) {
    var bank = 0;
    for (final p in payments) {
      if (p.source != PaymentSource.bank) continue;
      if (p.cardName != cardName) continue;
      if (_isBillOf(p, payMonth)) bank += p.amount;
    }
    if (bank > 0) return bank;

    final r = cardClosingPeriodOf(cardName, payMonth);
    var total = 0;
    for (final p in payments) {
      if (p.source == PaymentSource.bank) continue;
      if (p.infoOnly) continue; // 記録だけの明細は合計に足さない
      if (p.cardName != cardName) continue;
      final d = DateTime(p.paymentDate.year, p.paymentDate.month, p.paymentDate.day);
      if (d.isBefore(r.start) || d.isAfter(r.end)) continue;
      total += p.amount;
    }
    return total;
  }

  // 💡 月末の予想の内訳（タップ詳細用）。forecastMonths と同じ行を group ごとにまとめる。
  //   今月は起点を「現在の残高・デビット」に分けて見せ、翌月以降は前月末から始める（財布は口座の予想に入れない）。
  Map<String, int> _breakdownOf(int offset) {
    final months = forecastMonths(count: offset + 1);
    final f = months[offset];
    final out = <String, int>{};
    if (offset == 0) {
      out['現在の残高'] = currentBalance;
      final debit = debitsAfterSnapshot();
      if (debit > 0) out['デビット利用（編集後・即時引落）'] = -debit;
    } else {
      out[offset == 1 ? '今月末残高' : '来月末残高'] = f.start;
    }
    for (final g in f.grouped()) {
      out[g.group] = (out[g.group] ?? 0) + g.amount;
    }
    return out;
  }

  Map<String, int> get thisMonthBreakdown => _breakdownOf(0);
  Map<String, int> get nextMonthBreakdown => _breakdownOf(1);
  Map<String, int> get monthAfterNextBreakdown => _breakdownOf(2);


  // ════════════════ バックアップ（エクスポート/インポート）════════════════
  // 全データを1つのJSON文字列に書き出す（機種変・バックアップ用）。
  String exportJson() {
    final map = {
      'version': 1,
      'exportedAt': clockNow().toIso8601String(),
      'shifts': shifts.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'workplaces': workplaces.map((e) => e.toJson()).toList(),
      'actualSalaries': actualSalaries,
      'actualSalariesByWp': actualSalariesByWp,
      'balanceUpdatedAt': balanceUpdatedAt?.toIso8601String(),
      'balanceEnteredAt': balanceEnteredAt?.toIso8601String(),
      'paymentNotes': paymentNotes,
      'amazonCardOverrides': amazonCardOverrides,
      'cardAliases': cardAliases,
      'bankBillMonths': bankBillMonths,
      // 💡 カレンダーのイベントIDは同じGoogleアカウントで共通。別の端末で同じ給料日を
      //   二重に作らないよう、同期データにも入れる。
      'specialCalendarIds': specialCalendarIds,
      'specialCalendarSigs': specialCalendarSigs,
      'cardPaymentDays': cardPaymentDays,
      'cardClosingDays': cardClosingDays,
      'cardIcons': cardIcons,
      'events': events.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'todos': todos.map((k, v) => MapEntry(k, v.map((e) => e.toJson()).toList())),
      'payments': payments.map((e) => e.toJson()).toList(),
      'installments': installments.map((e) => e.toJson()).toList(),
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'loans': loans.map((e) => e.toJson()).toList(),
      'plannedExpenses': plannedExpenses.map((e) => e.toJson()).toList(),
      'paidPlannedExpenseKeys': paidPlannedExpenseKeys.toList(),
      'scheduleSuggestions': scheduleSuggestions.map((e) => e.toJson()).toList(),
      'mailEntityLinks': mailEntityLinks.values.map((e) => e.toJson()).toList(),
      'withdrawals': withdrawals.map((e) => e.toJson()).toList(),
      'currentBalance': currentBalance,
      'walletCash': walletCash,
      'pendingDeposits': pendingDeposits.map((e) => e.toJson()).toList(),
      'paypayTransfers': paypayTransfers.map((e) => e.toJson()).toList(),
      'receivedTransfers': receivedTransfers,
      'handledDepositIds': handledDepositIds.toList(),
      'handledDrawIds': handledDrawIds.toList(),
      'balanceHistory': balanceHistory.map((e) => e.toJson()).toList(),
      'paidSalaryKeys': paidSalaryKeys.toList(),
      'plannedIncomes': plannedIncomes.map((e) => e.toJson()).toList(),
      'receivedPlannedKeys': receivedPlannedKeys.toList(),
      'salaryPaidThroughMonth': salaryPaidThroughMonth?.toIso8601String(),
      'cardInterestRates': cardInterestRates,
      'convertedPaymentKeys': convertedPaymentKeys.toList(),
      'foldedDebitKeys': foldedDebitKeys.toList(),
      'convertedSourceIds': convertedSourceIds.toList(),
      'trashedPayments': trashedPayments.map((e) => e.toJson()).toList(),
      'deletedSourceIds': deletedSourceIds.toList(),
      'deletedDupKeys': deletedDupKeys.toList(),
      'gmailFirstSyncDone': gmailFirstSyncDone,
      'goalAmount': goalAmount,
      'goalDate': goalDate?.toIso8601String(),
      'budgets': budgets,
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  // CSV（シフトの実績一覧）を書き出す。表計算で見たい人向けの簡易版。
  String exportShiftsCsv() {
    final rows = <String>['日付,勤務先,開始,終了,休憩(分),時給,給与'];
    final keys = shifts.keys.toList()..sort();
    for (final k in keys) {
      for (final s in shifts[k]!) {
        rows.add('$k,${s.workplace},${s.start.toIso8601String()},'
            '${s.end.toIso8601String()},${s.breakMinutes},${s.hourlyWage},${s.earnings}');
      }
    }
    return rows.join('\n');
  }

  // ────── CSVインポート ──────
  // exportShiftsCsv() が書き出した形式のシフトCSVを取り込む。
  // 💡 CSVには交通費・深夜/残業/休日の割増が載らないので、「給与」列から逆算して
  //    復元する（そうしないと取り込んだ月の収入がズレる）。
  CsvImportResult importShiftsCsv(String text, {bool replace = false}) {
    _ensureEditable();
    final lines = const LineSplitter()
        .convert(text.replaceAll('﻿', ''))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const CsvImportResult();

    // ヘッダー列名 → 位置。未知のヘッダーなら書き出し順の固定位置にフォールバック。
    const names = ['日付', '勤務先', '開始', '終了', '休憩(分)', '時給', '給与'];
    final header = _splitCsvLine(lines.first).map((e) => e.trim()).toList();
    final idx = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      idx[header[i]] = i;
    }
    final hasHeader = idx.containsKey('日付') && idx.containsKey('開始');
    for (var i = 0; i < names.length; i++) {
      idx.putIfAbsent(names[i], () => i);
    }

    var failed = 0;
    final parsed = <_CsvShiftRow>[];
    for (final line in lines.skip(hasHeader ? 1 : 0)) {
      final f = _splitCsvLine(line);
      String cell(String name) {
        final i = idx[name]!;
        return i < f.length ? f[i].trim() : '';
      }

      final start = DateTime.tryParse(cell('開始'));
      final end = DateTime.tryParse(cell('終了'));
      final wp = cell('勤務先');
      if (start == null || end == null || wp.isEmpty || !end.isAfter(start)) {
        failed++;
        continue;
      }
      parsed.add(_CsvShiftRow(
        workplace: wp,
        start: start,
        end: end,
        breakMinutes: int.tryParse(cell('休憩(分)')) ?? 0,
        hourlyWage: int.tryParse(cell('時給')) ?? 0,
        earnings: int.tryParse(cell('給与')) ?? 0,
      ));
    }
    if (parsed.isEmpty) return CsvImportResult(failed: failed);

    // 勤務先ごとに交通費・割増を推定
    final byWorkplace = <String, List<_CsvShiftRow>>{};
    for (final r in parsed) {
      byWorkplace.putIfAbsent(r.workplace, () => []).add(r);
    }
    final fits = {
      for (final e in byWorkplace.entries) e.key: _fitWageSettings(e.value)
    };

    if (replace) shifts.clear();

    // 既存シフトの重複判定キー（日付+勤務先+開始+終了）
    String keyOf(String dateKey, ShiftData s) =>
        '$dateKey|${s.workplace}|${s.start.toIso8601String()}|${s.end.toIso8601String()}';
    final existing = <String>{};
    shifts.forEach((k, list) {
      for (final s in list) {
        existing.add(keyOf(k, s));
      }
    });

    var imported = 0, skipped = 0, mismatched = 0;
    for (final r in parsed) {
      final fit = fits[r.workplace]!;
      final s = ShiftData(
        workplace: r.workplace,
        hourlyWage: r.hourlyWage,
        start: r.start,
        end: r.end,
        breakMinutes: r.breakMinutes,
        transportPerDay: fit.transportPerDay,
        nightMultiplier: fit.nightMultiplier,
        overtimeMultiplier: fit.overtimeMultiplier,
        holidayMultiplier: fit.holidayMultiplier,
      );
      final key = dateKey(r.start);
      final k = keyOf(key, s);
      if (existing.contains(k)) {
        skipped++;
        continue;
      }
      existing.add(k);
      shifts.putIfAbsent(key, () => []).add(s);
      imported++;
      if (r.earnings > 0 && s.earnings != r.earnings) mismatched++;
    }

    // 新しい勤務先は推定した給料情報つきで作る（以後の手入力にも効く）
    for (final entry in byWorkplace.entries) {
      if (workplaces.any((w) => w.name == entry.key)) continue;
      final fit = fits[entry.key]!;
      final latest = entry.value.reduce((a, b) => a.start.isAfter(b.start) ? a : b);
      workplaces.add(Workplace(
        id: newWorkplaceId(),
        name: entry.key,
        colorValue:
            workplaceColorPalette[workplaces.length % workplaceColorPalette.length]
                .toARGB32(),
        wagePeriods: [
          WagePeriod(
            hourlyWage: latest.hourlyWage,
            transportPerDay: fit.transportPerDay,
            nightMultiplier: fit.nightMultiplier,
            overtimeMultiplier: fit.overtimeMultiplier,
            holidayMultiplier: fit.holidayMultiplier,
          ),
        ],
      ));
    }

    _migrateWorkplaces(); // workplaceId の紐付け
    saveData();
    notifyListeners();
    return CsvImportResult(
      imported: imported,
      skipped: skipped,
      failed: failed,
      mismatched: mismatched,
    );
  }

  // 💡 給与列に一致するように交通費と各割増を総当たりで推定する。
  //    倍率は 1.00〜2.00 の 0.05 刻み。該当行が無い項目はループごと省くので軽い。
  _WageFit _fitWageSettings(List<_CsvShiftRow> rows) {
    final hasNight = rows.any((r) => r.nightHours > 0);
    final hasOvertime = rows.any((r) => r.hours > 8);
    final hasHoliday = rows.any((r) => r.isWeekend);
    const steps = 21; // 1.00, 1.05, ... 2.00

    _WageFit? best;
    var bestHits = -1, bestSimple = 99, bestTransport = 1 << 30;
    for (var a = 0; a < (hasNight ? steps : 1); a++) {
      final nm = 1.0 + a * 0.05;
      for (var b = 0; b < (hasOvertime ? steps : 1); b++) {
        final om = 1.0 + b * 0.05;
        for (var c = 0; c < (hasHoliday ? steps : 1); c++) {
          final hm = 1.0 + c * 0.05;
          // 残差（= 交通費の候補）の最頻値をとる
          final counts = <int, int>{};
          for (final r in rows) {
            final diff = r.earnings - r.wageWith(nm, om, hm);
            if (diff < 0) continue;
            counts[diff] = (counts[diff] ?? 0) + 1;
          }
          if (counts.isEmpty) continue;
          var tp = 0, hits = 0;
          counts.forEach((k, v) {
            if (v > hits || (v == hits && k < tp)) {
              tp = k;
              hits = v;
            }
          });
          final simple = (nm > 1.0001 ? 1 : 0) +
              (om > 1.0001 ? 1 : 0) +
              (hm > 1.0001 ? 1 : 0);
          // 一致数が多い → 設定が単純 → 交通費が小さい、の順に良いとみなす
          final better = hits > bestHits ||
              (hits == bestHits &&
                  (simple < bestSimple ||
                      (simple == bestSimple && tp < bestTransport)));
          if (!better) continue;
          bestHits = hits;
          bestSimple = simple;
          bestTransport = tp;
          best = _WageFit(
            transportPerDay: tp,
            nightMultiplier: nm,
            overtimeMultiplier: om,
            holidayMultiplier: hm,
          );
        }
      }
    }
    return best ?? const _WageFit();
  }

  // ────── 自動バックアップ ──────
  // 1日1回、アプリのDocumentsディレクトリにJSONを保存。直近7件を保持。
  Future<void> doAutoBackup() async {
    if (kIsWeb) return; // Webはファイル保存できない（設定→書き出しで手動保存）
    if (!autoBackupEnabled) return;
    if (_dataLock != null || uploadsBlocked) return; // ⚠️ 取り込み中・保存が整っていない間は書き出さない
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) await backupDir.create(recursive: true);
      final ts = DateFormat('yyyyMMdd_HHmmss').format(clockNow());
      final file = File('${backupDir.path}/pocket_maid_$ts.json');
      await file.writeAsString(exportJson());
      lastAutoBackupAt = clockNow();
      // 古い7件超えのバックアップを削除
      final files = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (var i = 7; i < files.length; i++) {
        await files[i].delete();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_last_backup_at', lastAutoBackupAt!.toIso8601String());
    } catch (_) {}
  }

  // バックアップファイルの一覧を返す（新しい順）。
  Future<List<File>> listBackupFiles() async {
    if (kIsWeb) return [];
    try {
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory('${dir.path}/backups');
      if (!await backupDir.exists()) return [];
      final files = (await backupDir.list().toList())
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return [];
    }
  }

  // バックアップファイルからリストア。
  Future<void> restoreFromBackup(File file) async {
    final text = await file.readAsString();
    await importJson(text, label: 'バックアップから復元しています');
  }

  Future<void> setAutoBackupEnabled(bool on) async {
    autoBackupEnabled = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('saved_auto_backup_enabled', on);
    notifyListeners();
    if (on) doAutoBackup();
  }

  // エクスポートしたJSONを取り込んで全データを置き換える。
  // 💡 保存が終わるまで待つ（Future）。呼び出し側（ドライブの取り込み・復元）は、
  //   保存まで成功したときだけ「同期済み」「復元しました」にする。
  //   手順:
  //   1) メモリで読み込む（壊れていたらメモリを戻して終わり。端末には何も書かない）
  //   2) 取り込む前の全キーを「復旧点」に書く。⚠️ 書けなければ上書きを始めない（メモリを戻して例外）
  //   3) 取り込んだ状態を保存（一時保存 → 全キー）。成功で一時保存と復旧点を消す
  //   4) 3 が失敗したら、メモリを戻し、復旧点の値で端末も戻す。それも失敗したら「回復待ち」にして、
  //      次の起動で復旧点から戻す（復旧点は消さずに残る）
  //   ⚠️ 取り込みの間は家計データの変更を断る（DataLock）。成功しても失敗しても最後に外す。
  //   [lock]: 呼び出し側が先に鍵を取っているとき（ドライブ: 取得から取り込みまでを 1 つの処理にする）
  Future<void> importJson(String text, {DataLock? lock, String label = 'データを取り込んでいます'}) {
    if (lock != null) {
      if (!identical(lock, _dataLock)) {
        return Future.error(StateError('取り込みの鍵が有効ではありません'));
      }
      return _importJsonLocked(text);
    }
    // 💡 JSON として読めないものは、鍵を取る前に断る（何も変えない・表示も切り替えない）
    try {
      if (jsonDecode(text) is! Map) throw const FormatException('取り込むデータの形が違います');
    } catch (e) {
      return Future.error(e);
    }
    final DataLock own;
    try {
      own = acquireDataLock(label);
    } catch (e) {
      return Future.error(e); // 二重の取り込み → 後から来た方を断る（先の取り込みはそのまま続く）
    }
    // 💡 鍵の取得とメモリでの読み込みは同じ同期区間で行う（間に他の変更が入らない）
    return _importJsonLocked(text).whenComplete(() => releaseDataLock(own));
  }

  Future<void> _importJsonLocked(String text) async {
    final beforeJson = exportJson();
    final beforeValues = _persistedValues(includeUpdatedAt: true);
    try {
      _importJson(text);
    } catch (_) {
      _importJson(beforeJson, repair: false);
      rethrow;
    }
    _lockSnapshot = exportJson();
    // 💡 成功した取り込みも「この端末での編集」には数えない（更新時刻は変えない）
    final afterValues = _persistedValues(includeUpdatedAt: false);
    // ⚠️ 取り込み前に始まっていた保存を終わらせてから復旧点を書く。
    //   走っている保存は成功すると復旧点を消すので、先に書くと「戻す先」が消えて、
    //   取り込みの保存が途中で止まったときに取り込む前の状態へ戻せなくなる。
    //   （書く値はその保存を頼んだ時点のものなので、取り込んだ内容とは混ざらない。
    //    失敗しても、取り込む前の状態は beforeValues として復旧点に入る）
    await _drainWrites();
    final prefs = await SharedPreferences.getInstance();
    try {
      await _putRecord(
          prefs,
          kRestorePointKey,
          jsonEncode({
            'v': 1,
            'before': beforeValues,
            'afterKeys': afterValues.keys.toList(),
            'afterHash': _fingerprint(afterValues),
          }));
    } catch (e) {
      _importJson(beforeJson, repair: false);
      throw StorageWriteFailure('復旧点の保存', e);
    }
    try {
      await saveData(markModified: false);
    } catch (_) {
      final wasUnrecoverable = storageIssue == StorageIssue.unrecoverable;
      _importJson(beforeJson, repair: false);
      try {
        if (wasUnrecoverable) rethrow; // 元が混ざっている可能性 → 書き戻さず、そのまま
        for (final e in beforeValues.entries) {
          await _putValue(prefs, e.key, e.value);
        }
        await _remove(prefs, kPendingWriteKey);
        await _remove(prefs, kRestorePointKey);
        storageIssue = null;
      } catch (_) {
        if (!wasUnrecoverable) storageIssue = StorageIssue.recoveryPending; // 復旧点が残る → 次の起動で戻す
      }
      rethrow;
    }
    storageIssue = null; // 💡 取り込み直し・復元が保存まで成功した＝整った状態になった
    _importSucceededUnderLock = true;
    // 💡 画面への通知は、鍵を外すとき（releaseDataLock）にまとめて行う
  }

  // ════════════════ 取り込み中の変更の停止 ════════════════
  // 💡 取り込みの間（鍵を持っている間）は:
  //   ・画面: 全体を「取り込み中」の表示で覆い、操作できなくする（DataLockOverlay）
  //   ・AppState の変更（追加・削除・残高の入力など）: 始める前に DataLockedException で断る（_ensureEditable）
  //   ・自動の処理（Gmail の反映・カレンダーの記録）: 取り込みが終わるまで待ってから行う（runWhenEditable）
  //   ・ドライブへの保存・自動バックアップ: 行わない（終わったあとの変更通知でまた予約される）
  //   ・二重の取り込み: 後から来た方を断る
  //   ⚠️ 変更を受け付けてから巻き戻すと、入力した内容が黙って消える（GPT 再レビューの残件）。
  DataLock? _dataLock;
  // 💡 取り込みの始まりと終わりで増える。自動の処理は、始めたときの値と比べて「中身が置き換わったか」を知る
  int _dataGeneration = 0;
  String? _lockSnapshot; // 鍵を持っている間の正しい中身（安全網の巻き戻し用）
  bool _importSucceededUnderLock = false;
  Completer<void>? _unlocked;

  /// 取り込み中なら true（画面はこれで全体を覆う）
  bool get dataLocked => _dataLock != null;

  /// いま何をしているか（取り込み中でなければ null）
  String? get dataLockLabel => _dataLock?.label;

  /// 鍵を取る。もう取り込み中なら DataLockedException（二重の取り込みを断る）。
  DataLock acquireDataLock(String label) {
    final held = _dataLock;
    if (held != null) throw DataLockedException(held.label);
    final lock = _dataLock = DataLock._(label);
    _dataGeneration++;
    _lockSnapshot = exportJson();
    _importSucceededUnderLock = false;
    _unlocked = Completer<void>();
    notifyListeners();
    return lock;
  }

  /// 鍵を外す（成功でも失敗でも必ず呼ぶ）。待っていた自動の処理を動かす。
  void releaseDataLock(DataLock lock) {
    if (!identical(lock, _dataLock)) return;
    _dataLock = null;
    _dataGeneration++; // 失敗で巻き戻した場合も、中身の物は作り直されている
    _lockSnapshot = null;
    final waiting = _unlocked;
    _unlocked = null;
    waiting?.complete();
    notifyListeners(); // 💡 ドライブの自動保存・不足の見込みの書き直しは、この通知でまた予約される
    if (_importSucceededUnderLock) {
      _importSucceededUnderLock = false;
      _maybeAutoBackup(); // 取り込みの保存の直後は鍵を持っていて見送ったため
    }
  }

  /// 鍵を持ったまま処理する（ドライブの取り込み: 取得 → 判定 → 取り込み を 1 つの処理にする）
  Future<T> runWithDataLock<T>(String label, Future<T> Function(DataLock lock) body) async {
    final lock = acquireDataLock(label);
    try {
      return await body(lock);
    } finally {
      releaseDataLock(lock);
    }
  }

  /// 自動の処理の変更は、取り込みが終わるまで待ってから行う（断らずに保留する）。
  /// 💡 「取り込み中でない」の確認と変更を同じ同期区間で行う（間に取り込みが始まらない）。
  Future<T> runWhenEditable<T>(T Function() action) async {
    while (_dataLock != null) {
      await _unlocked!.future;
    }
    return action();
  }

  void _ensureEditable() {
    final held = _dataLock;
    if (held != null) throw DataLockedException(held.label);
  }

  // 走っている保存・並んでいる保存が全部終わるまで待つ（失敗は storageIssue に出る）。
  // ⚠️ 鍵を持っている間に呼ぶ（新しい保存が並ばないので、必ず終わる）
  Future<void> _drainWrites() async {
    while (true) {
      final waiting = _queuedDone?.future ?? _runningWrite;
      if (waiting == null) return;
      try {
        await waiting;
      } catch (_) {}
    }
  }

  // [repair]: 取り込んだ後に自己修復するか。⚠️ 失敗時の巻き戻しでは修復しない（元の状態にそのまま戻す）
  void _importJson(String text, {bool repair = true}) {
    final map = jsonDecode(text) as Map<String, dynamic>;

    shifts.clear();
    (map['shifts'] as Map?)?.forEach((k, v) =>
        shifts[k] = (v as List).map((e) => ShiftData.fromJson(e)).toList());

    workplaces
      ..clear()
      ..addAll((map['workplaces'] as List? ?? []).map((e) => Workplace.fromJson(e)));

    actualSalaries.clear();
    (map['actualSalaries'] as Map?)?.forEach((k, v) {
      if (v is int) actualSalaries[k] = v;
    });
    actualSalariesByWp.clear();
    (map['actualSalariesByWp'] as Map?)?.forEach((k, v) {
      if (v is int) actualSalariesByWp[k] = v;
    });
    final buaStr = map['balanceUpdatedAt'] as String?;
    balanceUpdatedAt = (buaStr != null && buaStr.isNotEmpty) ? DateTime.tryParse(buaStr) : null;
    // 💡 旧版の書き出しには無い → null（含まれているか判断できない＝利用者に聞く）
    final beaStr = map['balanceEnteredAt'] as String?;
    balanceEnteredAt = (beaStr != null && beaStr.isNotEmpty) ? DateTime.tryParse(beaStr) : null;
    paymentNotes.clear();
    (map['paymentNotes'] as Map?)?.forEach((k, v) {
      if (v is String) paymentNotes['$k'] = v;
    });
    amazonCardOverrides.clear();
    (map['amazonCardOverrides'] as Map?)?.forEach((k, v) {
      if (v is String) amazonCardOverrides['$k'] = v;
    });
    cardAliases.clear();
    (map['cardAliases'] as Map?)?.forEach((k, v) {
      if (v is String) cardAliases['$k'] = v;
    });
    bankBillMonths.clear();
    (map['bankBillMonths'] as Map?)?.forEach((k, v) {
      if (v is String) bankBillMonths['$k'] = v;
    });
    specialCalendarIds.clear();
    (map['specialCalendarIds'] as Map?)?.forEach((k, v) {
      if (v is String) specialCalendarIds['$k'] = v;
    });
    specialCalendarSigs.clear();
    (map['specialCalendarSigs'] as Map?)?.forEach((k, v) {
      if (v is String) specialCalendarSigs['$k'] = v;
    });
    // 💡 マージだと、別端末で削除したカードが取り込みのたびに復活する。置き換える。
    final cpd = map['cardPaymentDays'] as Map?;
    if (cpd != null) {
      cardPaymentDays.clear();
      cpd.forEach((k, v) {
        if (v is int) cardPaymentDays['$k'] = v;
      });
    }
    cardClosingDays.clear();
    (map['cardClosingDays'] as Map?)?.forEach((k, v) {
      if (v is int) cardClosingDays[k] = v;
    });
    cardIcons.clear();
    (map['cardIcons'] as Map?)?.forEach((k, v) {
      if (v is String && v.isNotEmpty) cardIcons['$k'] = v;
    });

    events.clear();
    (map['events'] as Map?)?.forEach((k, v) =>
        events[k] = (v as List).map((e) => EventData.fromJson(e)).toList());

    todos.clear();
    (map['todos'] as Map?)?.forEach((k, v) =>
        todos[k] = (v as List).map((e) => TodoData.fromJson(e)).toList());

    payments = (map['payments'] as List? ?? []).map((e) => Payment.fromJson(e)).toList();
    installments =
        (map['installments'] as List? ?? []).map((e) => Installment.fromJson(e)).toList();
    subscriptions =
        (map['subscriptions'] as List? ?? []).map((e) => Subscription.fromJson(e)).toList();
    loans = (map['loans'] as List? ?? []).map((e) => Loan.fromJson(e)).toList();
    plannedExpenses = (map['plannedExpenses'] as List? ?? [])
        .map((e) => PlannedExpense.fromJson(e))
        .toList();
    scheduleSuggestions = (map['scheduleSuggestions'] as List? ?? [])
        .map((e) => ScheduleSuggestion.fromJson(e))
        .toList();
    _setMailEntityLinks(map['mailEntityLinks'] as List? ?? const []);
    paidPlannedExpenseKeys
      ..clear()
      ..addAll((map['paidPlannedExpenseKeys'] as List? ?? []).map((e) => '$e'));
    withdrawals =
        (map['withdrawals'] as List? ?? []).map((e) => Withdrawal.fromJson(e)).toList();

    currentBalance = map['currentBalance'] ?? currentBalance;
    walletCash = map['walletCash'] ?? walletCash;
    pendingDeposits = (map['pendingDeposits'] as List? ?? [])
        .map((e) => DepositNotice.fromJson(e))
        .toList();
    _loadTransfers(map['paypayTransfers'], map['receivedTransfers']);
    handledDepositIds
      ..clear()
      ..addAll((map['handledDepositIds'] as List? ?? []).map((e) => e.toString()));
    handledDrawIds
      ..clear()
      ..addAll((map['handledDrawIds'] as List? ?? []).map((e) => e.toString()));
    balanceHistory = (map['balanceHistory'] as List? ?? [])
        .map((e) => BalanceEntry.fromJson(e))
        .toList();
    paidSalaryKeys
      ..clear()
      ..addAll((map['paidSalaryKeys'] as List? ?? []).map((e) => e.toString()));
    plannedIncomes = (map['plannedIncomes'] as List? ?? [])
        .map((e) => PlannedIncome.fromJson(e))
        .toList();
    receivedPlannedKeys
      ..clear()
      ..addAll((map['receivedPlannedKeys'] as List? ?? []).map((e) => e.toString()));
    final sptStr = map['salaryPaidThroughMonth'] as String?;
    salaryPaidThroughMonth =
        (sptStr != null && sptStr.isNotEmpty) ? DateTime.tryParse(sptStr) : null;

    cardInterestRates.clear();
    (map['cardInterestRates'] as Map?)?.forEach((k, v) {
      cardInterestRates[k] = (v as num).toDouble();
    });

    convertedPaymentKeys
      ..clear()
      ..addAll((map['convertedPaymentKeys'] as List? ?? []).map((e) => e.toString()));
    foldedDebitKeys
      ..clear()
      ..addAll((map['foldedDebitKeys'] as List? ?? []).map((e) => e.toString()));
    convertedSourceIds
      ..clear()
      ..addAll((map['convertedSourceIds'] as List? ?? []).map((e) => e.toString()));

    trashedPayments =
        (map['trashedPayments'] as List? ?? []).map((e) => Payment.fromJson(e)).toList();
    deletedSourceIds
      ..clear()
      ..addAll((map['deletedSourceIds'] as List? ?? []).map((e) => e.toString()));
    deletedDupKeys
      ..clear()
      ..addAll((map['deletedDupKeys'] as List? ?? []).map((e) => e.toString()));

    gmailFirstSyncDone = map['gmailFirstSyncDone'] ?? gmailFirstSyncDone;
    goalAmount = map['goalAmount'] ?? 0;
    final gd = map['goalDate'] as String?;
    goalDate = (gd != null && gd.isNotEmpty) ? DateTime.tryParse(gd) : null;

    budgets.clear();
    (map['budgets'] as Map?)?.forEach((k, v) {
      if (v is int) budgets[k] = v;
    });
    if (repair) repairData(); // 起動時と同じ自己修復（B8）。保存は importJson がまとめて行う
  }

  // ════════════════ 保存・読込 ════════════════
  // 💡 保存は「全部そろったときだけ有効」にする（保存キーと JSON の形は以前のまま）。
  //   1) 書く値を同じ瞬間にまとめて作る（途中で状態が変わっても混ざらない）
  //   2) その全部を一時保存（saved_pending_write）に書く。⚠️ 書けなければ既存のキーの上書きを始めない
  //   3) 各キーを書く → 4) 一時保存を消す
  //   途中で失敗・アプリ終了しても、次の起動で一時保存から全キーを書き直す（_recoverInterruptedWrite）。
  //   ⚠️ 以前は各キーを順に書くだけで、途中で失敗し続けると新旧のキーが混ざったまま残った
  //     （docs/prepublish-review-plan.md §3）。
  static const String kPendingWriteKey = 'saved_pending_write';
  // 💡 取り込み（ドライブ・バックアップ・貼り付け）の前の状態。取り込みの保存が終わる前に止まったら、
  //   次の起動でこの状態に戻す（取り込みは「失敗」と伝えているので、その前の状態が正しい）。
  static const String kRestorePointKey = 'saved_restore_point';

  // 💡 保存の状態（null＝正常）。正常でない間は、ドライブへの保存・自動バックアップを止める（uploadsBlocked）。
  StorageIssue? storageIssue;
  // 前回の保存が途中で止まっていて、起動時に整った状態へ戻したか（ホームで一度知らせる）
  bool recoveredOnStartup = false;

  // 💡 容量が足りないときに、作り直せるもの（Gmail の解析キャッシュなど）を消す。main.dart から渡す。
  //   ⚠️ 補助策。空きができる保証は無いので、これに頼らず「書けなければ上書きしない」で守る。
  Future<void> Function()? freeStorageSpace;

  /// 保存データが整っていない可能性がある間は、正常なコピー（ドライブ・バックアップ）を上書きしない
  bool get uploadsBlocked =>
      storageIssue == StorageIssue.recoveryPending || storageIssue == StorageIssue.unrecoverable;

  // 保存する全キーと値（この瞬間の状態）。キー・型は以前の saveData と同じ。
  Map<String, Object> _persistedValues({required bool includeUpdatedAt}) => {
        if (includeUpdatedAt && dataUpdatedAt != null)
          'saved_data_updated_at': dataUpdatedAt!.toIso8601String(),
      'saved_shifts': jsonEncode(shifts),
      'saved_payment_notes': jsonEncode(paymentNotes),
      'saved_amazon_overrides': jsonEncode(amazonCardOverrides),
      'saved_card_aliases': jsonEncode(cardAliases),
      'saved_bank_bill_months': jsonEncode(bankBillMonths),
      'saved_special_calendar_ids': jsonEncode(specialCalendarIds),
      'saved_special_calendar_sigs': jsonEncode(specialCalendarSigs),
      'saved_actual_salaries': jsonEncode(actualSalaries),
      'saved_actual_salaries_by_wp': jsonEncode(actualSalariesByWp),
      'saved_balance_updated_at': balanceUpdatedAt?.toIso8601String() ?? '',
      'saved_balance_entered_at': balanceEnteredAt?.toIso8601String() ?? '',
      'saved_goal_amount': goalAmount,
      'saved_goal_date': goalDate?.toIso8601String() ?? '',
      'saved_budgets': jsonEncode(budgets),
      'saved_workplaces': jsonEncode(workplaces.map((e) => e.toJson()).toList()),
      'saved_events': jsonEncode(events),
      'saved_todos': jsonEncode(todos.map( (k, v) => MapEntry(k, v.map((t) => t.toJson()).toList()))),
      'saved_payments': jsonEncode(payments.map((e) => e.toJson()).toList()),
      'saved_installments': jsonEncode(installments.map((e) => e.toJson()).toList()),
      'saved_subscriptions': jsonEncode(subscriptions.map((e) => e.toJson()).toList()),
      'saved_loans': jsonEncode(loans.map((e) => e.toJson()).toList()),
      'saved_planned_expenses': jsonEncode(plannedExpenses.map((e) => e.toJson()).toList()),
      'saved_schedule_suggestions': jsonEncode(scheduleSuggestions.map((e) => e.toJson()).toList()),
      'saved_mail_entity_links': jsonEncode(mailEntityLinks.values.map((e) => e.toJson()).toList()),
      'saved_paid_planned_expenses': paidPlannedExpenseKeys.toList(),
      'saved_withdrawals': jsonEncode(withdrawals.map((e) => e.toJson()).toList()),
      'saved_balance': currentBalance,
      'saved_wallet_cash': walletCash,
      'saved_pending_deposits': jsonEncode(pendingDeposits.map((e) => e.toJson()).toList()),
      'saved_handled_deposit_ids': handledDepositIds.toList(),
      'saved_paypay_transfers': jsonEncode(paypayTransfers.map((e) => e.toJson()).toList()),
      'saved_received_transfers': jsonEncode(receivedTransfers),
      'saved_handled_draw_ids': handledDrawIds.toList(),
      'saved_balance_history': jsonEncode(balanceHistory.map((e) => e.toJson()).toList()),
      'saved_paid_salary_keys': paidSalaryKeys.toList(),
      'saved_planned_incomes': jsonEncode(plannedIncomes.map((e) => e.toJson()).toList()),
      'saved_received_planned_keys': receivedPlannedKeys.toList(),
      'saved_salary_paid_through': salaryPaidThroughMonth?.toIso8601String() ?? '',
      'saved_card_rates': jsonEncode(cardInterestRates),
      'saved_converted_keys': convertedPaymentKeys.toList(),
      'saved_folded_debit_keys': foldedDebitKeys.toList(),
      'saved_converted_source_ids': convertedSourceIds.toList(),
      'saved_trashed_payments': jsonEncode(trashedPayments.map((e) => e.toJson()).toList()),
      'saved_deleted_source_ids': deletedSourceIds.toList(),
      'saved_deleted_dup_keys': deletedDupKeys.toList(),
      'saved_calendar_autosync': calendarAutoSync,
      'saved_first_sync': gmailFirstSyncDone,
        // ⚠️ カードの引落日・締め日も毎回書く（B1）。空でもキーを書く（無いと初回起動とみなされる）
        'saved_card_payment_days': jsonEncode(cardPaymentDays),
        'saved_card_closing_days': jsonEncode(cardClosingDays),
        'saved_card_icons': jsonEncode(cardIcons),
      };

  // ⚠️ SharedPreferences の保存・削除は、失敗を例外ではなく false で返すことがある（API の約束）。
  //   false を見落とすと、復旧点を書けていないのに上書きを始めたり、保存できていないのに成功扱いにしたりする
  //   （GPT 実装レビュー P2）。保存・削除はすべてここを通し、false は例外にする。
  static Future<void> _checked(Future<bool> op, String what) async {
    if (!await op) throw StateError('保存先が失敗を返しました: $what');
  }

  static Future<void> _remove(SharedPreferences prefs, String key) =>
      _checked(prefs.remove(key), '$key の削除');

  static Future<void> _putValue(SharedPreferences prefs, String key, Object value) {
    if (value is int) return _checked(prefs.setInt(key, value), key);
    if (value is bool) return _checked(prefs.setBool(key, value), key);
    if (value is List) {
      return _checked(prefs.setStringList(key, [for (final e in value) '$e']), key);
    }
    return _checked(prefs.setString(key, value as String), key);
  }

  // 1つのキーに全部を書く（一時保存・復旧点）。書けなければ空きを作って一度だけやり直す。
  Future<void> _putRecord(SharedPreferences prefs, String key, String json) async {
    try {
      await _checked(prefs.setString(key, json), key);
    } catch (_) {
      final free = freeStorageSpace;
      if (free == null) rethrow;
      try {
        await free();
      } catch (_) {}
      await _checked(prefs.setString(key, json), key);
    }
  }

  // 一時保存 → 全キー → 一時保存を消す。成功したら、残っていた復旧点も消す（端末の保存＝いまの状態になったため）。
  Future<void> _writeValues(Map<String, Object> values) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await _putRecord(prefs, kPendingWriteKey, jsonEncode({'v': 1, 'values': values}));
    } catch (e) {
      throw StorageWriteFailure('一時保存', e); // ⚠️ 既存のキーは何も書き換えていない
    }
    try {
      for (final e in values.entries) {
        await _putValue(prefs, e.key, e.value);
      }
      await _remove(prefs, kPendingWriteKey);
      await _remove(prefs, kRestorePointKey);
    } catch (e) {
      throw StorageWriteFailure('保存', e); // 一時保存が残るので、次の起動で書き直せる
    }
  }

  // 💡 保存は1つずつ順に行い、待っている間に頼まれた分は1回にまとめる（書く値は新しい方）。
  Map<String, Object>? _queuedValues;
  Completer<void>? _queuedDone;
  Future<void>? _runningWrite;

  Future<void> _enqueueWrite(Map<String, Object> values) {
    final queued = _queuedValues;
    if (queued != null) {
      _queuedValues = {...queued, ...values};
      return _queuedDone!.future;
    }
    _queuedValues = values;
    final done = _queuedDone = Completer<void>();
    () async {
      while (_runningWrite != null) {
        try {
          await _runningWrite;
        } catch (_) {}
      }
      final v = _queuedValues!;
      _queuedValues = null;
      _queuedDone = null;
      final f = _writeValues(v);
      _runningWrite = f;
      Object? error;
      StackTrace? stack;
      try {
        await f;
        _onWriteSucceeded();
      } catch (e, st) {
        _onWriteFailed();
        error = e;
        stack = st;
      } finally {
        if (identical(_runningWrite, f)) _runningWrite = null;
      }
      // 💡 書いている間に頼まれた保存（後ろに並んだもの）が終わるまで待ってから完了にする。
      //   「保存した」と返った時点で、それまでの変更がすべて端末に入っているようにするため。
      final next = _queuedDone?.future;
      if (next != null) {
        try {
          await next;
        } catch (_) {} // 後ろの保存の失敗は、その保存を頼んだ側と storageIssue に出る
      }
      if (error != null) {
        done.completeError(error, stack);
      } else {
        done.complete();
      }
    }();
    return done.future;
  }

  void _onWriteSucceeded() {
    // ⚠️ 回復不能（混ざっている可能性）は、ふつうの保存が成功しても解消しない。
    //   取り込み直し・復元（importJson の成功）でだけ解消する。
    if (storageIssue != null && storageIssue != StorageIssue.unrecoverable) {
      storageIssue = null;
      notifyListeners();
    }
  }

  void _onWriteFailed() {
    // 回復待ち・回復不能のときはそのまま（保存の失敗より重い状態）
    if (storageIssue == null) {
      storageIssue = StorageIssue.saveFailed;
      notifyListeners();
    }
  }

  // 💡 変更時刻・同期の基準時刻は、時計が同じ値を返しても必ず増える値にする。
  //   ⚠️ 取り込みを始めた時刻と、その後の編集の時刻が同じだと、編集が「同期済み」に紛れる（GPT 実装レビュー P1）。
  DateTime? _lastStamp;
  DateTime issueStamp() {
    var t = clockNow();
    final last = _lastStamp;
    if (last != null && !t.isAfter(last)) t = last.add(const Duration(microseconds: 1));
    _lastStamp = t;
    return t;
  }

  Future<void> saveData({bool markModified = true}) {
    if (markModified && _dataLock != null) {
      // ⚠️ 安全網: 取り込み中に、断る確認（_ensureEditable）を通らずに書き換えた経路がある。
      //   その変更は保存せず、取り込み中の正しい中身へ戻して断る（取り込みの保存に混ぜない）。
      //   ここに来るのは不具合なので、見つけたら書き換える側に _ensureEditable / runWhenEditable を足す。
      final label = _dataLock!.label;
      final snap = _lockSnapshot;
      if (snap != null) {
        _importJson(snap, repair: false);
        notifyListeners();
      }
      final f = Future<void>.error(DataLockedException(label));
      f.catchError((_) {});
      return f;
    }
    if (markModified) dataUpdatedAt = issueStamp();
    final f = _enqueueWrite(_persistedValues(includeUpdatedAt: markModified));
    // ⚠️ 呼び出し側の多くは待たない。失敗は storageIssue で画面に出すので、未処理の例外にしない
    //   （待っている呼び出し側には、そのまま例外が届く）。
    f.catchError((_) {});
    f.then((_) => _maybeAutoBackup(), onError: (_) {});
    return f;
  }

  /// 保存をやり直す（保存に失敗・回復待ちのとき、画面のボタンから）。成功したら true。
  Future<bool> retryStorage() async {
    if (_dataLock != null) return false; // 取り込み中は取り込みの保存を待つ
    try {
      await saveData(markModified: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _maybeAutoBackup() {
    // ⚠️ 取り込み中は書き出さない（保存が終わる前の中身をバックアップにしない）。終わったら releaseDataLock から呼ぶ
    if (_dataLock != null) return;
    if (uploadsBlocked) return; // ⚠️ 整っていない状態で、正常なバックアップを押し出さない
    // 自動バックアップ（1日1回）
    final now = clockNow();
    if (autoBackupEnabled &&
        (lastAutoBackupAt == null ||
            lastAutoBackupAt!.year != now.year ||
            lastAutoBackupAt!.month != now.month ||
            lastAutoBackupAt!.day != now.day)) {
      doAutoBackup();
    }
  }

  Future<void> loadData() async {
    try {
      await _loadDataInner();
    } finally {
      // ⚠️ 読み込みの途中で例外が出ても「読み終えた」にする。
      //   そうしないとホームがずっと読み込み中のまま止まり、起動時の同期も始まらない。
      isLoaded = true;
      if (!_loaded.isCompleted) _loaded.complete();
      notifyListeners();
    }
  }

  static Map<String, Object> _decodeValues(Object? raw) {
    final m = (raw as Map).cast<String, Object?>();
    return {
      for (final e in m.entries)
        if (e.value != null) e.key: e.value is List ? [for (final x in e.value as List) '$x'] : e.value!,
    };
  }

  static String _fingerprint(Map<String, Object> values) =>
      sha256.convert(utf8.encode(jsonEncode(values))).toString();

  // 今の端末の保存から、指定したキーの値を読み直す（復旧点の照合用）
  static Map<String, Object> _currentValues(SharedPreferences prefs, Iterable<String> keys) => {
        for (final k in keys)
          if (prefs.get(k) != null) k: prefs.get(k) is List ? [for (final x in prefs.get(k) as List) '$x'] : prefs.get(k)!,
      };

  // 💡 起動時に、途中で止まった保存・取り込みを整った状態へ戻す。
  //   ・復旧点があり、取り込み後の保存が最後まで終わっていない → 取り込む前の状態へ戻す
  //   ・復旧点があるが、端末の保存が取り込み後の状態と一致 → 取り込みは終わっていた（記録を消すだけ）
  //   ・一時保存だけがある → その状態（最後に保存しようとした状態）を書き直す
  //   書き戻せなかったら、記録を残したまま「回復待ち」にし、記録の値で読む（戻り値）。
  Future<Map<String, Object>?> _recoverInterruptedWrite(SharedPreferences prefs) async {
    final rpRaw = prefs.getString(kRestorePointKey);
    final walRaw = prefs.getString(kPendingWriteKey);
    if (rpRaw == null && walRaw == null) return null;
    Map<String, Object> target;
    try {
      if (rpRaw != null) {
        final rp = jsonDecode(rpRaw) as Map<String, dynamic>;
        final afterKeys = [for (final k in (rp['afterKeys'] as List)) '$k'];
        final done = walRaw == null &&
            _fingerprint(_currentValues(prefs, afterKeys)) == rp['afterHash'];
        if (done) {
          await _remove(prefs, kRestorePointKey);
          return null;
        }
        target = _decodeValues(rp['before']);
      } else {
        target = _decodeValues((jsonDecode(walRaw!) as Map<String, dynamic>)['values']);
      }
    } catch (_) {
      // ⚠️ 記録が壊れている。端末の保存は混ざっている可能性がある（正常なデータとして扱わない）
      storageIssue = StorageIssue.unrecoverable;
      return null;
    }
    try {
      for (final e in target.entries) {
        await _putValue(prefs, e.key, e.value);
      }
      await _remove(prefs, kPendingWriteKey);
      await _remove(prefs, kRestorePointKey);
      recoveredOnStartup = true;
      return null;
    } catch (_) {
      storageIssue = StorageIssue.recoveryPending;
      return target;
    }
  }

  Future<void> _loadDataInner() async {
    final prefs = await SharedPreferences.getInstance();
    // 💡 前回の保存・取り込みが途中で止まっていたら、まず整った状態へ戻す
    final pv = _PrefsView(prefs, await _recoverInterruptedWrite(prefs));

    final shiftsStr = pv.getString('saved_shifts');
    if (shiftsStr != null) {
      (jsonDecode(shiftsStr) as Map<String, dynamic>).forEach((k, v) {
        shifts[k] = (v as List).map((e) => ShiftData.fromJson(e)).toList();
      });
    }

    final actualSalStr = pv.getString('saved_actual_salaries');
    if (actualSalStr != null) {
      (jsonDecode(actualSalStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) actualSalaries[k] = v;
      });
    }
    final actualSalWpStr = pv.getString('saved_actual_salaries_by_wp');
    if (actualSalWpStr != null) {
      (jsonDecode(actualSalWpStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) actualSalariesByWp[k] = v;
      });
    }
    final buaStr = pv.getString('saved_balance_updated_at');
    balanceUpdatedAt = (buaStr != null && buaStr.isNotEmpty) ? DateTime.tryParse(buaStr) : null;
    final beaStr = pv.getString('saved_balance_entered_at');
    balanceEnteredAt = (beaStr != null && beaStr.isNotEmpty) ? DateTime.tryParse(beaStr) : null;
    goalAmount = pv.getInt('saved_goal_amount') ?? 0;
    final goalStr = pv.getString('saved_goal_date');
    goalDate = (goalStr != null && goalStr.isNotEmpty) ? DateTime.tryParse(goalStr) : null;
    final budgetsStr = pv.getString('saved_budgets');
    if (budgetsStr != null) {
      (jsonDecode(budgetsStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) budgets[k] = v;
      });
    }

    final workplacesStr = pv.getString('saved_workplaces');
    if (workplacesStr != null) {
      workplaces
        ..clear()
        ..addAll((jsonDecode(workplacesStr) as List)
            .map((e) => Workplace.fromJson(e)));
    }

    final eventsStr = pv.getString('saved_events');
    if (eventsStr != null) {
      (jsonDecode(eventsStr) as Map<String, dynamic>).forEach((k, v) {
        events[k] = (v as List).map((e) => EventData.fromJson(e)).toList();
      });
    }

    final todosStr = pv.getString('saved_todos');
    if (todosStr != null) {
      (jsonDecode(todosStr) as Map<String, dynamic>).forEach((k, v) {
        todos[k] = (v as List).map((e) => TodoData.fromJson(e)).toList();
      });
    }

    final paymentsStr = pv.getString('saved_payments');
    if (paymentsStr != null) {
      payments = (jsonDecode(paymentsStr) as List)
          .map((e) => Payment.fromJson(e))
          .toList();
      // 旧データの重複IDを振り直し（Keyの衝突・巻き込み削除を防ぐ）
      final seen = <String>{};
      var dedupped = false;
      for (final p in payments) {
        if (!seen.add(p.id)) {
          p.id = _id();
          dedupped = true;
        }
      }
      if (dedupped) saveData();
    }

    final installStr = pv.getString('saved_installments');
    if (installStr != null) {
      installments = (jsonDecode(installStr) as List)
          .map((e) => Installment.fromJson(e))
          .toList();
    }

    final subsStr = pv.getString('saved_subscriptions');
    if (subsStr != null) {
      subscriptions = (jsonDecode(subsStr) as List)
          .map((e) => Subscription.fromJson(e))
          .toList();
    }

    final loanStr = pv.getString('saved_loans');
    if (loanStr != null) {
      loans = (jsonDecode(loanStr) as List).map((e) => Loan.fromJson(e)).toList();
    }

    final peStr = pv.getString('saved_planned_expenses');
    if (peStr != null) {
      plannedExpenses = (jsonDecode(peStr) as List)
          .map((e) => PlannedExpense.fromJson(e))
          .toList();
    }
    final sgStr = pv.getString('saved_schedule_suggestions');
    if (sgStr != null) {
      scheduleSuggestions = (jsonDecode(sgStr) as List)
          .map((e) => ScheduleSuggestion.fromJson(e))
          .toList();
    }
    final mlStr = pv.getString('saved_mail_entity_links');
    if (mlStr != null) _setMailEntityLinks(jsonDecode(mlStr) as List);
    paidPlannedExpenseKeys
      ..clear()
      ..addAll(pv.getStringList('saved_paid_planned_expenses') ?? []);

    final wdStr = pv.getString('saved_withdrawals');
    if (wdStr != null) {
      withdrawals = (jsonDecode(wdStr) as List)
          .map((e) => Withdrawal.fromJson(e))
          .toList();
    }

    currentBalance = pv.getInt('saved_balance') ?? 0;
    walletCash = pv.getInt('saved_wallet_cash') ?? 0;
    final ptStr = pv.getString('saved_paypay_transfers');
    final rtStr = pv.getString('saved_received_transfers');
    _loadTransfers(ptStr == null ? null : jsonDecode(ptStr),
        rtStr == null ? null : jsonDecode(rtStr));
    final pdStr = pv.getString('saved_pending_deposits');
    if (pdStr != null) {
      pendingDeposits =
          (jsonDecode(pdStr) as List).map((e) => DepositNotice.fromJson(e)).toList();
    }
    handledDepositIds
      ..clear()
      ..addAll(pv.getStringList('saved_handled_deposit_ids') ?? const []);
    handledDrawIds
      ..clear()
      ..addAll(pv.getStringList('saved_handled_draw_ids') ?? const []);
    final histStr = pv.getString('saved_balance_history');
    if (histStr != null) {
      balanceHistory =
          (jsonDecode(histStr) as List).map((e) => BalanceEntry.fromJson(e)).toList();
    }
    paidSalaryKeys
      ..clear()
      ..addAll(pv.getStringList('saved_paid_salary_keys') ?? const []);
    final planStr = pv.getString('saved_planned_incomes');
    if (planStr != null) {
      plannedIncomes =
          (jsonDecode(planStr) as List).map((e) => PlannedIncome.fromJson(e)).toList();
    }
    receivedPlannedKeys
      ..clear()
      ..addAll(pv.getStringList('saved_received_planned_keys') ?? const []);
    final sptStr = pv.getString('saved_salary_paid_through');
    salaryPaidThroughMonth =
        (sptStr != null && sptStr.isNotEmpty) ? DateTime.tryParse(sptStr) : null;
    // 💡 一度だけの移行: 2026年8月までの給料は受け取り済みとして扱う
    //   （既存ユーザーは8月分まで入金済みのため、9月分から選択肢に出す）
    if (!(pv.getBool('migrated_salary_paid_through_202608') ?? false)) {
      salaryPaidThroughMonth ??= DateTime(2026, 8);
      await prefs.setString(
          'saved_salary_paid_through', salaryPaidThroughMonth!.toIso8601String());
      await prefs.setBool('migrated_salary_paid_through_202608', true);
    }

    final ratesStr = pv.getString('saved_card_rates');
    if (ratesStr != null) {
      (jsonDecode(ratesStr) as Map<String, dynamic>).forEach((k, v) {
        cardInterestRates[k] = (v as num).toDouble();
      });
    }
    convertedPaymentKeys
      ..clear()
      ..addAll(pv.getStringList('saved_converted_keys') ?? const []);
    foldedDebitKeys
      ..clear()
      ..addAll(pv.getStringList('saved_folded_debit_keys') ?? const []);
    convertedSourceIds
      ..clear()
      ..addAll(pv.getStringList('saved_converted_source_ids') ?? const []);

    final trashStr = pv.getString('saved_trashed_payments');
    if (trashStr != null) {
      trashedPayments =
          (jsonDecode(trashStr) as List).map((e) => Payment.fromJson(e)).toList();
    }
    deletedSourceIds
      ..clear()
      ..addAll(pv.getStringList('saved_deleted_source_ids') ?? const []);
    deletedDupKeys
      ..clear()
      ..addAll(pv.getStringList('saved_deleted_dup_keys') ?? const []);
    calendarAutoSync = pv.getBool('saved_calendar_autosync') ?? false;
    final reminderIdx = pv.getInt('saved_shift_reminder');
    shiftReminder = reminderIdx != null &&
            reminderIdx >= 0 &&
            reminderIdx < ShiftReminder.values.length
        ? ShiftReminder.values[reminderIdx]
        : ShiftReminder.calendarDefault;
    shortfallAlerts = pv.getBool('saved_shortfall_alerts') ?? true;
    autoBackupEnabled = pv.getBool('saved_auto_backup_enabled') ?? true;
    showMonthAfterNext = pv.getBool('saved_show_month_after_next') ?? true;
    showWalletCash = pv.getBool('saved_show_wallet_cash') ?? true;
    backgroundTheme = pv.getString('saved_background_theme') ?? 'pink';
    final cpdStr = pv.getString('saved_card_payment_days');
    if (cpdStr == null) {
      // 初回起動：種をデータとして書き込む（以後はここを通らない）
      cardPaymentDays = Map<String, int>.from(kSeedCardPaymentDays);
      await prefs.setString('saved_card_payment_days', jsonEncode(cardPaymentDays));
    } else {
      // 保存済みの内容で「置き換える」。消したカードが復活しないように。
      cardPaymentDays
        ..clear()
        ..addAll({
          for (final e in (jsonDecode(cpdStr) as Map<String, dynamic>).entries)
            if (e.value is int) e.key: e.value as int
        });
    }
    final bbmStr = pv.getString('saved_bank_bill_months');
    if (bbmStr != null) {
      (jsonDecode(bbmStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) bankBillMonths[k] = v;
      });
    }
    final caStr = pv.getString('saved_card_aliases');
    if (caStr != null) {
      (jsonDecode(caStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) cardAliases[k] = v;
      });
    }
    for (final (key, target) in [
      ('saved_special_calendar_ids', specialCalendarIds),
      ('saved_special_calendar_sigs', specialCalendarSigs),
    ]) {
      final s = pv.getString(key);
      if (s == null) continue;
      (jsonDecode(s) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) target[k] = v;
      });
    }
    final aoStr = pv.getString('saved_amazon_overrides');
    if (aoStr != null) {
      (jsonDecode(aoStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) amazonCardOverrides[k] = v;
      });
    }
    final pnStr = pv.getString('saved_payment_notes');
    if (pnStr != null) {
      (jsonDecode(pnStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String) paymentNotes[k] = v;
      });
    }
    final iconStr = pv.getString('saved_card_icons');
    if (iconStr != null) {
      (jsonDecode(iconStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is String && v.isNotEmpty) cardIcons[k] = v;
      });
    }
    final ccdStr = pv.getString('saved_card_closing_days');
    if (ccdStr != null) {
      (jsonDecode(ccdStr) as Map<String, dynamic>).forEach((k, v) {
        if (v is int) cardClosingDays[k] = v;
      });
    }
    final lbaStr = pv.getString('saved_last_backup_at');
    if (lbaStr != null && lbaStr.isNotEmpty) lastAutoBackupAt = DateTime.tryParse(lbaStr);

    gmailFirstSyncDone = pv.getBool('saved_first_sync') ?? false;

    driveSyncEnabled = pv.getBool('saved_drive_sync_enabled') ?? false;
    requireGoogleLogin = pv.getBool('saved_require_google_login') ?? false;
    DateTime? readAt(String key) {
      final s = pv.getString(key);
      return (s == null || s.isEmpty) ? null : DateTime.tryParse(s);
    }

    dataUpdatedAt = readAt('saved_data_updated_at');
    driveSyncedAt = readAt('saved_drive_synced_at');
    driveKnownRemoteAt = readAt('saved_drive_remote_at');

    var migrated = repairData();
    // 💡 IDの無い旧シフトに採番したIDを保存する（次の起動で別のIDにならないように）
    //   ⚠️ legacyId は読み込んだ時点の印なので、起動時だけ見る（repairData に入れると冪等でなくなる）
    if (shifts.values.any((l) => l.any((s) => s.legacyId))) migrated = true;
    if (migrated) saveData();

    notifyListeners();
  }

  // 💡 自己修復（古いデータの形をいまの形にそろえる）。起動時の読込と、取り込み（ドライブ・
  //   バックアップ）の両方でここを通す。⚠️ 以前は取り込み時にローンの紐づけしか直しておらず、
  //   古い端末が上げたデータは次の起動まで直らないまま計算されていた（B8）。
  //   ・何度走らせても結果が同じ（2回目は何も変えず false を返す）
  //   ・失った情報を推測で作らない（例: 消えた予定のIDは戻さない）
  //   戻り値: 何か直したら true（呼び出し側が保存する）
  @visibleForTesting
  bool repairData() {
    // 💡 「三井住友」は「三井OLIVE」に統合
    var changed = retireOldScheduleSuggestions() > 0;
    if (_removeSampleSuggestions() > 0) changed = true; // 削除した「見本の提案」の残り
    for (final p in payments) {
      if (p.cardName == '三井住友') {
        p.cardName = '三井OLIVE';
        changed = true;
      }
    }
    for (final i in installments) {
      if (i.cardName == '三井住友') {
        i.cardName = '三井OLIVE';
        changed = true;
      }
      // 旧データ: startDate が無ければ名前内の日付 "(2026-03-11)" から復元
      if (i.startDate == null) {
        final m = RegExp(r'(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(i.name);
        if (m != null) {
          i.startDate =
              DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
          changed = true;
        }
      }
    }
    if (_migrateWorkplaces()) changed = true;
    // 分割へ移した決済がカード側に残っていたら掃除（旧バージョンの取りこぼしを自己修復）
    if (cleanupInstallmentDuplicates() > 0) changed = true;
    if (repairLoanBillingLinks()) changed = true;
    return changed;
  }

  // 💡 既存の手入力シフト（workplace文字列）から勤務先マスタを自動生成し、
  //    各シフトに workplaceId を紐付ける。戻り値: 変更があれば true。
  bool _migrateWorkplaces() {
    var changed = false;
    // 既存の勤務先名→id
    final byName = <String, Workplace>{for (final w in workplaces) w.name: w};

    // シフトに登場する勤務先名と「最新シフトの時給」を集める
    final latestWageByName = <String, ({DateTime date, int wage})>{};
    shifts.forEach((dateKey, list) {
      final d = DateTime.tryParse(dateKey);
      for (final s in list) {
        final name = s.workplace.trim();
        if (name.isEmpty) continue;
        if (d != null) {
          final cur = latestWageByName[name];
          if (cur == null || d.isAfter(cur.date)) {
            latestWageByName[name] = (date: d, wage: s.hourlyWage);
          }
        }
        latestWageByName.putIfAbsent(name, () => (date: DateTime(2000), wage: s.hourlyWage));
      }
    });

    // 未登録の勤務先を生成
    for (final entry in latestWageByName.entries) {
      if (byName.containsKey(entry.key)) continue;
      final color = workplaceColorPalette[
          workplaces.length % workplaceColorPalette.length];
      final w = Workplace(
        id: newWorkplaceId(),
        name: entry.key,
        colorValue: color.toARGB32(),
        wagePeriods: [WagePeriod(hourlyWage: entry.value.wage)],
      );
      workplaces.add(w);
      byName[entry.key] = w;
      changed = true;
    }

    // シフトに workplaceId を紐付け（未設定のものだけ）
    shifts.forEach((dateKey, list) {
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        if (s.workplaceId != null) continue;
        final w = byName[s.workplace.trim()];
        if (w == null) continue;
        // ⚠️ ID と予定のIDを引き継ぐ。以前は作り直しで新しいIDになり、予定IDも消えていた
        //   （カレンダーに同じ予定が二重にでき、メールの予定提案との対応も外れる＝B2）。
        list[i] = ShiftData(
          id: s.id,
          legacyId: s.legacyId,
          calendarEventId: s.calendarEventId,
          workplace: s.workplace,
          workplaceId: w.id,
          hourlyWage: s.hourlyWage,
          start: s.start,
          end: s.end,
          breakMinutes: s.breakMinutes,
          transportPerDay: s.transportPerDay,
          transportMonthlyCap: s.transportMonthlyCap,
          nightMultiplier: s.nightMultiplier,
          overtimeMultiplier: s.overtimeMultiplier,
          holidayMultiplier: s.holidayMultiplier,
        );
        changed = true;
      }
    });

    return changed;
  }
}
