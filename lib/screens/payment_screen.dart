import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../app_state.dart';
import '../card_styles.dart';
import '../widgets/gmail_refresh_button.dart';
import '../widgets/swipe_to_delete.dart';
import 'trash_screen.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

// 支払い一覧の並べ替え
enum _SortMode { dateAsc, dateDesc, amountAsc, amountDesc }

class _PaymentScreenState extends State<PaymentScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 4, vsync: this);
  String? _filterCard; // カード絞り込み（nullは全件）
  late DateTime _filterMonth = DateTime(DateTime.now().year, DateTime.now().month); // 初期=今月
  _SortMode _sortMode = _SortMode.dateAsc; // 並べ替え
  bool _showBank = false; // 銀行確定(過去)を表示するか（既定は非表示）
  String _search = ''; // 文字・金額での検索
  final _searchCtrl = TextEditingController();

  // 検索語に一致するか（カード名・利用先・金額のいずれか）
  bool _matchesSearch(Payment p) {
    final q = _search.trim();
    if (q.isEmpty) return true;
    final lower = q.toLowerCase();
    if (p.cardName.toLowerCase().contains(lower)) return true;
    if (p.note.toLowerCase().contains(lower)) return true;
    // 数字だけなら金額の部分一致でも探せる（例: 3000 / 300）
    final digits = q.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isNotEmpty && p.amount.toString().contains(digits)) return true;
    return false;
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('支払い管理'),
        actions: [
          IconButton(
            tooltip: '削除した金額（ゴミ箱）',
            icon: Badge(
              isLabelVisible: appState.trashedPayments.isNotEmpty,
              label: Text('${appState.trashedPayments.length}'),
              child: const Icon(Icons.delete_outline),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TrashScreen()),
            ),
          ),
          const GmailRefreshButton(),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: const [
            Tab(text: 'カード'),
            Tab(text: '分割'),
            Tab(text: '定期'),
            Tab(text: 'ATM'),
          ],
        ),
      ),
      // 💡 単一Scaffold・単一FAB。各タブはリスト表示のみ（入れ子Scaffoldを廃止）
      body: TabBarView(
        controller: _tab,
        children: [
          _cardList(appState),
          _installmentList(appState),
          _subscriptionList(appState),
          _withdrawalList(appState),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.pink,
        onPressed: () => _onAdd(appState),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  // 現在のタブに応じて追加ダイアログを出し分け
  void _onAdd(AppState appState) {
    switch (_tab.index) {
      case 0:
        _addCard(appState);
      case 1:
        _addInstallment(appState);
      case 2:
        _addSubscription(appState);
      case 3:
        _addWithdrawal(appState);
    }
  }

  Widget _empty(String text) => Center(child: Text(text, style: const TextStyle(color: Colors.grey)));

  bool _sameMonth(DateTime d) => d.year == _filterMonth.year && d.month == _filterMonth.month;

  // 利用通知は「利用日時」(時刻あり)、それ以外は「支払日」
  String _dateLabel(Payment p) {
    final d = p.paymentDate;
    if (p.source == PaymentSource.usage) {
      final hasTime = d.hour != 0 || d.minute != 0;
      return hasTime
          ? '利用日時: ${DateFormat('M/d HH:mm').format(d)}'
          : '利用日: ${DateFormat('M/d').format(d)}';
    }
    return '支払日: ${DateFormat('M/d').format(d)}';
  }

  // ───────────────────── カード請求 ─────────────────────
  Widget _cardList(AppState appState) {
    // 月で絞り込み（表示している日付＝利用日/支払日 の月で振り分け）
    var list = appState.payments.where((p) => _sameMonth(p.paymentDate)).toList();
    // 銀行確定(過去データ)は既定で非表示
    if (!_showBank) list = list.where((p) => p.source != PaymentSource.bank).toList();
    // この月に存在するカード一覧
    final cards = list.map((p) => p.cardName).toSet().toList()..sort();
    if (_filterCard != null && !cards.contains(_filterCard)) _filterCard = null;
    if (_filterCard != null) list = list.where((p) => p.cardName == _filterCard).toList();
    // 文字・金額で検索
    list = list.where(_matchesSearch).toList();
    // 並び替え（日付／金額 × 昇順／降順）
    switch (_sortMode) {
      case _SortMode.dateAsc:
        list.sort((a, b) => a.paymentDate.compareTo(b.paymentDate));
        break;
      case _SortMode.dateDesc:
        list.sort((a, b) => b.paymentDate.compareTo(a.paymentDate));
        break;
      case _SortMode.amountAsc:
        list.sort((a, b) => a.amount.compareTo(b.amount));
        break;
      case _SortMode.amountDesc:
        list.sort((a, b) => b.amount.compareTo(a.amount));
        break;
    }
    final searchTotal = list.fold<int>(0, (s, p) => s + p.amount);

    return Column(
      children: [
        // 月セレクタ＋並び替え＋銀行確定トグル
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() =>
                    _filterMonth = DateTime(_filterMonth.year, _filterMonth.month - 1)),
              ),
              Expanded(
                child: Center(
                  child: Text('${_filterMonth.year}年${_filterMonth.month}月',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() =>
                    _filterMonth = DateTime(_filterMonth.year, _filterMonth.month + 1)),
              ),
              // 並べ替え（日付・金額 × 昇順・降順）
              PopupMenuButton<_SortMode>(
                tooltip: '並べ替え',
                icon: Icon(Icons.swap_vert, color: Colors.pink[300]),
                initialValue: _sortMode,
                onSelected: (v) => setState(() => _sortMode = v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _SortMode.dateAsc, child: Text('日付が古い順')),
                  PopupMenuItem(value: _SortMode.dateDesc, child: Text('日付が新しい順')),
                  PopupMenuItem(value: _SortMode.amountAsc, child: Text('金額が安い順')),
                  PopupMenuItem(value: _SortMode.amountDesc, child: Text('金額が高い順')),
                ],
              ),
              IconButton(
                tooltip: _showBank ? '銀行確定を隠す' : '銀行確定(過去)を表示',
                icon: Icon(_showBank ? Icons.history_toggle_off : Icons.history),
                color: _showBank ? Colors.green : null,
                onPressed: () => setState(() => _showBank = !_showBank),
              ),
            ],
          ),
        ),
        // 🔍 検索（利用先・カード名・金額）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: '検索（利用先・カード・金額）',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _search.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() {
                        _search = '';
                        _searchCtrl.clear();
                      }),
                    ),
              isDense: true,
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.7),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        // 検索中は件数と合計を表示
        if (_search.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${list.length}件 ・ 合計 ¥$searchTotal',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
        // カード別フィルタ
        if (cards.isNotEmpty)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: const Text('すべて'),
                    selected: _filterCard == null,
                    onSelected: (_) => setState(() => _filterCard = null),
                  ),
                ),
                ...cards.map((c) {
                  final style = cardStyleOf(c);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: ChoiceChip(
                      avatar: CircleAvatar(backgroundColor: style.color, radius: 6),
                      label: Text(c),
                      selected: _filterCard == c,
                      onSelected: (_) => setState(() => _filterCard = c),
                    ),
                  );
                }),
              ],
            ),
          ),
        Expanded(
          child: list.isEmpty
              ? _empty('この月の請求はありません')
              : ListView(
                  children: list.asMap().entries.map((entry) {
                    final i = entry.key;
                    final p = entry.value;
                    final style = cardStyleOf(p.cardName);
                    return SwipeToDelete(
                      // 重複IDが残っていても衝突しないよう index を併用
                      itemKey: ValueKey('pay_${i}_${p.id}'),
                      onDelete: () => appState.removePayment(p.id),
                      child: Card(
                        child: ListTile(
                          leading: Icon(style.icon, color: style.color),
                          title: Row(
                            children: [
                              Expanded(child: Text(p.cardName)),
                              _sourceBadge(p.source),
                            ],
                          ),
                          subtitle: Text(
                            p.infoOnly
                                ? '${_dateLabel(p)}\n他のカードで計上済みのため、記録のみ'
                                : (p.note.isNotEmpty
                                    ? '${_dateLabel(p)}\n${p.note}'
                                    : '${_dateLabel(p)}\nタップして利用先を書く'),
                            style: p.infoOnly
                                ? const TextStyle(color: Colors.grey)
                                : null,
                          ),
                          isThreeLine: true,
                          onTap: () => _editNote(appState, p),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('¥${p.amount}',
                                  style: TextStyle(
                                      color: p.infoOnly
                                          ? Colors.grey
                                          : (p.paid ? Colors.grey : Colors.red),
                                      decoration: (p.paid || p.infoOnly)
                                          ? TextDecoration.lineThrough
                                          : null)),
                              // 💡 Amazonのメールには支払いカードが載らないので、
                              //   ここで実際に使ったカードへ付け替えられるようにする。
                              if (appState.isAmazonPayment(p))
                                IconButton(
                                  tooltip: p.infoOnly ? '記録のみ（計上していません）' : '使ったカードに移す',
                                  icon: Icon(Icons.drive_file_move_outline,
                                      color: p.infoOnly
                                          ? Colors.grey
                                          : Colors.indigo),
                                  onPressed: () => _moveAmazon(appState, p),
                                ),
                              // 最低分割金額を満たすカードのみ「分割に変換」を表示
                              if (canInstallment(p.cardName, p.amount))
                                IconButton(
                                  tooltip: '分割に変換',
                                  icon: const Icon(Icons.call_split, color: Colors.deepOrange),
                                  onPressed: () => _convertToInstallment(appState, p),
                                ),
                              IconButton(
                                icon: Icon(p.paid ? Icons.check_circle : Icons.radio_button_unchecked,
                                    color: p.paid ? Colors.green : Colors.grey),
                                onPressed: () => appState.togglePaid(p.id),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  // 💡 Amazonの明細を、実際に使ったカードへ付け替える。
  //   既にカード会社の通知で同じ日・同じ金額が入っていれば二重になるので付け替えない。
  Future<void> _moveAmazon(AppState appState, Payment p) async {
    final cards = appState.cardChoices
        .where((c) => c != AppState.kOtherCard)
        .toList();
    final picked = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('どのカードで払いましたか？',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('${DateFormat('M/d').format(p.paymentDate)}・¥${p.amount}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  const Text(
                    'Amazonのメールには支払いカードが載らないため、既定は Amazonマスター として'
                    '計上しています。別のカードで払ったなら選び直してください。',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const Divider(),
            ...cards.map((c) {
              final style = cardStyleOf(c);
              return ListTile(
                leading: Icon(style.icon, color: style.color),
                title: Text(c),
                onTap: () => Navigator.pop(context, c),
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final ok = appState.moveAmazonPaymentTo(p.id, picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '$picked の支出に計上しました'
          : '$picked に同じ日・同じ金額の明細があるため、記録のみに戻しました'),
    ));
  }

  // 💡 「これ何の支払いだっけ」を後から書けるように。
  //   メール由来の明細に書いたメモも、次の取り込みで消えないようにしてある。
  void _editNote(AppState appState, Payment p) {
    final ctrl = TextEditingController(text: p.note);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${p.cardName} ¥${p.amount}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: '利用先',
            hintText: '例: Amazonで購入',
          ),
          onSubmitted: (_) {
            appState.setPaymentNote(p.id, ctrl.text);
            Navigator.pop(context);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              appState.setPaymentNote(p.id, ctrl.text);
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _addCard(AppState appState) {
    // 💡 設定で追加したカードも選べるように、一覧は AppState から取る
    final cards = appState.cardChoices;
    String card = cards.first;
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController(); // 何に使ったか（例: Amazonで購入）
    DateTime date = DateTime.now();
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('カード請求を追加'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: card,
                isExpanded: true,
                items: cards.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setLocal(() => card = v!),
              ),
              TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '請求額(円)')),
              TextField(
                controller: noteCtrl,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: '利用先（任意）',
                  hintText: '例: Amazonで購入',
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('支払日'),
                trailing: Text(DateFormat('M/d').format(date)),
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime(2030));
                  if (d != null) setLocal(() => date = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                appState.addPayment(
                  cardName: card,
                  amount: int.tryParse(amountCtrl.text) ?? 0,
                  date: date,
                  note: noteCtrl.text,
                );
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // 💡 カード請求を分割払いへ変換（回数を入力、金利はカード規則で自動判定）
  void _convertToInstallment(AppState appState, Payment p) {
    final countCtrl = TextEditingController(text: '3');
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final count = int.tryParse(countCtrl.text) ?? 0;
          final valid = count >= 2;
          final free = isInstallmentInterestFree(p.cardName, count);
          final rate = appState.effectiveRateFor(p.cardName, count);
          final monthly = valid ? computeInstallmentMonthly(p.amount, count, rate) : 0;
          return AlertDialog(
            title: const Text('分割に変換'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${p.cardName}  ¥${p.amount}'),
                Text('分割可能: ¥${minInstallmentAmount(p.cardName)}以上',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                TextField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '分割回数（2回以上）'),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                if (!valid)
                  const Text('2回以上を入力してください', style: TextStyle(color: Colors.red, fontSize: 12))
                else ...[
                  Text(free ? '金利: 無料（${p.cardName}の2・3回）' : '金利(年率): ${rate.toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 12, color: free ? Colors.green : Colors.grey)),
                  const SizedBox(height: 4),
                  Text('月額 ¥$monthly × $count回', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
              ElevatedButton(
                onPressed: valid
                    ? () {
                        appState.convertPaymentToInstallment(p.id, count);
                        Navigator.pop(context);
                      }
                    : null,
                child: const Text('分割にする'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ───────────────────── 分割払い ─────────────────────
  Widget _installmentList(AppState appState) {
    if (appState.installments.isEmpty) return _empty('分割払いはありません');
    return ListView(
      children: appState.installments.asMap().entries.map((entry) {
        final i = entry.value;
        final style = i.cardName.isNotEmpty ? cardStyleOf(i.cardName) : null;
        final fee = i.totalWithInterest - i.totalAmount;
        final remaining = appState.remainingMonthsOf(i); // 経過に応じた残回数
        final done = remaining <= 0;
        return SwipeToDelete(
          itemKey: ValueKey('inst_${entry.key}_${i.id}'),
          onDelete: () => appState.removeInstallment(i.id),
          child: Card(
            child: ListTile(
              leading: Icon(done ? Icons.check_circle : Icons.calendar_view_month,
                  color: done ? Colors.green : (style?.color ?? Colors.deepOrange)),
              title: Text(i.name),
              subtitle: Text(
                  '総額¥${i.totalAmount} / ${i.installmentCount}回 / ${done ? '完済' : '残$remaining回'}'
                  '${i.interestRate > 0 ? '\n金利${i.interestRate.toStringAsFixed(1)}% (手数料¥$fee)' : ''}'),
              isThreeLine: i.interestRate > 0,
              trailing: Text(done ? '完済' : '月¥${i.monthlyAmount}',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: done ? Colors.green : null)),
              onTap: () => _editInstallment(appState, i),
            ),
          ),
        );
      }).toList(),
    );
  }

  // 分割回数を編集（金利込みで月額再計算）
  void _editInstallment(AppState appState, Installment inst) {
    final countCtrl = TextEditingController(text: inst.installmentCount.toString());
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) {
          final count = int.tryParse(countCtrl.text) ?? 0;
          final valid = count >= 2;
          final free = isInstallmentInterestFree(inst.cardName, count);
          final rate = appState.effectiveRateFor(inst.cardName, count);
          final monthly = valid ? computeInstallmentMonthly(inst.totalAmount, count, rate) : 0;
          return AlertDialog(
            title: const Text('分割回数を編集'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${inst.name}  元金¥${inst.totalAmount}'),
                const SizedBox(height: 8),
                TextField(
                  controller: countCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '分割回数（2回以上）'),
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                if (!valid)
                  const Text('2回以上を入力してください', style: TextStyle(color: Colors.red, fontSize: 12))
                else ...[
                  Text(free ? '金利: 無料（2・3回）' : '金利(年率): ${rate.toStringAsFixed(1)}%',
                      style: TextStyle(fontSize: 12, color: free ? Colors.green : Colors.grey)),
                  const SizedBox(height: 4),
                  Text('月額 ¥$monthly × $count回', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
              ElevatedButton(
                onPressed: valid
                    ? () {
                        appState.editInstallment(inst.id, count: count);
                        Navigator.pop(context);
                      }
                    : null,
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _addInstallment(AppState appState) {
    final nameCtrl = TextEditingController();
    final totalCtrl = TextEditingController();
    final countCtrl = TextEditingController(text: '12');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('分割払いを追加'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '品名')),
            TextField(controller: totalCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '総額(円)')),
            TextField(controller: countCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '回数')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              appState.addInstallment(
                name: nameCtrl.text,
                totalAmount: int.tryParse(totalCtrl.text) ?? 0,
                count: int.tryParse(countCtrl.text) ?? 1,
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ───────────────────── 定期支払い ─────────────────────
  Widget _subscriptionList(AppState appState) {
    if (appState.subscriptions.isEmpty) return _empty('定期支払いはありません');
    return ListView(
      children: appState.subscriptions
          .map((s) => SwipeToDelete(
                itemKey: Key(s.id),
                onDelete: () => appState.removeSubscription(s.id),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.subscriptions, color: Colors.purple),
                    title: Text(s.title),
                    subtitle: Text('毎月${s.payDay}日 ・ ${s.methodLabel}'),
                    trailing: Text('¥${s.amount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    onTap: () => _editSubscriptionMethod(appState, s),
                  ),
                ),
              ))
          .toList(),
    );
  }

  void _addSubscription(AppState appState) {
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final dayCtrl = TextEditingController(text: '1');
    String method = ''; // '' = 口座振替
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('定期支払いを追加'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'サービス名')),
                TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '金額(円)')),
                TextField(controller: dayCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '支払日(日)')),
                const SizedBox(height: 12),
                const Text('支払い方法', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('口座振替', style: TextStyle(fontSize: 12)),
                      selected: method.isEmpty,
                      onSelected: (_) => setLocal(() => method = ''),
                    ),
                    ChoiceChip(
                      label: const Text('手動で払う', style: TextStyle(fontSize: 12)),
                      selected: method == kManualPayMethod,
                      onSelected: (_) => setLocal(() => method = kManualPayMethod),
                    ),
                    ...appState.cardChoices.map((c) => ChoiceChip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          selected: method == c,
                          onSelected: (_) => setLocal(() => method = c),
                        )),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _methodHint(method),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                appState.addSubscription(
                  title: titleCtrl.text,
                  amount: int.tryParse(amountCtrl.text) ?? 0,
                  payDay: int.tryParse(dayCtrl.text) ?? 1,
                  method: method,
                );
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // 支払い方法の説明文
  String _methodHint(String method) {
    if (method.isEmpty) return '口座から自動で引かれます（引き落とし一覧に出ます）';
    if (method == kManualPayMethod) {
      return '自分で払います。払った月に一覧から記録すると残高に反映され、その月はもう聞かれません';
    }
    return 'カードの請求に含まれます（口座からは別途引きません）';
  }

  // 既存の定期支払いの支払い方法を変更
  void _editSubscriptionMethod(AppState appState, Subscription sub) {
    String method = sub.method;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text('${sub.title} の支払い方法'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('口座振替', style: TextStyle(fontSize: 12)),
                    selected: method.isEmpty,
                    onSelected: (_) => setLocal(() => method = ''),
                  ),
                  ChoiceChip(
                    label: const Text('手動で払う', style: TextStyle(fontSize: 12)),
                    selected: method == kManualPayMethod,
                    onSelected: (_) => setLocal(() => method = kManualPayMethod),
                  ),
                  ...appState.cardChoices.map((c) => ChoiceChip(
                        label: Text(c, style: const TextStyle(fontSize: 12)),
                        selected: method == c,
                        onSelected: (_) => setLocal(() => method = c),
                      )),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _methodHint(method),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                appState.setSubscriptionMethod(sub.id, method);
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────── ATM引き出し ─────────────────────
  Widget _withdrawalList(AppState appState) {
    final list = [...appState.withdrawals]..sort((a, b) => b.date.compareTo(a.date));
    if (list.isEmpty) return _empty('引き出し履歴はありません');
    return ListView(
      children: list
          .map((w) => SwipeToDelete(
                itemKey: Key(w.id),
                onDelete: () => appState.removeWithdrawal(w.id),
                child: Card(
                  child: ListTile(
                    leading: const Icon(Icons.atm, color: Colors.brown),
                    title: Text('¥${w.amount}'),
                    subtitle: Text('${DateFormat('M/d').format(w.date)}${w.memo.isNotEmpty ? ' / ${w.memo}' : ''}'),
                  ),
                ),
              ))
          .toList(),
    );
  }

  void _addWithdrawal(AppState appState) {
    final amountCtrl = TextEditingController();
    final memoCtrl = TextEditingController();
    DateTime date = DateTime.now();
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('ATM引き出しを追加'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '金額(円)')),
              TextField(controller: memoCtrl, decoration: const InputDecoration(labelText: 'メモ')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('日付'),
                trailing: Text(DateFormat('M/d').format(date)),
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: date, firstDate: DateTime(2020), lastDate: DateTime(2030));
                  if (d != null) setLocal(() => date = d);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
            ElevatedButton(
              onPressed: () {
                appState.addWithdrawal(date: date, amount: int.tryParse(amountCtrl.text) ?? 0, memo: memoCtrl.text);
                Navigator.pop(context);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

// 支払いの出所バッジ（銀行確定/請求予定/利用/手動）
Widget _sourceBadge(PaymentSource source) {
  late final String label;
  late final Color bg;
  late final Color fg;
  switch (source) {
    case PaymentSource.bank:
      label = '銀行確定';
      bg = Colors.green.shade100;
      fg = Colors.green.shade900;
    case PaymentSource.billing:
      label = '請求予定';
      bg = Colors.red.shade100;
      fg = Colors.red.shade900;
    case PaymentSource.usage:
      label = '利用';
      bg = Colors.blue.shade100;
      fg = Colors.blue.shade900;
    case PaymentSource.manual:
      label = '手動';
      bg = Colors.grey.shade200;
      fg = Colors.grey.shade800;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
    child: Text(label, style: TextStyle(fontSize: 11, color: fg)),
  );
}
