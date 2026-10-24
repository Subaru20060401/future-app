import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import 'app_sheet.dart';

// 💡 初回だけ対応関係を選び、以後の取り込み・他端末への同期でも使う。
void showBillingLinkSheet(BuildContext context) {
  showAppSheet(
    context,
    (ctx) => Consumer<AppState>(
      builder: (ctx, app, _) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'メールの請求名を確認',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '同じ支払いのカード・ローンを選ぶと、次回からも対応を記憶します。'
              'ローンの銀行確定額には、手動の予定額を重ねて足しません。',
            ),
            const SizedBox(height: 12),
            if (app.unregisteredCardNames.isEmpty) const Text('未確認の請求名はありません'),
            for (final u in app.unregisteredCardNames)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(u.name),
                subtitle: Text('明細 ${u.count}件'),
                trailing: TextButton(
                  onPressed: () => _pickTarget(ctx, app, u.name),
                  child: const Text('対応を選ぶ'),
                ),
              ),
            for (final l in app.loans)
              for (final name in l.bankBillingNames)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link),
                  title: Text(name),
                  subtitle: Text('ローン：${l.name}'),
                  trailing: TextButton(
                    onPressed: () => app.unlinkBankBillingFromLoan(l.id, name),
                    child: const Text('解除'),
                  ),
                ),
          ],
        ),
      ),
    ),
  );
}

void _pickTarget(BuildContext context, AppState app, String name) {
  final hasBank = app.payments.any(
    (p) => p.cardName == name && p.source == PaymentSource.bank,
  );
  final loans = hasBank
      ? app.loans
            .where(
              (l) =>
                  l.isFromAccount ||
                  (l.hasDownPayment && l.isDownPaymentFromAccount),
            )
            .toList()
      : <Loan>[];
  final cards = app.cardPaymentDays.keys.where((c) => c != name).toList();
  loans.sort(
    (a, b) => (AppState.billingNamesSimilar(name, b.name) ? 1 : 0).compareTo(
      AppState.billingNamesSimilar(name, a.name) ? 1 : 0,
    ),
  );
  cards.sort(
    (a, b) => (AppState.billingNamesSimilar(name, b) ? 1 : 0).compareTo(
      AppState.billingNamesSimilar(name, a) ? 1 : 0,
    ),
  );
  showAppSheet(
    context,
    (ctx) => Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '「$name」はどの支払い？',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('同じ会社でも別の契約なら、紐づけずに閉じてください。'),
          for (final l in loans)
            ListTile(
              leading: const Icon(Icons.account_balance),
              title: Text(l.name),
              subtitle: Text(
                AppState.billingNamesSimilar(name, l.name)
                    ? 'ローン・名前が似ています'
                    : 'ローン',
              ),
              onTap: () {
                app.linkBankBillingToLoan(name, l.id);
                Navigator.pop(ctx);
              },
            ),
          for (final card in cards)
            ListTile(
              leading: const Icon(Icons.credit_card),
              title: Text(card),
              subtitle: Text(
                AppState.billingNamesSimilar(name, card)
                    ? 'カード・名前が似ています'
                    : 'カード',
              ),
              onTap: () {
                app.mergeCardName(name, card);
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    ),
  );
}
