// 💡 見た目の共通の決まり（色・文字・余白）。画面ごとに Colors.red や fontSize: 11 を直接書かず、ここを使う。
//   ・ブランドのピンク（ポケットメイド）は main.dart の ColorScheme（seed: pink）のまま
//   ・意味の色は「名前」で持つ。⚠️ 色だけで区別しない（金額は +/− と言葉、状態は「確定」「見込み」の文字を必ず添える）
//   ・文字は本文 14・補足 12 を下限にする（以前は 10〜11 の箇所があった）
//   ・押せる部分は 48×48 以上
import 'package:flutter/material.dart';

class AppColors {
  AppColors._();
  static const Color brand = Color(0xFFE91E63); // Colors.pink
  static const Color brandDeep = Color(0xFFAD1457);
  static const Color income = Color(0xFF2E7D32); // 入金（緑 800：白背景でコントラスト比 4.5 以上）
  static const Color expense = Color(0xFFC62828); // 出金（赤 800）
  static const Color warning = Color(0xFFB71C1C); // 足りない・失敗
  static const Color warningBg = Color(0xFFFFEBEE);
  static const Color caution = Color(0xFF8D4E00); // 注意（橙系の文字。背景との比 4.5 以上）
  static const Color cautionBg = Color(0xFFFFF3E0);
  static const Color info = Color(0xFF37474F);
  static const Color infoBg = Color(0xFFECEFF1);
  static const Color confirmed = Color(0xFF1565C0); // 確定（青 800）
  static const Color estimated = Color(0xFF616161); // 見込み（灰 700）
  static const Color subtle = Color(0xFF5F6368); // 補足の文字（白背景で 4.5 以上）
  static const Color surface = Color(0xD9FFFFFF); // カードの白（少し透ける）
}

class AppSpace {
  AppSpace._();
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double minTap = 48;
  static const double radius = 18;
}

class AppText {
  AppText._();
  static const TextStyle title = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);
  static const TextStyle body = TextStyle(fontSize: 14);
  static const TextStyle caption = TextStyle(fontSize: 12, color: AppColors.subtle);
  static const TextStyle amountHero = TextStyle(fontSize: 36, fontWeight: FontWeight.bold);
  static const TextStyle amountLarge = TextStyle(fontSize: 22, fontWeight: FontWeight.bold);
  static const TextStyle amount = TextStyle(fontSize: 16, fontWeight: FontWeight.bold);
}

/// PC など広い画面で 2 列にする幅
const double kWideLayoutWidth = 840;
