// 💡 色の印＋名前の凡例（カレンダーの印・グラフの色の説明に使う）。
//   以前は calendar_screen と history_screen に同じものが別々にあった。
//   ⚠️ 色だけで区別しないよう、カレンダーの印は形も変える（MarkShape）。凡例も同じ形で出す。
import 'package:flutter/material.dart';

/// 印の形（カレンダー: シフト＝●、給料日・予定入金＝▲、引き落とし＝■、予定＝◆）
enum MarkShape { circle, triangle, square, diamond }

/// 小さな印（色＋形）
class Mark extends StatelessWidget {
  const Mark({super.key, required this.color, this.shape = MarkShape.circle, this.size = 6});
  final Color color;
  final MarkShape shape;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MarkPainter(color, shape)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color, this.shape);
  final Color color;
  final MarkShape shape;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = color;
    final w = s.width, h = s.height;
    switch (shape) {
      case MarkShape.circle:
        canvas.drawCircle(Offset(w / 2, h / 2), w / 2, p);
      case MarkShape.square:
        canvas.drawRect(Rect.fromLTWH(0, 0, w, h), p);
      case MarkShape.triangle:
        canvas.drawPath(
            Path()
              ..moveTo(w / 2, 0)
              ..lineTo(w, h)
              ..lineTo(0, h)
              ..close(),
            p);
      case MarkShape.diamond:
        canvas.drawPath(
            Path()
              ..moveTo(w / 2, 0)
              ..lineTo(w, h / 2)
              ..lineTo(w / 2, h)
              ..lineTo(0, h / 2)
              ..close(),
            p);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color || old.shape != shape;
}

class LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final MarkShape shape;
  // カレンダーの下の小さい凡例（印8・文字12）か、グラフの凡例（印12・文字12）か
  final bool compact;
  const LegendDot({
    super.key,
    required this.color,
    required this.label,
    this.compact = false,
    this.shape = MarkShape.circle,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 8.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Mark(color: color, shape: shape, size: size),
        const SizedBox(width: 4),
        Text(label,
            style: compact
                ? const TextStyle(fontSize: 12, color: Colors.black54)
                : const TextStyle(fontSize: 12)),
      ],
    );
  }
}
