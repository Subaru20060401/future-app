// 💡 金額が変わったときに、何が変わったかが分かるように短く動かす。
//   （計画書の段階1「金額更新のモーション」）
//   ・旧金額 → 新金額へ 250ms で切り替え、差額「今回の更新 −¥3000」を数秒だけ添える
//   ・最初に表示したときは動かさない（0円から数え上げない）
//   ・金額が同じなら何もしない。続けて変わったら、差額はまとめて出す
//   ・OSの「視差効果を減らす」等が有効なら動かさず、すぐ最終値にする
// ⚠️ 表示だけのもの。警告やお金の計算には、ここの途中の値を一切使わないこと
//   （判定は常に AppState の最終値で行う）。
import 'dart:async';

import 'package:flutter/material.dart';

class AnimatedAmount extends StatefulWidget {
  const AnimatedAmount({
    super.key,
    required this.value,
    required this.style,
    this.prefix = '¥ ',
    this.showDelta = true,
    this.duration = const Duration(milliseconds: 250),
    this.deltaVisibleFor = const Duration(seconds: 4),
    this.alignment = CrossAxisAlignment.end,
  });

  final int value;
  final TextStyle style;
  final String prefix;
  final bool showDelta;
  final Duration duration;
  final Duration deltaVisibleFor;
  final CrossAxisAlignment alignment; // 差額を金額の下のどこに寄せるか

  @override
  State<AnimatedAmount> createState() => _AnimatedAmountState();
}

class _AnimatedAmountState extends State<AnimatedAmount>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.duration);
  late int _from = widget.value;
  late int _to = widget.value;
  // 差額の起点（続けて変わったときは、最初の変化の前の値から数える）
  int? _deltaBase;
  Timer? _deltaTimer;

  @override
  void didUpdateWidget(covariant AnimatedAmount old) {
    super.didUpdateWidget(old);
    if (widget.value == _to) return; // 同じ金額なら動かさない
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // いま画面に出ている値から動かし始める（途中で変わってもガクッと戻らない）
    _from = _displayed;
    _to = widget.value;
    _deltaBase ??= old.value;
    _deltaTimer?.cancel();
    _deltaTimer = Timer(widget.deltaVisibleFor, () {
      if (mounted) setState(() => _deltaBase = null);
    });
    if (reduceMotion) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  int get _displayed {
    if (_from == _to) return _to;
    final t = Curves.easeOutCubic.transform(_c.value);
    return (_from + (_to - _from) * t).round();
  }

  @override
  void dispose() {
    _deltaTimer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = _deltaBase;
    final delta = base == null ? 0 : widget.value - base;
    // 数字の横幅を揃えて、桁が変わっても文字が左右に揺れないようにする
    final style = widget.style.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      // 読み上げは最終の金額を一度だけ
      label: '${widget.prefix}${widget.value}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: widget.alignment,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Text('${widget.prefix}$_displayed', style: style),
          ),
          if (widget.showDelta && delta != 0)
            Text(
              // 💡 理由までは分からないので「今回の更新」とだけ言う（カード利用分などと断定しない）
              '今回の更新 ${delta > 0 ? '+' : '−'}¥${delta.abs()}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: delta > 0 ? Colors.green[700] : Colors.red[700],
              ),
            ),
        ],
      ),
    );
  }
}
