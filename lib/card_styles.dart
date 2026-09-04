import 'package:flutter/material.dart';

// 💡 カードごとの色・アイコン（画面全体で統一）
class CardStyle {
  final Color color;
  final IconData icon;
  const CardStyle(this.color, this.icon);
}

const _defaultStyle = CardStyle(Color(0xFF9E9E9E), Icons.credit_card);

CardStyle cardStyleOf(String name) {
  if (name.contains('三井') || name.contains('OLIVE')) {
    return const CardStyle(Color(0xFF2E7D32), Icons.credit_card); // 三井OLIVE: 緑
  }
  if (name.contains('Amazon') || name.contains('アマゾン')) {
    return const CardStyle(Color(0xFFEF6C00), Icons.shopping_cart); // Amazon: オレンジ
  }
  if (name.contains('楽天')) {
    return const CardStyle(Color(0xFFC62828), Icons.credit_card); // 楽天: 赤
  }
  if (name.contains('PayPay') || name.contains('ペイペイ')) {
    return const CardStyle(Color(0xFF1565C0), Icons.credit_card); // PayPay: 青
  }
  if (name.contains('メル')) {
    return const CardStyle(Color(0xFFD81B60), Icons.credit_card); // メル: ピンク
  }
  return _defaultStyle;
}

Color cardColorOf(String name) => cardStyleOf(name).color;

// ───────────────────────── 分割払いの制約 ─────────────────────────
// 分割できる最低金額（これ未満は分割不可）
//   三井OLIVE / Amazon : 1000円以上
//   楽天 / その他      : 3000円以上
int minInstallmentAmount(String name) {
  if (name.contains('三井') || name.contains('OLIVE')) return 1000;
  if (name.contains('Amazon') || name.contains('アマゾン')) return 1000;
  return 3000; // 楽天・PayPay・メル・その他
}

// この金額で分割可能か
bool canInstallment(String name, int amount) => amount >= minInstallmentAmount(name);

// 手数料無料になる条件（Amazonカードは2・3回払いが無料）
bool isInstallmentInterestFree(String name, int count) {
  final isAmazon = name.contains('Amazon') || name.contains('アマゾン');
  return isAmazon && (count == 2 || count == 3);
}
