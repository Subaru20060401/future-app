import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

// 左スワイプで「削除」ボタンを出し、タップで削除する2段階のラッパー（誤削除防止）。
//   右スワイプでは削除されず、ボタンのタップが必要なので、ポケットから取り出すときの
//   誤操作で消える事故を防げる。
class SwipeToDelete extends StatelessWidget {
  final Key itemKey;
  final VoidCallback onDelete;
  final String label;
  final Widget child;
  const SwipeToDelete({
    super.key,
    required this.itemKey,
    required this.onDelete,
    required this.child,
    this.label = '削除',
  });

  @override
  Widget build(BuildContext context) {
    return Slidable(
      key: itemKey,
      groupTag: 'delete', // 1つ開くと他は閉じる
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.28,
        children: [
          SlidableAction(
            onPressed: (_) => onDelete(),
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            icon: Icons.delete,
            label: label,
            borderRadius: BorderRadius.circular(12),
          ),
        ],
      ),
      child: child,
    );
  }
}
