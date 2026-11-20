// 💡 お金のデータ型（明細・分割・ローン・定期・予定の入出金・残高の記録）。
//   保存の JSON の形を変えないこと（既存データとドライブ同期の互換）。
//   ⚠️ ここから AppState を参照しない（依存は AppState → models の一方向）。

// 支払いの出所: 手動 / 利用通知 / カード請求予定 / 銀行引落確定
enum PaymentSource { manual, usage, billing, bank }

// ───────────────────────── カード支払い ─────────────────────────
class Payment {
  String id;
  String cardName;
  int amount;
  DateTime paymentDate;
  bool paid;
  PaymentSource source;
  String sourceId; // メール由来の一意キー（自動取り込みの識別用）
  DateTime? mailReceivedAt; // 💡 検索範囲の判定用。旧データは再取得できたときに補完する
  String note; // 利用先（店舗名）など
  // 💡 「記録として残すが、金額は合計に足さない」明細。
  //   同じ買い物がカード会社の通知からも入ってきたときだけ立てる。
  bool infoOnly;

  Payment({
    required this.id,
    required this.cardName,
    required this.amount,
    required this.paymentDate,
    this.paid = false,
    this.source = PaymentSource.manual,
    this.sourceId = '',
    this.mailReceivedAt,
    this.note = '',
    this.infoOnly = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'cardName': cardName,
        'amount': amount,
        'paymentDate': paymentDate.toIso8601String(),
        'paid': paid,
        'source': source.index,
        'sourceId': sourceId,
        if (mailReceivedAt != null) 'mailReceivedAt': mailReceivedAt!.toIso8601String(),
        'note': note,
        'infoOnly': infoOnly,
      };

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
        id: json['id'],
        cardName: json['cardName'],
        amount: json['amount'],
        paymentDate: DateTime.parse(json['paymentDate']),
        paid: json['paid'] ?? false,
        source: PaymentSource.values[json['source'] ?? 0],
        sourceId: json['sourceId'] ?? '',
        mailReceivedAt: DateTime.tryParse(json['mailReceivedAt'] as String? ?? ''),
        note: json['note'] ?? '',
        infoOnly: json['infoOnly'] ?? false,
      );
}

// ───────────────────────── 分割払い ─────────────────────────
class Installment {
  final String id;
  String name;
  String cardName; // 紐づくクレカ
  int totalAmount; // 元金
  int installmentCount;
  int remainingMonths;
  int monthlyAmount; // 金利込みの月額
  double interestRate; // 年率(%)
  DateTime? startDate; // 利用日（残回数の自動計算に使用）

  Installment({
    required this.id,
    required this.name,
    this.cardName = '',
    required this.totalAmount,
    required this.installmentCount,
    required this.remainingMonths,
    required this.monthlyAmount,
    this.interestRate = 0,
    this.startDate,
  });

  // 手数料込みの総支払額
  int get totalWithInterest => monthlyAmount * installmentCount;

  // 💡 その月が何回目か（1始まり）。期間外・開始日の無い旧データは0。
  //   1回目＝利用開始月。そこから installmentCount か月ぶん。
  //   ⚠️ 以前は同じ式が AppState に5か所あった。ここ1か所で決める。
  int countIn(DateTime month) {
    final start = startDate;
    if (start == null) return 0;
    final diff = (month.year - start.year) * 12 + (month.month - start.month);
    if (diff < 0 || diff >= installmentCount) return 0;
    return diff + 1;
  }

  // 💡 その月に計上する額。開始日の無い旧データは、残りがあれば「今月」だけ計上する。
  int amountIn(DateTime month, {required DateTime now}) {
    if (startDate == null) {
      final thisMonth = month.year == now.year && month.month == now.month;
      return remainingMonths > 0 && thisMonth ? monthlyAmount : 0;
    }
    return countIn(month) > 0 ? monthlyAmount : 0;
  }

  // 明細に出す「何回目か」
  String countLabelIn(DateTime month) {
    final n = countIn(month);
    return n > 0 ? '$n/$installmentCount回目' : '残り$remainingMonths回（開始日なし）';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cardName': cardName,
        'totalAmount': totalAmount,
        'installmentCount': installmentCount,
        'remainingMonths': remainingMonths,
        'monthlyAmount': monthlyAmount,
        'interestRate': interestRate,
        'startDate': startDate?.toIso8601String(),
      };

  factory Installment.fromJson(Map<String, dynamic> json) => Installment(
        id: json['id'],
        name: json['name'],
        cardName: json['cardName'] ?? '',
        totalAmount: json['totalAmount'],
        installmentCount: json['installmentCount'],
        remainingMonths: json['remainingMonths'],
        monthlyAmount: json['monthlyAmount'],
        interestRate: (json['interestRate'] ?? 0).toDouble(),
        startDate: json['startDate'] != null ? DateTime.parse(json['startDate']) : null,
      );
}

// 分割の月額を計算（単純な年率手数料: 元金 × 年率% × 回数/12 を上乗せ）
int computeInstallmentMonthly(int principal, int count, double annualRatePercent) {
  if (count <= 0) return principal;
  final fee = principal * (annualRatePercent / 100) * (count / 12);
  return ((principal + fee) / count).round();
}

// ───────────────────────── ローン ─────────────────────────
// 💡 分割払いとの違い: 分割はカードの請求に含まれて落ちるが、
//   ローンは口座から直接引き落とされることが多く、返済日も独立している。
//   奨学金のように「卒業してから返済開始」というものもあるので、
//   返済開始の年月を持たせて、それより前の月は何も引かない。
class Loan {
  final String id;
  String name; // 奨学金、車のローン など
  int principal; // 借入総額（元金）
  double interestRate; // 年利(%)。0＝無利息（奨学金の第一種など）
  int totalCount; // 返済回数（月）
  DateTime startMonth; // 初回返済の年月
  int payDay; // 毎月の返済日
  // 引き落とし方法。'' = 口座から直接、カード名 = そのカードの請求に含める
  String method;
  int monthlyOverride; // 0以外なら毎月の返済額をこの値で固定
  // 💡 ショッピングクレジットは「初回だけ金額が違う」ことが多い
  //   （例: 第1回 9,800円／第2回目以降 8,000円×23回）。0なら毎月と同じ。
  int firstPaymentAmount;
  // 💡 頭金。借入額(principal)には含まれない「最初にまとめて払うぶん」。
  //   口座払いならその日に一度だけ出ていく。カード払いならそのカードの請求に入る。
  int downPayment;
  DateTime? downPaymentDate;
  String downPaymentMethod; // '' = 口座から, カード名 = そのカード
  // 💡 請求元表記は表示名と分けて覚える。名前を変えても紐づけは維持する。
  List<String> bankBillingNames;
  bool autoLinkBankBills;

  Loan({
    required this.id,
    required this.name,
    required this.principal,
    required this.totalCount,
    required this.startMonth,
    this.interestRate = 0,
    this.payDay = 27,
    this.method = '',
    this.monthlyOverride = 0,
    this.firstPaymentAmount = 0,
    this.downPayment = 0,
    this.downPaymentDate,
    this.downPaymentMethod = '',
    List<String>? bankBillingNames,
    this.autoLinkBankBills = true,
  }) : bankBillingNames = bankBillingNames ?? [];

  // 頭金を含めた総額（車両価格など）
  int get totalPrice => principal + downPayment;
  // 返済の総額（手数料込み。初回だけ違う場合も正しく足す）
  int get totalRepayment =>
      firstAmount + monthlyAmount * (totalCount > 0 ? totalCount - 1 : 0);

  bool get hasDownPayment => downPayment > 0 && downPaymentDate != null;
  bool get isDownPaymentFromAccount => downPaymentMethod.isEmpty;

  bool get isFromAccount => method.isEmpty;
  bool get isCardPayment => method.isNotEmpty;

  // 手数料（分割払手数料）を含めた支払総額
  int get _totalWithFee {
    final fee = principal * (interestRate / 100) * (totalCount / 12);
    return (principal + fee).round();
  }

  // 2回目以降の返済額。指定があればそれを使う。
  // 初回だけ違う契約なら、残りを回数-1で割る（総額が合うように）。
  int get monthlyAmount {
    if (monthlyOverride > 0) return monthlyOverride;
    if (firstPaymentAmount > 0 && totalCount > 1) {
      return ((_totalWithFee - firstPaymentAmount) / (totalCount - 1)).round();
    }
    return computeInstallmentMonthly(principal, totalCount, interestRate);
  }

  // 初回の返済額（指定が無ければ毎月と同じ）
  int get firstAmount =>
      firstPaymentAmount > 0 ? firstPaymentAmount : monthlyAmount;

  // n回目の返済額
  int amountForCount(int n) => n == 1 ? firstAmount : monthlyAmount;

  // その月に払う額（返済期間外は0）
  int amountIn(DateTime month) {
    final n = countIn(month);
    return n == 0 ? 0 : amountForCount(n);
  }

  // その月が何回目の返済か（1始まり）。返済期間外なら0。
  int countIn(DateTime month) {
    final diff = (month.year - startMonth.year) * 12 + (month.month - startMonth.month);
    if (diff < 0 || diff >= totalCount) return 0;
    return diff + 1;
  }

  bool isActiveIn(DateTime month) => countIn(month) > 0;

  // 完済する月（最後の返済月）
  DateTime get finishMonth =>
      DateTime(startMonth.year, startMonth.month + totalCount - 1);

  // 基準日の時点で残っている回数
  int remainingCountAt(DateTime now) {
    final done = (now.year - startMonth.year) * 12 + (now.month - startMonth.month);
    if (done < 0) return totalCount; // まだ返済が始まっていない
    final left = totalCount - done;
    return left < 0 ? 0 : left;
  }

  // 残債（これから払う回のぶんを足し上げる）
  int remainingAmountAt(DateTime now) {
    final done = (now.year - startMonth.year) * 12 + (now.month - startMonth.month);
    if (done <= 0) return totalRepayment; // まだ1回も払っていない
    var total = 0;
    for (var n = done + 1; n <= totalCount; n++) {
      total += amountForCount(n);
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'principal': principal,
        'interestRate': interestRate,
        'totalCount': totalCount,
        'startMonth': startMonth.toIso8601String(),
        'payDay': payDay,
        'method': method,
        'monthlyOverride': monthlyOverride,
        'firstPaymentAmount': firstPaymentAmount,
        'downPayment': downPayment,
        'downPaymentDate': downPaymentDate?.toIso8601String(),
        'downPaymentMethod': downPaymentMethod,
        'bankBillingNames': bankBillingNames,
        'autoLinkBankBills': autoLinkBankBills,
      };

  factory Loan.fromJson(Map<String, dynamic> json) => Loan(
        id: json['id'],
        name: json['name'] ?? '',
        principal: json['principal'] ?? 0,
        interestRate: (json['interestRate'] ?? 0).toDouble(),
        totalCount: json['totalCount'] ?? 1,
        startMonth: DateTime.parse(json['startMonth']),
        payDay: json['payDay'] ?? 27,
        method: json['method'] ?? '',
        monthlyOverride: json['monthlyOverride'] ?? 0,
        firstPaymentAmount: json['firstPaymentAmount'] ?? 0,
        downPayment: json['downPayment'] ?? 0,
        downPaymentDate: (json['downPaymentDate'] as String?) == null
            ? null
            : DateTime.tryParse(json['downPaymentDate']),
        downPaymentMethod: json['downPaymentMethod'] ?? '',
        bankBillingNames: (json['bankBillingNames'] as List? ?? [])
            .map((e) => e.toString()).toList(),
        autoLinkBankBills: json['autoLinkBankBills'] ?? true,
      );
}


// ───────────────────────── 予定支出 ─────────────────────────
// 💡 車検・旅行・家電の買い替えなど、決まった日に一度だけ出ていくお金。
//   予定入金の裏返し。毎月の固定費（定期支払い）とは別物。
class PlannedExpense {
  final String id;
  String title;
  int amount;
  DateTime date; // 支払予定日
  bool monthly; // 毎月繰り返すか

  PlannedExpense({
    required this.id,
    required this.title,
    required this.amount,
    required this.date,
    this.monthly = false,
  });

  DateTime? dateIn(DateTime month) {
    if (!monthly) {
      return (date.year == month.year && date.month == month.month) ? date : null;
    }
    if (DateTime(month.year, month.month).isBefore(DateTime(date.year, date.month))) {
      return null;
    }
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return DateTime(month.year, month.month, date.day > lastDay ? lastDay : date.day);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'date': date.toIso8601String(),
        'monthly': monthly,
      };

  factory PlannedExpense.fromJson(Map<String, dynamic> json) => PlannedExpense(
        id: json['id'] ?? '',
        title: json['title'] ?? '',
        amount: json['amount'] ?? 0,
        date: DateTime.parse(json['date']),
        monthly: json['monthly'] ?? false,
      );
}

// ───────────────────────── 定期支払い ─────────────────────────
// 定期支払いの「手動」支払いを表す値（method に入る）
const String kManualPayMethod = '手動';

class Subscription {
  final String id;
  String title;
  int amount;
  int payDay;
  // 支払い方法。
  //   '' = 口座振替（口座から自動で引かれる）
  //   '手動' = 自分で払う（振込・現金など。払ったら記録して残高から引く）
  //   カード名 = そのカード払い（カードの引き落とし額に含まれるので口座からは別途引かない）
  String method;

  Subscription({
    required this.id,
    required this.title,
    required this.amount,
    required this.payDay,
    this.method = '',
  });

  // 口座振替（自動引き落とし）か
  bool get isFromAccount => method.isEmpty;
  // 自分で払うか
  bool get isManualPay => method == kManualPayMethod;
  // カード払いか（カード請求に含まれる＝口座から別途引かない）
  bool get isCardPayment => method.isNotEmpty && method != kManualPayMethod;
  // 支払い方法の表示名
  String get methodLabel => isFromAccount ? '口座振替' : method;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'payDay': payDay,
        'method': method,
      };

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: json['id'],
        title: json['title'],
        amount: json['amount'],
        payDay: json['payDay'],
        method: json['method'] ?? '',
      );
}

// ───────────────────────── ATM引き出し ─────────────────────────
class Withdrawal {
  final String id;
  DateTime date;
  int amount;
  String memo;
  // 💡 登録したときに「口座から引いて財布に足した」か。
  //   ⚠️ 以前の版で登録した引き出しは記録だけで、口座も財布も動かしていない（false のまま読む）。
  //     取り消すときに、動かしていないお金を戻さないための印。
  bool movedToWallet;

  Withdrawal({
    required this.id,
    required this.date,
    required this.amount,
    this.memo = '',
    this.movedToWallet = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'amount': amount,
        'memo': memo,
        if (movedToWallet) 'movedToWallet': true,
      };

  factory Withdrawal.fromJson(Map<String, dynamic> json) => Withdrawal(
        id: json['id'],
        date: DateTime.parse(json['date']),
        amount: json['amount'],
        memo: json['memo'] ?? '',
        movedToWallet: json['movedToWallet'] == true,
      );
}

// ───────────────────────── 口座への入金 ─────────────────────────
// 💡 銀行の「振込入金のお知らせ」メール。
//   このメールには金額が載らない（SMBCダイレクトで確認する形式）ため、
//   アプリを開いたときにポップアップで金額を入力してもらう。
class DepositNotice {
  final String sourceId; // メールID（重複表示を防ぐ一意キー）
  final DateTime date; // 入金日（メール受信日時）

  DepositNotice({required this.sourceId, required this.date});

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'date': date.toIso8601String(),
      };

  factory DepositNotice.fromJson(Map<String, dynamic> json) => DepositNotice(
        sourceId: json['sourceId'] ?? '',
        date: DateTime.parse(json['date']),
      );
}

// ───────────────────── PayPayからの出金（口座への入金予定） ─────────────────────
// 💡 PayPay残高を銀行へ出金すると「出金を受け付けました」メールが届く。
//   金額と振込予定日が載っているので、着金前から予想残高に入れられる。
//   （銀行の「振込入金のお知らせ」は金額が載らないので、それだけでは予想に入れられない）
class PayPayTransfer {
  final String id; // 取引番号（同じ出金を二重に数えないためのキー）
  final int amount; // 口座に入る見込み額（手数料は差し引き済み）
  final DateTime acceptedAt; // 出金を受け付けた日時
  final DateTime scheduledDate; // 振込予定日（「前後」なので確定ではない）
  final String bank;

  const PayPayTransfer({
    required this.id,
    required this.amount,
    required this.acceptedAt,
    required this.scheduledDate,
    required this.bank,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'amount': amount,
        'acceptedAt': acceptedAt.toIso8601String(),
        'scheduledDate': scheduledDate.toIso8601String(),
        'bank': bank,
      };

  static PayPayTransfer? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final amount = j['amount'];
    final acc = DateTime.tryParse('${j['acceptedAt']}');
    final sch = DateTime.tryParse('${j['scheduledDate']}');
    if (id is! String || amount is! int || acc == null || sch == null) return null;
    return PayPayTransfer(
      id: id,
      amount: amount,
      acceptedAt: acc,
      scheduledDate: sch,
      bank: j['bank'] as String? ?? '',
    );
  }
}

// ───────────────────── 予定入金 ─────────────────────
// 💡 これから入ってくる予定のお金（仕送り・返金・臨時収入など）。
//   給料はシフトから自動計算するので、それ以外の入金をここに登録する。
class PlannedIncome {
  final String id;
  String title;
  int amount;
  DateTime date; // 入金予定日
  bool monthly; // 毎月繰り返すか

  PlannedIncome({
    required this.id,
    required this.title,
    required this.amount,
    required this.date,
    this.monthly = false,
  });

  // 指定月の入金予定日（毎月繰り返しなら、その月の同じ日）
  DateTime? dateIn(DateTime month) {
    if (!monthly) {
      return (date.year == month.year && date.month == month.month) ? date : null;
    }
    // 繰り返しは登録日以降の月だけ
    if (DateTime(month.year, month.month).isBefore(DateTime(date.year, date.month))) {
      return null;
    }
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return DateTime(month.year, month.month, date.day > lastDay ? lastDay : date.day);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'amount': amount,
        'date': date.toIso8601String(),
        'monthly': monthly,
      };

  factory PlannedIncome.fromJson(Map<String, dynamic> json) => PlannedIncome(
        id: json['id'] ?? '',
        title: json['title'] ?? '',
        amount: json['amount'] ?? 0,
        date: DateTime.parse(json['date']),
        monthly: json['monthly'] ?? false,
      );
}

// ───────────────────── 残高の増減履歴 ─────────────────────
// 💡 入金・引き落としを口座残高に反映したときの記録。
//   「いつ・何を・いくら反映したか」を後から確認でき、間違えたら取り消せる。
enum BalanceEntryKind { deposit, draw }

// 💡 入出金の履歴に出す1行。
//   保存した履歴（entry あり）と、明細から作るデビットの利用（entry なし）の両方を運ぶ。
class LedgerRow {
  final DateTime at;
  final String label;
  final int amount; // 正の数
  final bool isDeposit;
  final BalanceEntry? entry; // 保存した履歴なら中身（取り消しに使う）
  final int? balanceAfter; // 反映後の残高。デビットは残高を動かさないので null

  const LedgerRow({
    required this.at,
    required this.label,
    required this.amount,
    required this.isDeposit,
    this.entry,
    this.balanceAfter,
  });

  // デビットの利用（明細から作った行）は取り消せない。明細側で直す。
  bool get isDebit => entry == null;
}

class BalanceEntry {
  final String id;
  final BalanceEntryKind kind;
  final String label; // 勤務先名・カード名・サービス名など
  final int amount; // 正の数（入金は＋、引き落としは−として扱う）
  final DateTime at; // 反映した日時
  final int balanceAfter; // 反映後の口座残高
  final String? workplaceId; // 給料入金のとき、どのバイトか
  final String? sourceKey; // 元の通知ID（取り消し時に再表示するため）

  BalanceEntry({
    required this.id,
    required this.kind,
    required this.label,
    required this.amount,
    required this.at,
    required this.balanceAfter,
    this.workplaceId,
    this.sourceKey,
  });

  // 残高への影響（入金＝＋、引き落とし＝−）
  int get signedAmount => kind == BalanceEntryKind.deposit ? amount : -amount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.index,
        'label': label,
        'amount': amount,
        'at': at.toIso8601String(),
        'balanceAfter': balanceAfter,
        'workplaceId': workplaceId,
        'sourceKey': sourceKey,
      };

  factory BalanceEntry.fromJson(Map<String, dynamic> json) => BalanceEntry(
        id: json['id'] ?? '',
        kind: BalanceEntryKind.values[json['kind'] ?? 0],
        label: json['label'] ?? '',
        amount: json['amount'] ?? 0,
        at: DateTime.parse(json['at']),
        balanceAfter: json['balanceAfter'] ?? 0,
        workplaceId: json['workplaceId'],
        sourceKey: json['sourceKey'],
      );
}
