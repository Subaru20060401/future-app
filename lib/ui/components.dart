// 💡 用途がはっきりした共通部品だけを置く（何でも入れない）。
//   MoneyText … 金額（符号・桁区切り・色・読み上げ）
//   CertaintyBadge … 確定／見込み（文字で示す。色だけにしない）
//   StatusBanner … 状態（情報・注意・失敗）と、次に押すボタン
//   SectionCard … 見出しつきのカード
//   ⚠️ どれも計算しない。金額や状態は AppState から受け取ったものをそのまま出す。
import 'package:flutter/material.dart';

import '../finance/forecast.dart' show Certainty, CertaintyLabel;
import '../money_format.dart';
import 'tokens.dart';

/// 金額。signed: true なら +/− を付け、入金は緑・出金は赤にする（記号も付くので色だけに頼らない）。
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    this.signed = false,
    this.style = AppText.amount,
    this.color,
    this.textAlign,
  });

  final int amount;
  final bool signed;
  final TextStyle style;
  final Color? color;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final text = yen(amount, signed: signed);
    final c = color ??
        (signed
            ? (amount > 0 ? AppColors.income : (amount < 0 ? AppColors.expense : null))
            : (amount < 0 ? AppColors.warning : null));
    // 💡 読み上げでは「マイナス」「プラス」を言葉で伝える
    final spoken = yenSpoken(amount, signed: signed);
    return Semantics(
      label: spoken,
      excludeSemantics: true,
      child: Text(text, style: style.copyWith(color: c), textAlign: textAlign),
    );
  }
}

/// 確定／見込み。画面では 2 段階（登録済みの予定は「見込み」に含める）。
class CertaintyBadge extends StatelessWidget {
  const CertaintyBadge(this.certainty, {super.key});
  final Certainty certainty;

  @override
  Widget build(BuildContext context) {
    final confirmed = certainty == Certainty.confirmed;
    final color = confirmed ? AppColors.confirmed : AppColors.estimated;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
        color: confirmed ? color.withValues(alpha: 0.08) : null,
      ),
      child: Text(certainty.label,
          style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// 要確認（請求の月を判定できない銀行確定が関わる行など）。文字で示す。
class ReviewBadge extends StatelessWidget {
  const ReviewBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.cautionBg,
        border: Border.all(color: AppColors.caution),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text('要確認',
          style: TextStyle(fontSize: 12, color: AppColors.caution, fontWeight: FontWeight.w600)),
    );
  }
}

enum BannerKind { info, caution, error }

/// 状態と、次にすること。アイコン＋文で示す（色だけにしない）。
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.kind,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final BannerKind kind;
  final String message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (kind) {
      BannerKind.info => (AppColors.infoBg, AppColors.info, Icons.info_outline),
      BannerKind.caution => (AppColors.cautionBg, AppColors.caution, Icons.error_outline),
      BannerKind.error => (AppColors.warningBg, AppColors.warning, Icons.warning_amber),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      padding: const EdgeInsets.fromLTRB(AppSpace.m, AppSpace.s, AppSpace.s, AppSpace.s),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: AppSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: AppText.body.copyWith(color: fg, fontWeight: FontWeight.w600)),
                if (detail != null) Text(detail!, style: AppText.caption.copyWith(color: fg)),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: fg,
                minimumSize: const Size(AppSpace.minTap, AppSpace.minTap),
              ),
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// 見出しつきのカード
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.l, AppSpace.m, AppSpace.l, AppSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: AppColors.brandDeep),
                  const SizedBox(width: AppSpace.s),
                ],
                Expanded(
                  child: Semantics(header: true, child: Text(title, style: AppText.title)),
                ),
                ?trailing,
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, style: AppText.caption),
              ),
            const SizedBox(height: AppSpace.s),
            child,
          ],
        ),
      ),
    );
  }
}
