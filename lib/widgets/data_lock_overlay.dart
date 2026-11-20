// 💡 取り込み中（ドライブ・バックアップ・貼り付け）は、画面全体を覆って操作できなくする。
//   ⚠️ 取り込みの途中で受け付けた変更は、取り込みが失敗して元に戻すときに一緒に消える。
//     「入力できたのに消えた」にしないため、そもそも入力させない（AppState 側でも断る）。
//   成功・失敗のどちらでも、AppState が鍵を外すとこの覆いは消えて、そのまま操作できるようになる。
// ⚠️ MaterialApp.builder の中で使うので context.watch しない（Selector で鍵の状態だけを見る）。
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../ui/tokens.dart';

class DataLockOverlay extends StatelessWidget {
  const DataLockOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, String?>(
      selector: (_, app) => app.dataLockLabel,
      child: child,
      builder: (context, label, inner) => Stack(
        children: [
          inner!,
          if (label != null) Positioned.fill(child: _LockedCover(label: label)),
        ],
      ),
    );
  }
}

class _LockedCover extends StatelessWidget {
  const _LockedCover({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 💡 下の画面のボタン・入力欄（開いていたダイアログも含む）へ触れられないようにする
        const ModalBarrier(dismissible: false, color: Color(0x66000000)),
        BlockSemantics(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Material(
                key: const Key('data-lock-cover'),
                borderRadius: BorderRadius.circular(16),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.l),
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: AppSpace.m),
                        Text('$label…',
                            style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                            textAlign: TextAlign.center),
                        const SizedBox(height: AppSpace.xs),
                        Text('入力した内容が消えないように、終わるまで操作を止めています',
                            style: AppText.caption, textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
