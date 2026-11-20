import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import 'app_sheet.dart';
import '../money_format.dart';
import '../ui/components.dart';
import '../ui/tokens.dart';

// 💡 入金を反映する前に、日付の過ぎた未処理の引き落としを先に確認してもらう。
// ⚠️ 入金を反映すると残高の基準日が今日に進み、それより前の引き落としは
//   予想から外れる。未処理のまま進めると、口座からは出ていったのに予想にも
//   残高にも入らず、予想が実際より多く見える（画面は壊れないので気づけない）。
//   true＝入金の手続きへ進んでよい。
Future<bool> confirmDrawsBeforeDeposit(BuildContext context, AppState appState) async {
  final atRisk = appState.drawsAtRiskOnSnapshotAdvance;
  if (atRisk.isEmpty) return true;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('先に引き落としを確認してください'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'まだ残高に反映していない引き落としがあります。'
            'このまま入金を反映すると、これらは予想残高から外れます。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          for (final d in atRisk.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text('${d.date.month}/${d.date.day}  ',
                      style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  Expanded(child: Text(d.label, style: const TextStyle(fontSize: 13))),
                  Text('¥${yenNum(d.amount)}',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          if (atRisk.length > 5)
            Text('ほか${atRisk.length - 5}件',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'cancel'),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'proceed'),
          child: const Text('このまま入金'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, 'draws'),
          child: const Text('引き落としを先に確認'),
        ),
      ],
    ),
  );
  if (!context.mounted) return false;
  switch (choice) {
    case 'proceed':
      return true;
    case 'draws':
      // 古い順に1件ずつ聞く。「あとで」で閉じたら、そこで止める（入金にも進まない）
      for (final d in atRisk) {
        if (!context.mounted) return false;
        await showDrawDialog(context, appState, d);
        final stillPending = appState.pendingDraws.any((p) => p.id == d.id);
        if (stillPending) return false;
      }
      return context.mounted;
    default:
      return false;
  }
}

// 💡 「振込入金のお知らせ」メールを受けて、金額を入力してもらうポップアップ。
//   メールに金額が載らないため、ユーザーに入力してもらって口座残高へ加算する。
//   給料日が一致する勤務先は自動で選ばれ、見込み額が金額欄に入る。
Future<void> showDepositDialog(
  BuildContext context,
  AppState appState,
  DepositNotice notice,
) async {
  if (!await confirmDrawsBeforeDeposit(context, appState)) return;
  if (!context.mounted) return;
  // 💡 まだ受け取っていない勤務先だけを選択肢に出す（入金済みは消す）
  final awaiting = appState.workplacesAwaitingSalary(notice.date);
  // 入金日が給料日に近い勤務先（近い順）。未入金のものだけ推奨にする。
  final candidates = appState
      .workplacesWithPaydayNear(notice.date)
      .where((w) => awaiting.any((a) => a.id == w.id))
      .toList();
  String? selectedWpId = candidates.isNotEmpty ? candidates.first.id : null;
  final amountCtrl = TextEditingController();

  // 選んだ勤務先の見込み手取りを金額欄に入れる
  void fillEstimate() {
    final w = appState.workplaceById(selectedWpId);
    if (w == null) return;
    final wm = appState.workMonthForPayday(w, notice.date);
    final est = appState.takeHomeOfWorkplace(wm, w.id);
    if (est > 0) amountCtrl.text = est.toString();
  }

  // 💡 PayPayの出金の着金と見られるなら、メールに載っていた金額を入れて選んでおく。
  //   ⚠️ 選んだまま保存すると「受け取り済み」になる。結びつけずに保存すると、
  //     振込予定日がまだ先のとき予想でもう一度足されるので、既定で選ぶ。
  final transfer = appState.transferForDeposit(notice);
  var useTransfer = transfer != null;
  if (transfer != null) {
    selectedWpId = null;
    amountCtrl.text = transfer.amount.toString();
  } else {
    fillEstimate();
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Row(
          children: [
            Text('💰 ', style: TextStyle(fontSize: 22)),
            Expanded(child: Text('入金がありました', style: TextStyle(fontSize: 18))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${DateFormat('M月d日').format(notice.date)} に振込入金のお知らせが届いています。',
                style: const TextStyle(fontSize: 13, color: Colors.black87),
              ),
              const SizedBox(height: 2),
              Text(
                transfer != null
                    ? 'PayPayの出金（${transfer.acceptedAt.month}/${transfer.acceptedAt.day}受付）の着金と見られます。金額が違えば直してください。'
                    : 'メールに金額が無いため、入金額を入力してください。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '入金額',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (awaiting.isNotEmpty || transfer != null) ...[
                const SizedBox(height: 14),
                const Text('どの入金ですか？',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (transfer != null)
                      ChoiceChip(
                        avatar: const Icon(Icons.account_balance_wallet, size: 14),
                        label: Text('PayPayの出金 ¥${yenNum(transfer.amount)}',
                            style: const TextStyle(fontSize: 12)),
                        selected: useTransfer,
                        onSelected: (_) => setLocal(() {
                          useTransfer = true;
                          selectedWpId = null;
                          amountCtrl.text = transfer.amount.toString();
                        }),
                      ),
                    ...awaiting.map((w) {
                      // 給料日が入金日と近い勤務先には「推奨」マークを出す
                      final isPayday = candidates.any((c) => c.id == w.id);
                      return ChoiceChip(
                        avatar: CircleAvatar(
                          backgroundColor: Color(w.colorValue),
                          radius: 6,
                        ),
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${w.name}の給料', style: const TextStyle(fontSize: 12)),
                            if (isPayday) ...[
                              const SizedBox(width: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.amber.shade700,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star, size: 9, color: Colors.white),
                                    SizedBox(width: 2),
                                    Text('推奨',
                                        style: TextStyle(
                                            fontSize: 9,
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        selected: !useTransfer && selectedWpId == w.id,
                        onSelected: (_) => setLocal(() {
                          useTransfer = false;
                          selectedWpId = selectedWpId == w.id ? null : w.id;
                          fillEstimate();
                        }),
                      );
                    }),
                    ChoiceChip(
                      label: const Text('その他の入金', style: TextStyle(fontSize: 12)),
                      selected: !useTransfer && selectedWpId == null,
                      onSelected: (_) => setLocal(() {
                        useTransfer = false;
                        selectedWpId = null;
                      }),
                    ),
                  ],
                ),
                if (selectedWpId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '※ ${_workMonthLabel(appState, selectedWpId!, notice.date)}の実給料としても記録します',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              appState.skipDepositNotice(notice.sourceId);
              Navigator.pop(context);
            },
            child: const Text('スキップ'),
          ),
          ElevatedButton(
            onPressed: () {
              final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('入金額を入力してください')),
                );
                return;
              }
              appState.applyDepositNotice(notice.sourceId, amount,
                  workplaceId: selectedWpId,
                  transferId: useTransfer ? transfer?.id : null);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¥${yenNum(amount)} を口座残高に追加しました')),
              );
            },
            child: const Text('残高に追加'),
          ),
        ],
      ),
    ),
  );
}

String _workMonthLabel(AppState appState, String wpId, DateTime date) {
  final w = appState.workplaceById(wpId);
  if (w == null) return '';
  final wm = appState.workMonthForPayday(w, date);
  return '${wm.month}月分';
}

// 💡 手入力で口座に入金する（メール通知が無いときや現金入金用）
Future<void> showManualDepositDialog(BuildContext context, AppState appState) async {
  if (!await confirmDrawsBeforeDeposit(context, appState)) return;
  if (!context.mounted) return;
  final amountCtrl = TextEditingController();
  String? selectedWpId;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setLocal) => AlertDialog(
        title: const Text('口座に入金'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('現在の口座残高に加算します。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 10),
              TextField(
                controller: amountCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '入金額',
                  prefixText: '¥ ',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (appState.workplacesAwaitingSalary(DateTime.now()).isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('給料の場合はバイトを選択',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ...appState.workplacesAwaitingSalary(DateTime.now()).map((w) => ChoiceChip(
                          avatar: CircleAvatar(
                              backgroundColor: Color(w.colorValue), radius: 6),
                          label: Text(w.name, style: const TextStyle(fontSize: 12)),
                          selected: selectedWpId == w.id,
                          onSelected: (_) => setLocal(
                              () => selectedWpId = selectedWpId == w.id ? null : w.id),
                        )),
                    ChoiceChip(
                      label: const Text('その他', style: TextStyle(fontSize: 12)),
                      selected: selectedWpId == null,
                      onSelected: (_) => setLocal(() => selectedWpId = null),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? 0;
              if (amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('入金額を入力してください')),
                );
                return;
              }
              appState.addDeposit(amount, workplaceId: selectedWpId);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¥${yenNum(amount)} を口座残高に追加しました')),
              );
            },
            child: const Text('入金する'),
          ),
        ],
      ),
    ),
  );
}

// 💡 確認待ちの引き落としが、入力した残高に含まれているかの説明（AppState の推定を言葉にする）。
//   ⚠️ 「反映済み」とは言わない。前後関係からの推定なので「可能性」「見込み」と書く。
String drawReflectionText(AppState appState, DrawReflection r) {
  final at = appState.balanceEnteredAt;
  final when = at == null ? '' : '${at.month}/${at.day} に入力した';
  return switch (r) {
    DrawReflection.maybeIncluded =>
      '$when残高に、この引き落としが含まれている可能性があります。通帳やアプリの残高と比べてください',
    DrawReflection.likelyNotIncluded => '$when残高より後の引き落としです。まだ残高に入っていない見込みです',
    DrawReflection.unknown => at == null
        ? '残高を入力した記録が無いため、残高に入っているか分かりません'
        : '残高を入力した日と同じ日の引き落としです。入力の前か後か分かりません',
  };
}

BannerKind _bannerOf(DrawReflection r) => switch (r) {
      DrawReflection.maybeIncluded => BannerKind.info,
      DrawReflection.likelyNotIncluded => BannerKind.caution,
      DrawReflection.unknown => BannerKind.caution,
    };

// 💡 残高から引く前の最終確認。対象・金額・変更後の残高を必ず見せる。
//   含まれている可能性がある／判断できないときは、二重に引くおそれを書く。
Future<bool> confirmSubtract(
  BuildContext context,
  AppState appState, {
  required List<({String label, DateTime date, int amount})> items,
  required DrawReflection reflection,
}) async {
  final total = items.fold<int>(0, (s, e) => s + e.amount);
  final before = appState.effectiveBalance;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('残高から引きますか？'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                        child: Text('${e.date.month}/${e.date.day}  ${e.label}', style: AppText.body)),
                    MoneyText(-e.amount, signed: true, style: AppText.body),
                  ],
                ),
              ),
            const Divider(height: 20),
            Row(children: [
              const Expanded(child: Text('いまの残高', style: AppText.body)),
              MoneyText(before, style: AppText.body),
            ]),
            Row(children: [
              const Expanded(child: Text('引く金額', style: AppText.body)),
              MoneyText(-total, signed: true, style: AppText.body),
            ]),
            Row(children: [
              const Expanded(
                  child: Text('引いた後の残高', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold))),
              MoneyText(before - total, style: AppText.amount),
            ]),
            if (reflection != DrawReflection.likelyNotIncluded)
              const StatusBanner(
                kind: BannerKind.caution,
                message: '入力した残高に含まれていると、二重に引くことになります',
                detail: '通帳やアプリの残高で、まだ引かれていないことを確かめてから引いてください',
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('やめる')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('引く')),
      ],
    ),
  );
  return ok == true;
}

// 💡 確認待ちの引き落とし（ホームの確認待ちから開く）。
//   基本の操作は「残高はそのまま（確認した）」。まだ入っていない見込みのときだけ「引く」を主にする。
//   どちらも AppState 側で一度だけ反映する（処理済みなら何もしない）。
Future<void> showDrawDialog(
  BuildContext context,
  AppState appState,
  ({String id, String label, int amount, DateTime date}) draw,
) async {
  final amountCtrl = TextEditingController(text: draw.amount.toString());
  final reflection = appState.drawReflectionOf(draw.date);
  final notIncluded = reflection == DrawReflection.likelyNotIncluded;

  void done(String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('引き落としの確認'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${DateFormat('M月d日').format(draw.date)}  ${draw.label}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            if (draw.label.contains('（予定）'))
              const Text('見込みの金額です。実際の引き落とし額に直せます', style: AppText.caption),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '引き落とし額',
                prefixText: '¥ ',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            StatusBanner(kind: _bannerOf(reflection), message: drawReflectionText(appState, reflection)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('あとで')),
        if (notIncluded)
          TextButton(
              onPressed: () => Navigator.pop(context, 'keep'), child: const Text('残高はそのまま')),
        if (notIncluded)
          ElevatedButton(
              onPressed: () => Navigator.pop(context, 'subtract'), child: const Text('残高から引く…'))
        else ...[
          TextButton(
              onPressed: () => Navigator.pop(context, 'subtract'), child: const Text('残高から引く…')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, 'keep'),
              child: const Text('残高はそのまま（確認した）')),
        ],
      ],
    ),
  );
  if (action == 'keep') {
    if (!appState.skipDraw(draw.id)) done('この引き落としは処理済みです');
    return;
  }
  if (action != 'subtract' || !context.mounted) return;
  final amount = int.tryParse(amountCtrl.text.replaceAll(',', '')) ?? draw.amount;
  final ok = await confirmSubtract(context, appState,
      items: [(label: draw.label, date: draw.date, amount: amount)], reflection: reflection);
  if (!ok) return;
  if (appState.applyDraw(draw.id, amount, label: draw.label)) {
    done('¥${yenNum(amount)} を口座残高から引きました');
  } else {
    done('この引き落としは処理済みです（二重には引いていません）');
  }
}

// 💡 引き落としの一覧＋手入力。確認待ちの引き落としを1件ずつ、またはまとめて処理する。
//   ⚠️ 以前の「すべて引く」は、入力した残高に含まれている可能性があるものまで引いていた。
//     まとめて引けるのは「まだ入っていない見込み」のものだけにした。
Future<void> showDrawSheet(BuildContext context, AppState appState) async {
  showAppSheet<void>(context, (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final pending = appState.pendingDraws;
        final notIncluded = [
          for (final d in pending)
            if (appState.drawReflectionOf(d.date) == DrawReflection.likelyNotIncluded) d,
        ];
        final notIncludedTotal = notIncluded.fold<int>(0, (s, d) => s + d.amount);
        return Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('口座から引き落とし',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('いまの残高 ¥${yenNum(appState.effectiveBalance)}', style: AppText.caption),
              const SizedBox(height: 12),
              if (pending.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('確認待ちの引き落としはありません', style: AppText.caption),
                )
              else ...[
                const Text('確認待ちの引き落とし', style: AppText.caption),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final d in pending)
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                          '${DateFormat('M/d').format(d.date)}  ${d.label}',
                                          style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                                    ),
                                    MoneyText(-d.amount, signed: true, style: AppText.body),
                                  ],
                                ),
                                Text(drawReflectionText(appState, appState.drawReflectionOf(d.date)),
                                    style: AppText.caption),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () {
                                        appState.skipDraw(d.id);
                                        setLocal(() {});
                                      },
                                      child: const Text('残高はそのまま'),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        final ok = await confirmSubtract(ctx, appState,
                                            items: [(label: d.label, date: d.date, amount: d.amount)],
                                            reflection: appState.drawReflectionOf(d.date));
                                        if (ok) appState.applyDraw(d.id, d.amount, label: d.label);
                                        setLocal(() {});
                                      },
                                      child: const Text('残高から引く…'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (notIncluded.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final ok = await confirmSubtract(ctx, appState,
                            items: [
                              for (final d in notIncluded)
                                (label: d.label, date: d.date, amount: d.amount),
                            ],
                            reflection: DrawReflection.likelyNotIncluded);
                        if (ok) appState.applyLikelyNotIncludedDraws();
                        setLocal(() {});
                      },
                      child: Text(
                          'まだ入っていない見込みの${notIncluded.length}件を引く（−¥${yenNum(notIncludedTotal)}）…'),
                    ),
                  ),
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (c) => AlertDialog(
                        title: const Text('すべて確認済みにしますか？'),
                        content: Text('${pending.length}件を、残高を変えずに確認済みにします。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('やめる')),
                          ElevatedButton(
                              onPressed: () => Navigator.pop(c, true), child: const Text('確認済みにする')),
                        ],
                      ),
                    );
                    if (ok == true) appState.skipAllDraws();
                    setLocal(() {});
                  },
                  child: const Text('すべて確認済みにする（残高はそのまま）'),
                ),
              ],
              const Divider(height: 24),
              // 手入力（通知に無い引き落とし・現金払いなど）
              const Text('手入力で引く', style: AppText.caption),
              const SizedBox(height: 6),
              _ManualSubtractRow(appState: appState),
            ],
          ),
        );
      },
    ),
  );
}

class _ManualSubtractRow extends StatefulWidget {
  final AppState appState;
  const _ManualSubtractRow({required this.appState});

  @override
  State<_ManualSubtractRow> createState() => _ManualSubtractRowState();
}

class _ManualSubtractRowState extends State<_ManualSubtractRow> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '金額',
              prefixText: '¥ ',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: () {
            final amount = int.tryParse(_ctrl.text.replaceAll(',', '')) ?? 0;
            if (amount <= 0) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('金額を入力してください')),
              );
              return;
            }
            widget.appState.subtractFromBalance(amount);
            _ctrl.clear();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('¥${yenNum(amount)} を口座残高から引きました')),
            );
          },
          child: const Text('引く'),
        ),
      ],
    );
  }
}
