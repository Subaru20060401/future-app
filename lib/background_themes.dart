import 'package:flutter/material.dart';

// アプリ背景のグラデーションテーマ。設定で切り替え可能。
class BackgroundTheme {
  final String key;
  final String label;
  final List<Color> colors; // 上→下のグラデーション
  const BackgroundTheme(this.key, this.label, this.colors);
}

const List<BackgroundTheme> kBackgroundThemes = [
  BackgroundTheme('pink', 'ピンク', [Color(0xFFFCE4EC), Color(0xFFF3E9FB), Color(0xFFE8F1FF)]),
  BackgroundTheme('mint', 'ミント', [Color(0xFFE3F9F0), Color(0xFFE6F4FB), Color(0xFFEAF7E9)]),
  BackgroundTheme('lavender', 'ラベンダー', [Color(0xFFEDE7F6), Color(0xFFF3E5F5), Color(0xFFE8EAF6)]),
  BackgroundTheme('sky', 'スカイ', [Color(0xFFE1F5FE), Color(0xFFE8F1FF), Color(0xFFF3F8FF)]),
  BackgroundTheme('peach', 'ピーチ', [Color(0xFFFFF3E0), Color(0xFFFFEBEE), Color(0xFFFFF8E1)]),
  BackgroundTheme('lemon', 'レモン', [Color(0xFFFFFDE7), Color(0xFFF9FBE7), Color(0xFFF1F8E9)]),
  BackgroundTheme('gray', 'グレー', [Color(0xFFF5F5F7), Color(0xFFECEFF1), Color(0xFFF5F5F7)]),
  BackgroundTheme('night', 'ナイト', [Color(0xFF2B2540), Color(0xFF3A3357), Color(0xFF241F38)]),
];

BackgroundTheme backgroundThemeByKey(String key) =>
    kBackgroundThemes.firstWhere((t) => t.key == key, orElse: () => kBackgroundThemes.first);
