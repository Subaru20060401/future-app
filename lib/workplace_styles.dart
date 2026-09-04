import 'package:flutter/material.dart';

// 勤務先の表示色パレット（名前付き）。編集画面の色選択と自動採番に使う。
class WorkplaceColor {
  final String name;
  final Color color;
  const WorkplaceColor(this.name, this.color);
}

const List<WorkplaceColor> workplaceColorOptions = [
  WorkplaceColor('ブルー', Color(0xFF42A5F5)),
  WorkplaceColor('グリーン', Color(0xFF66BB6A)),
  WorkplaceColor('オレンジ', Color(0xFFFFA726)),
  WorkplaceColor('レッド', Color(0xFFEF5350)),
  WorkplaceColor('ピンク', Color(0xFFEC407A)),
  WorkplaceColor('パープル', Color(0xFFAB47BC)),
  WorkplaceColor('ティール', Color(0xFF26A69A)),
  WorkplaceColor('ブラウン', Color(0xFF8D6E63)),
];

// app_state からも参照する色だけのリスト（自動採番用）
final List<Color> workplaceColorPalette =
    workplaceColorOptions.map((e) => e.color).toList();

// ARGB値に最も近い登録色の名前を返す（編集画面の表示用）。無ければ「カスタム」。
String workplaceColorName(int value) {
  for (final o in workplaceColorOptions) {
    if (o.color.toARGB32() == value) return o.name;
  }
  return 'カスタム';
}

// ジャンルのプリセット（情報用・計算に影響なし）
const List<String> workplaceGenres = [
  '飲食',
  'コンビニ・スーパー',
  '家電・雑貨・他販売',
  'アパレル',
  '物流・倉庫',
  'オフィス・事務',
  '教育・塾',
  '医療・介護',
  'イベント・単発',
  'その他',
];
