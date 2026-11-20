// 💡 「何年何月」を選ぶ欄（定期支払いの開始月など）。◀ ▶ で 1 か月ずつ動かし、
//   タップで年と月を選べる。allowUnset のときは「未設定」にも戻せる（以前の版のデータ用）。
//   ⚠️ 計算はしない。選んだ月（その月の 1 日）を返すだけ。
import 'package:flutter/material.dart';

import '../ui/tokens.dart';

String yearMonthLabel(DateTime? m) => m == null ? '未設定' : '${m.year}年${m.month}月';

class MonthPickerField extends StatelessWidget {
  const MonthPickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.allowUnset = false,
    this.unsetHint = '',
    this.fallback,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool allowUnset;
  final String unsetHint;
  // 未設定から ◀ ▶ を押したときの出発点（今月など）
  final DateTime? fallback;

  DateTime get _base => value ?? fallback ?? DateTime(2026, 1);

  void _shift(int months) {
    final b = _base;
    onChanged(DateTime(b.year, b.month + months));
  }

  Future<void> _pick(BuildContext context) async {
    final b = _base;
    var year = b.year;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: '前の年',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setLocal(() => year--),
              ),
              Text('$year年'),
              IconButton(
                tooltip: '次の年',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setLocal(() => year++),
              ),
            ],
          ),
          content: SizedBox(
            width: 280,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var m = 1; m <= 12; m++)
                  ChoiceChip(
                    label: Text('$m月'),
                    selected: value != null && value!.year == year && value!.month == m,
                    onSelected: (_) => Navigator.pop(context, DateTime(year, m)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ],
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.subtle)),
        Row(
          children: [
            IconButton(
              tooltip: '1か月前',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _shift(-1),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => _pick(context),
                child: Text(yearMonthLabel(value),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            IconButton(
              tooltip: '1か月後',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _shift(1),
            ),
          ],
        ),
        if (allowUnset && value != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => onChanged(null),
              child: const Text('未設定に戻す', style: TextStyle(fontSize: 12)),
            ),
          ),
        if (value == null && unsetHint.isNotEmpty)
          Text(unsetHint, style: const TextStyle(fontSize: 12, color: AppColors.subtle)),
      ],
    );
  }
}
