// 💡 色の点＋名前の凡例（カレンダーの点・グラフの色の説明に使う）。
//   以前は calendar_screen と history_screen に同じものが別々にあった。
import 'package:flutter/material.dart';

class LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  // カレンダーの下の小さい凡例（点8・文字11）か、グラフの凡例（点12・文字12）か
  final bool compact;
  const LegendDot({super.key, required this.color, required this.label, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 8.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label,
            style: compact
                ? const TextStyle(fontSize: 11, color: Colors.black54)
                : const TextStyle(fontSize: 12)),
      ],
    );
  }
}
