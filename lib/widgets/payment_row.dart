// 💡 支払い管理の明細1行（UI改善計画 2026-10-14 の段階1）。
//   以前は ListTile の右側に「金額・カード変更・分割・支払済み」を横並びにしていたため、
//   狭い画面ではカード名や日時が1〜2文字幅の縦書き状態になっていた。
//   本文（カード名・種別と日時・利用先・状態）と、金額・操作を分ける。
//   ・操作は「︙」にまとめ、名前付きで出す（アイコンだけで意味を当てさせない）
//   ・狭い幅や文字拡大のときは、金額を下段に移す（文字を小さくして詰め込まない）
// ⚠️ 表示だけのもの。金額の集計・計上の判定はしない（AppState の結果を使う）。
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_state.dart';
import '../card_styles.dart';

final _yen = NumberFormat.decimalPattern('ja');

// 金額の表記をそろえる（桁区切り・マイナス）
String formatYen(int amount) =>
    amount < 0 ? '−¥${_yen.format(-amount)}' : '¥${_yen.format(amount)}';

String paymentSourceLabel(PaymentSource s) => switch (s) {
      PaymentSource.bank => '引落確定',
      PaymentSource.billing => '請求予定',
      PaymentSource.usage => '利用',
      PaymentSource.manual => '手動',
    };

// 利用通知は利用日時（時刻があれば）、それ以外は支払日
String paymentDateLabel(Payment p) {
  final d = p.paymentDate;
  if (p.source == PaymentSource.usage && (d.hour != 0 || d.minute != 0)) {
    return DateFormat('M/d HH:mm').format(d);
  }
  return DateFormat('M/d').format(d);
}

// 💡 明細の状態を文字で表す（色や取り消し線だけで伝えない）
String? paymentStatusLabel(Payment p) {
  if (p.infoOnly) return '記録のみ';
  if (p.paid) return '支払済み';
  return null;
}

// 明細に対してできる操作（対象外のものは null にして出さない）
class PaymentActions {
  const PaymentActions({
    required this.onEditNote,
    required this.onTogglePaid,
    required this.onDelete,
    this.onMoveCard,
    this.onInstallment,
  });

  final VoidCallback onEditNote;
  final VoidCallback onTogglePaid;
  final VoidCallback onDelete;
  final VoidCallback? onMoveCard; // Amazonの明細だけ
  final VoidCallback? onInstallment; // 分割できる金額・カードだけ
}

class PaymentRow extends StatelessWidget {
  const PaymentRow({
    super.key,
    required this.payment,
    required this.actions,
    required this.onTap,
  });

  final Payment payment;
  final PaymentActions actions;
  final VoidCallback onTap;

  // 💡 この幅より狭いか、文字を大きくしているときは金額を下段に回す
  static const double narrowWidth = 340;

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final style = cardStyleOf(p.cardName);
    final status = paymentStatusLabel(p);
    final muted = p.infoOnly || p.paid;
    final amountStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: muted ? Colors.black45 : Colors.red[700],
      decoration: muted ? TextDecoration.lineThrough : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final amountLabel = formatYen(p.amount);
    final amountText = Text(amountLabel, maxLines: 1, softWrap: false, style: amountStyle);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: LayoutBuilder(builder: (context, constraints) {
          final scaler = MediaQuery.textScalerOf(context);
          final scale = scaler.scale(14) / 14;
          // 💡 金額を1行目に置くと、カード名がどれだけ残るかを実際の文字幅で測って決める。
          //   7桁の金額や長いカード名でも、カード名に半分以上の幅を残せないなら下段へ。
          //   （幅の固定値だけで決めると、360〜390pxで名前が数文字幅まで潰れていた）
          final amountWidth = (TextPainter(
            text: TextSpan(text: amountLabel, style: amountStyle),
            textDirection: Directionality.of(context),
            textScaler: scaler,
            maxLines: 1,
          )..layout())
              .width;
          // 左右の余白(16)・アイコン(32)・操作ボタン(48) を除いた本文の幅
          final bodyWidth = constraints.maxWidth - 16 - 32 - 48;
          final narrow = constraints.maxWidth < narrowWidth ||
              scale > 1.3 ||
              amountWidth + 8 > bodyWidth * 0.45;
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(style.icon, color: style.color, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // カード名（1行目）。広い幅なら金額を同じ行の右に置く
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              p.cardName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (!narrow) ...[
                            const SizedBox(width: 8),
                            amountText,
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${paymentSourceLabel(p.source)} · ${paymentDateLabel(p)}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.infoOnly
                            ? '他のカードで計上済み'
                            : (p.note.isEmpty ? '利用先未入力' : p.note),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: (p.note.isEmpty || p.infoOnly)
                              ? Colors.black38
                              : Colors.black87,
                        ),
                      ),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: _StatusChip(label: status),
                        ),
                      // 下段の金額は1行を丸ごと使う。それでも入らないほど文字が大きいときだけ
                      // 縮めて全桁を見せる（省略記号や途中改行はしない）
                      if (narrow)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(fit: BoxFit.scaleDown, child: amountText),
                          ),
                        ),
                    ],
                  ),
                ),
                _PaymentMenu(payment: p, actions: actions),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
    );
  }
}

enum _Action { note, move, installment, paid, delete }

class _PaymentMenu extends StatelessWidget {
  const _PaymentMenu({required this.payment, required this.actions});
  final Payment payment;
  final PaymentActions actions;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Action>(
      tooltip: '操作',
      icon: const Icon(Icons.more_vert),
      onSelected: (a) {
        switch (a) {
          case _Action.note:
            actions.onEditNote();
          case _Action.move:
            actions.onMoveCard?.call();
          case _Action.installment:
            actions.onInstallment?.call();
          case _Action.paid:
            actions.onTogglePaid();
          case _Action.delete:
            actions.onDelete();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: _Action.note, child: Text('利用先を編集')),
        if (actions.onMoveCard != null)
          const PopupMenuItem(value: _Action.move, child: Text('支払いカードを変更')),
        if (actions.onInstallment != null)
          const PopupMenuItem(value: _Action.installment, child: Text('分割払いへ変更')),
        PopupMenuItem(
          value: _Action.paid,
          child: Text(payment.paid ? '未払いに戻す' : '支払済みにする'),
        ),
        const PopupMenuItem(
          value: _Action.delete,
          child: Text('削除（ゴミ箱へ）', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }
}
