import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../app_state.dart';
import '../build_info.dart';
import '../download_file.dart';
import '../drive_sync.dart';
import '../widgets/drive_sync_dialog.dart';
import '../widgets/google_account_tile.dart';
import '../widgets/passcode_settings.dart';
import '../background_themes.dart';
import '../notification_service.dart';
import '../gmail_service.dart';
import '../gmail_sync.dart';
import 'gmail_screen.dart';
import 'card_settings_screen.dart';
import 'workplace_list_screen.dart';
import 'budget_screen.dart';
import '../widgets/app_sheet.dart';
import '../card_styles.dart';
import '../google_calendar_sync.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  // 🔧 デバッグ情報をダイアログ表示（パーサー調整用）
  Future<void> _showDebug(BuildContext context, String title, Future<String> Function() load) async {
    showDialog(
      context: context,
      builder: (_) => const AlertDialog(content: Center(child: Padding(
        padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
    );
    final raw = await load();
    if (!context.mounted) return;
    Navigator.pop(context); // ローディングを閉じる
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(raw)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: raw));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('コピーしました')));
            },
            child: const Text('コピー'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
        ],
      ),
    );
  }

  String _fmtDt(DateTime dt) => DateFormat('M/d HH:mm').format(dt);

  // 背景色（グラデーション）を選ぶ
  void _showBackgroundPicker(BuildContext context, AppState appState) {
    showAppSheet(context, (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('アプリの背景色', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.8,
                children: kBackgroundThemes.map((t) {
                  final selected = t.key == appState.backgroundTheme;
                  return GestureDetector(
                    onTap: () {
                      appState.setBackgroundTheme(t.key);
                      Navigator.pop(context);
                    },
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: t.colors,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected ? Colors.pink : Colors.grey.shade300,
                              width: selected ? 3 : 1,
                            ),
                          ),
                          child: selected
                              ? const Icon(Icons.check, color: Colors.pink)
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(t.label, style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCardPaymentDaySettings(BuildContext context, AppState appState) {
    showAppSheet(context, (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('カードの締め日・引き落とし日',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                  '締め日＝どこまでの利用が次の引き落としに入るか。'
                  '引き落とし日＝毎月何日に口座から引かれるか。\n'
                  '月末締めなら「前月1日〜前月末日」の利用が当月の引き落としになります。'
                  '15日締めなら「前々月16日〜前月15日」ぶんです'
                  '（銀行の事前お知らせメールが届いている場合は、そちらの金額を優先）。',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 12),
              ...appState.cardPaymentDays.entries.map((e) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.credit_card, size: 20, color: Colors.red),
                title: Text(e.key),
                subtitle: Text(
                  '${appState.closingLabelOf(e.key)} → 毎月${e.value}日 引き落とし',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      child: const Text('変更', style: TextStyle(fontSize: 15)),
                      onPressed: () async {
                        await _editCardDays(context, appState, e.key);
                        setLocal(() {});
                      },
                    ),
                    IconButton(
                      tooltip: '一覧から外す',
                      icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                      onPressed: () async {
                        final ok = await _confirm(context, '${e.key} を外す',
                            'カードの一覧から外します。登録済みの明細は消えません。');
                        if (ok != true) return;
                        appState.removeCard(e.key);
                        setLocal(() {});
                      },
                    ),
                  ],
                ),
              )),
              // 💡 銀行の引落確定メールは請求元の表記でカード名をよこすため、
              //   自分が付けた名前と食い違って同じカードが2つに割れる。
              //   割れている候補をここに出して、1つにまとめられるようにする。
              if (appState.unregisteredCardNames.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('登録していないカード名',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 2),
                const Text(
                    '銀行やカード会社のメールから、この名前で明細が入っています。'
                    '上のカードと同じものなら、まとめると1枚として扱えます。',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 6),
                ...appState.unregisteredCardNames.map((u) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.help_outline,
                          size: 20, color: Colors.orange),
                      title: Text(u.name),
                      subtitle: Text('明細 ${u.count}件',
                          style: const TextStyle(fontSize: 12)),
                      trailing: TextButton(
                        child: const Text('まとめる'),
                        onPressed: () async {
                          final to = await _pickCardToMerge(context, appState, u.name);
                          if (to == null) return;
                          appState.mergeCardName(u.name, to);
                          setLocal(() {});
                        },
                      ),
                    )),
              ],
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add, color: Colors.blue),
                title: const Text('カードを追加'),
                onTap: () async {
                  final nameCtrl = TextEditingController();
                  final closeCtrl = TextEditingController(text: '31');
                  final dayCtrl = TextEditingController(text: '27');
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('カードを追加'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'カード名')),
                          TextField(controller: closeCtrl, keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: '締め日（31＝月末締め）', suffixText: '日')),
                          TextField(controller: dayCtrl, keyboardType: TextInputType.number,
                              decoration: const InputDecoration(labelText: '引き落とし日', suffixText: '日')),
                        ],
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('追加')),
                      ],
                    ),
                  );
                  if (ok == true && nameCtrl.text.isNotEmpty) {
                    final day = int.tryParse(dayCtrl.text) ?? 27;
                    appState.setCardPaymentDay(nameCtrl.text, day.clamp(1, 31));
                    appState.setCardClosingDay(
                        nameCtrl.text, int.tryParse(closeCtrl.text) ?? 31);
                    setLocal(() {});
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // どのカードにまとめるか選ぶ
  Future<String?> _pickCardToMerge(
      BuildContext context, AppState appState, String from) {
    final cards = appState.cardPaymentDays.keys.toList();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('「$from」をまとめる'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('同じカードを選んでください。既存の明細もまとめ先に付け替わり、'
                '次回以降の取り込みでも同じ扱いになります。',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            ...cards.map((c) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(cardStyleOf(c).icon, color: cardStyleOf(c).color),
                  title: Text(c),
                  onTap: () => Navigator.pop(context, c),
                )),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
        ],
      ),
    );
  }

  // 💡 カード1枚の「締め日」と「引き落とし日」をまとめて編集する。
  //   締め日は 31＝月末締め。引き落とし日が土日祝なら翌営業日にずれる（表示側で調整）。
  Future<void> _editCardDays(
      BuildContext context, AppState appState, String card) async {
    final closeCtrl =
        TextEditingController(text: appState.closingDayOf(card).toString());
    final dayCtrl =
        TextEditingController(text: (appState.cardPaymentDays[card] ?? 27).toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(card),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: closeCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '締め日（1〜31、31＝月末締め）',
                suffixText: '日',
                helperText: 'ここまでの利用が次の引き落としに入ります',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: dayCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '引き落とし日（1〜31）',
                suffixText: '日',
                helperText: '土日祝なら翌営業日にずれます',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    appState.setCardClosingDay(
        card, int.tryParse(closeCtrl.text) ?? appState.closingDayOf(card));
    appState.setCardPaymentDay(
        card,
        (int.tryParse(dayCtrl.text) ?? appState.cardPaymentDays[card] ?? 27)
            .clamp(1, 31));
  }

  // 取り返しがつかない操作の確認
  Future<bool?> _confirm(BuildContext context, String title, String body) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('実行する'),
          ),
        ],
      ),
    );
  }

  // バックアップから復元（自動保存ファイル一覧）
  Future<void> _showRestoreBackup(BuildContext context, AppState appState) async {
    final files = await appState.listBackupFiles();
    if (!context.mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('バックアップファイルがありません')),
      );
      return;
    }
    showAppSheet(context, (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('バックアップから復元', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(
              shrinkWrap: true,
              children: files.map((f) {
                final name = f.path.split('/').last;
                final dtStr = name.replaceAll('pocket_maid_', '').replaceAll('.json', '');
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file, color: Colors.teal),
                  title: Text(dtStr.length >= 15
                      ? '${dtStr.substring(0, 4)}/${dtStr.substring(4, 6)}/${dtStr.substring(6, 8)} ${dtStr.substring(9, 11)}:${dtStr.substring(11, 13)}'
                      : name),
                  trailing: TextButton(
                    child: const Text('復元', style: TextStyle(color: Colors.red)),
                    onPressed: () async {
                      Navigator.pop(context);
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('復元の確認'),
                          content: const Text('このバックアップで現在のデータをすべて上書きします。続けますか？'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('復元する'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true && context.mounted) {
                        try {
                          await appState.restoreFromBackup(f);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('復元しました')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('復元失敗: $e')),
                            );
                          }
                        }
                      }
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // バックアップ（エクスポート/インポート）のメニュー
  void _showBackup(BuildContext context, AppState appState) {
    showAppSheet(context, (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('データのバックアップ', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          // 💡 Web版はブラウザの中にしか保存されない（端末をまたがない）ので、
          //   「別の端末で開いたらデータが無い」を先に説明しておく。
          if (kIsWeb)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Web版のデータは、この端末のこのブラウザにだけ保存されます。'
                '別の端末（iPhoneなど）で使うには、ここでJSONを書き出して、'
                'その端末の「ファイルから読み込み」で取り込んでください。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.ios_share, color: Colors.green),
            title: const Text('ファイルに書き出し（JSON）'),
            subtitle: const Text('ファイルとして保存・共有'),
            onTap: () {
              Navigator.pop(context);
              _exportToFile(context, appState, 'pocket_maid_backup', 'json', appState.exportJson());
            },
          ),
          ListTile(
            leading: const Icon(Icons.grid_on, color: Colors.teal),
            title: const Text('シフトをCSVファイルに書き出し'),
            onTap: () {
              Navigator.pop(context);
              _exportToFile(context, appState, 'pocket_maid_shifts', 'csv', appState.exportShiftsCsv());
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_open, color: Colors.blue),
            title: const Text('ファイルから読み込み（JSON）'),
            subtitle: const Text('保存したJSONファイルを選んで復元'),
            onTap: () {
              Navigator.pop(context);
              _importFromFile(context, appState);
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file, color: Colors.indigo),
            title: const Text('シフトをCSVから読み込み'),
            subtitle: const Text('別の端末で書き出したシフトCSVを取り込む'),
            onTap: () {
              Navigator.pop(context);
              _importShiftsCsvFromFile(context, appState);
            },
          ),
          const Divider(),
          ListTile(
            dense: true,
            leading: const Icon(Icons.content_paste, color: Colors.grey),
            title: const Text('コピー/貼り付けで入出力'),
            subtitle: const Text('テキストでエクスポート・インポート'),
            onTap: () {
              Navigator.pop(context);
              _showTextBackup(context, appState);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // #1 ファイルに書き出して共有（保存）シートを開く
  Future<void> _exportToFile(BuildContext context, AppState appState,
      String baseName, String ext, String content) async {
    try {
      final ts = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      if (kIsWeb) {
        // 💡 Webは端末にファイルを書けないので、ブラウザのダウンロードで保存させる。
        //   （別の端末へ持っていくのにコピペは現実的でない）
        final name = '${baseName}_$ts.$ext';
        final mime = ext == 'csv' ? 'text/csv' : 'application/json';
        if (downloadTextFile(name, content, mime)) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('$name を保存しました')));
          }
        } else if (context.mounted) {
          // ダウンロードできない環境ではコピーできるテキストで出す
          _showText(context, 'エクスポート', content);
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${baseName}_$ts.$ext');
      await file.writeAsString(content);
      // iOS/iPad の共有シートは元の位置(sharePositionOrigin)が必須。画面の矩形を渡す。
      final box = context.findRenderObject() as RenderBox?;
      final origin = (box != null && box.hasSize)
          ? (box.localToGlobal(Offset.zero) & box.size)
          : const Rect.fromLTWH(0, 0, 1, 1);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'ポケットメイド バックアップ',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('書き出し失敗: $e')));
      }
    }
  }

  // #1 ファイルを選んで読み込み（JSON）
  Future<void> _importFromFile(BuildContext context, AppState appState) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null) return;
      final picked = result.files.single;
      // Webは path が取れないのでバイト列から読む
      final String text;
      if (picked.bytes != null) {
        text = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        text = await File(picked.path!).readAsString();
      } else {
        return;
      }
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('インポートの確認'),
          content: const Text('このファイルで現在のデータをすべて上書きします。続けますか？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取り込む（全置換）'),
            ),
          ],
        ),
      );
      if (ok == true) {
        appState.importJson(text);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('インポートしました')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('読み込み失敗: $e')));
      }
    }
  }

  // シフトCSVを選んで読み込み（勤務先/給与の設定はCSVの給与列から逆算して復元）
  Future<void> _importShiftsCsvFromFile(BuildContext context, AppState appState) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (result == null) return;
      final picked = result.files.single;
      // Webは path が取れないのでバイト列から読む
      final String text;
      if (picked.bytes != null) {
        text = utf8.decode(picked.bytes!);
      } else if (picked.path != null) {
        text = await File(picked.path!).readAsString();
      } else {
        return;
      }
      if (!context.mounted) return;
      final mode = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('シフトCSVの取り込み'),
          content: const Text(
            'CSVにはシフトだけが入っています（支払い・残高・設定は含まれません）。\n'
            '取り込み方を選んでください。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'merge'),
              child: const Text('追加（重複はスキップ）'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(context, 'replace'),
              child: const Text('シフトを全置換'),
            ),
          ],
        ),
      );
      if (mode == null) return;
      final r = appState.importShiftsCsv(text, replace: mode == 'replace');
      if (!context.mounted) return;
      final parts = <String>['${r.imported}件を取り込みました'];
      if (r.skipped > 0) parts.add('重複${r.skipped}件をスキップ');
      if (r.failed > 0) parts.add('${r.failed}行は読めませんでした');
      if (r.mismatched > 0) parts.add('${r.mismatched}件は給与を再現できず再計算');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(parts.join(' / '))));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('読み込み失敗: $e')));
      }
    }
  }

  // コピー/貼り付け方式（従来）のメニュー
  void _showTextBackup(BuildContext context, AppState appState) {
    showAppSheet(context, (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('コピー/貼り付けで入出力', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file, color: Colors.green),
            title: const Text('エクスポート（JSON・コピー）'),
            onTap: () {
              Navigator.pop(context);
              _showText(context, 'エクスポート（JSON）', appState.exportJson());
            },
          ),
          ListTile(
            leading: const Icon(Icons.download, color: Colors.blue),
            title: const Text('インポート（JSON・貼り付け）'),
            onTap: () {
              Navigator.pop(context);
              _showImport(context, appState);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  // テキストをコピー可能に表示
  void _showText(BuildContext context, String title, String text) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('コピーしました')));
            },
            child: const Text('コピー'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('閉じる')),
        ],
      ),
    );
  }

  // JSONを貼り付けてインポート
  void _showImport(BuildContext context, AppState appState) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('インポート（JSON）'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), hintText: 'エクスポートしたJSONを貼り付け'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          ElevatedButton(
            onPressed: () {
              try {
                appState.importJson(ctrl.text);
                Navigator.pop(context);
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('インポートしました')));
              } catch (e) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('読み込み失敗: $e')));
              }
            },
            child: const Text('取り込む（全置換）'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
      ),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.work, color: Colors.blue),
            title: const Text('勤務先の管理'),
            subtitle: const Text('バイト先・時給・交通費・各種手当の登録'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WorkplaceListScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.credit_card, color: Colors.red),
            title: const Text('カードの締め日・引き落とし日'),
            subtitle: const Text('カレンダー表示と、引き落としのお知らせに使います'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showCardPaymentDaySettings(context, appState),
          ),
          ListTile(
            leading: const Icon(Icons.savings, color: Colors.teal),
            title: const Text('予算の設定'),
            subtitle: const Text('カテゴリ別の月予算と超過チェック'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BudgetScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.backup, color: Colors.blueGrey),
            title: const Text('データのバックアップ'),
            subtitle: const Text('エクスポート（JSON/CSV）・インポート'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showBackup(context, appState),
          ),
          if (!kIsWeb)
          SwitchListTile(
            secondary: const Icon(Icons.cloud_done, color: Colors.teal),
            title: const Text('自動バックアップ'),
            subtitle: Text(appState.lastAutoBackupAt != null
                ? '最終: ${_fmtDt(appState.lastAutoBackupAt!)}'
                : '1日1回、アプリ内に自動保存'),
            value: appState.autoBackupEnabled,
            onChanged: (v) => appState.setAutoBackupEnabled(v),
          ),
          if (!kIsWeb)
          ListTile(
            leading: const Icon(Icons.restore, color: Colors.orange),
            title: const Text('バックアップから復元'),
            subtitle: const Text('自動保存されたバックアップ一覧'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRestoreBackup(context, appState),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.palette, color: Colors.deepPurple),
            title: const Text('アプリの背景色'),
            subtitle: Text('現在: ${backgroundThemeByKey(appState.backgroundTheme).label}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showBackgroundPicker(context, appState),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.calendar_month, color: Colors.pink),
            title: const Text('翌々月の予想残高を表示'),
            subtitle: const Text('残高画面に翌々月末の予想も表示する'),
            value: appState.showMonthAfterNext,
            onChanged: (v) => appState.setShowMonthAfterNext(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.wallet, color: Colors.brown),
            title: const Text('財布の現金を使う'),
            subtitle: const Text('残高画面に「財布の現金」を表示して予想残高に加算'),
            value: appState.showWalletCash,
            onChanged: (v) => appState.setShowWalletCash(v),
          ),
          // 💡 Googleカレンダーへ書き出す。iPhone/Macの純正カレンダーには、
          //   端末側でGoogleアカウントを追加すれば自動的に届く。
          SwitchListTile(
            secondary: const Icon(Icons.event_available, color: Colors.red),
            title: const Text('Googleカレンダーに自動連携'),
            subtitle: const Text(
                'シフト・予定・給料日・引き落とし日を「ポケットメイド」カレンダーへ書き出し'),
            value: appState.calendarAutoSync,
            onChanged: (v) async {
              if (v && !await ensureGoogleConnected(context)) return;
              if (!context.mounted) return;
              if (v) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('カレンダーへ同期中...')),
                );
              }
              final ok = await appState.setCalendarAutoSync(v);
              if (context.mounted && v) {
                final sync = appState.calendarSync;
                final why = sync is GoogleCalendarSync ? sync.lastError : null;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text(ok
                        ? 'Googleカレンダーに連携しました'
                        : (why ?? 'カレンダーに連携できませんでした')),
                    duration: Duration(seconds: ok ? 4 : 8),
                  ));
              }
            },
          ),
          if (appState.calendarAutoSync)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'iPhoneやMacの純正カレンダーにも出したいときは、端末の設定で'
                'Googleアカウントを追加してください（アプリ側の設定は不要です）。',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('セキュリティ',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          const PasscodeSettings(),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Google連携',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'メールの取り込みとドライブ同期は、同じGoogleアカウントを使います。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          // 連携はここ1か所（Gmail取込とドライブ同期で共用）
          const GoogleAccountTile(),
          SwitchListTile(
            secondary: const Icon(Icons.login, color: Colors.lightBlue),
            title: const Text('起動時にログインを求める'),
            subtitle: const Text(
                'ログインするとドライブから自分のデータが出てきます',
                style: TextStyle(fontSize: 12)),
            value: appState.requireGoogleLogin,
            onChanged: (v) async {
              if (v && !await ensureGoogleConnected(context)) return;
              await appState.setRequireGoogleLogin(v);
            },
          ),
          // 💡 端末をまたいでデータを持ち回るための同期。
          //   保存先はDriveのアプリ専用フォルダ（他のファイルには触れない）。
          SwitchListTile(
            secondary: const Icon(Icons.cloud_sync, color: Colors.lightBlue),
            title: const Text('Googleドライブと同期'),
            subtitle: Text(appState.driveSyncEnabled
                ? '最終同期: ${appState.driveSyncedAt == null ? 'まだ' : DateFormat('M/d HH:mm').format(appState.driveSyncedAt!)}'
                : 'iPhone・iPad・Macで同じデータを使う'),
            value: appState.driveSyncEnabled,
            onChanged: (v) async {
              // 💡 未連携のままONにしても同期できないので、ここで連携まで済ませる
              if (v && !await ensureGoogleConnected(context)) return;
              await appState.setDriveSyncEnabled(v);
              if (v && context.mounted) await runDriveSync(context, appState);
            },
          ),
          if (appState.driveSyncEnabled) ...[
            ListTile(
              dense: true,
              leading: const Icon(Icons.sync, color: Colors.lightBlue),
              title: const Text('今すぐ同期'),
              subtitle: const Text('新しい方に合わせる（両方変わっていたら選べます）'),
              onTap: () async {
                if (!await ensureGoogleConnected(context)) return;
                if (context.mounted) await runDriveSync(context, appState);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.help_outline, color: Colors.lightBlue),
              title: const Text('同期の状態を確認'),
              subtitle: const Text('データが出てこないときはここを見てください'),
              onTap: () => _showDebug(context, '同期の状態',
                  () => DriveSync.instance.diagnose(appState)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_download, color: Colors.blueGrey),
              title: const Text('ドライブの内容で置き換える'),
              subtitle: const Text('この端末のデータは消えます'),
              onTap: () async {
                if (!await ensureGoogleConnected(context)) return;
                if (!context.mounted) return;
                final ok = await _confirm(context, 'ドライブの内容で置き換える',
                    'この端末のデータはすべて消えて、ドライブの内容になります。');
                if (ok != true) return;
                final r = await DriveSync.instance.pullNow(appState);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(r.state == DriveSyncState.error
                          ? r.message
                          : 'ドライブの内容にしました')));
                }
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.cloud_upload, color: Colors.blueGrey),
              title: const Text('この端末の内容で上書きする'),
              subtitle: const Text('ドライブのデータは消えます'),
              onTap: () async {
                if (!await ensureGoogleConnected(context)) return;
                if (!context.mounted) return;
                final ok = await _confirm(context, 'この端末の内容で上書きする',
                    'ドライブにある内容はすべて消えて、この端末の内容になります。');
                if (ok != true) return;
                final r = await DriveSync.instance.pushNow(appState);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(r.state == DriveSyncState.error
                          ? r.message
                          : 'ドライブへ保存しました')));
                }
              },
            ),
          ],
          const Divider(),
          const ListTile(
            leading: Icon(Icons.account_balance, color: Colors.green),
            title: Text('三井住友銀行 連携設定'),
            subtitle: Text('未連携'),
          ),
          ListTile(
            leading: const Icon(Icons.sync, color: Colors.red),
            title: const Text('カード利用メールを今すぐ取得'),
            subtitle: const Text('先月＋今月の差分をすばやく取り込み'),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('取得中...')),
              );
              var result = await syncGmail(appState);
              // 許可が無ければこの場で求めてから再試行（ポップアップは操作中のみ開ける）
              if (result.needsPermission &&
                  await GmailService.instance.requestGmailAccess()) {
                result = await syncGmail(appState);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(result.message)));
              }
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cleaning_services, color: Colors.grey),
            title: const Text('メールの解析キャッシュを消す'),
            subtitle: const Text('取り込み内容がおかしいときに。次回の更新が遅くなります'),
            onTap: () async {
              await GmailService.instance.clearCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('キャッシュを消しました')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.history, color: Colors.indigo),
            title: const Text('過去2年分をすべて取り込み直す'),
            subtitle: const Text('時間がかかります（漏れた過去分もまとめて取得）'),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('全期間を取得中... 少し時間がかかります')),
              );
              var result = await syncGmail(appState, full: true);
              // 許可が無ければこの場で求めてから再試行（ポップアップは操作中のみ開ける）
              if (result.needsPermission &&
                  await GmailService.instance.requestGmailAccess()) {
                result = await syncGmail(appState, full: true);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(result.message)));
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.mail, color: Colors.red),
            title: const Text('メールの取得結果を見る'),
            subtitle: const Text('取り込んだ明細の確認・手動取得'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const GmailScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.percent, color: Colors.deepOrange),
            title: const Text('カードの金利設定'),
            subtitle: const Text('分割払いに使う年率を設定'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CardSettingsScreen()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_active, color: Colors.orange),
            title: const Text('メイドの通知を許可'),
            subtitle: const Text('支払い・Todoのリマインダーを受け取る'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final granted = await NotificationService.instance.requestPermission();
              if (granted) {
                await NotificationService.instance.rescheduleAll(appState);
              }
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(granted ? '通知を許可しました 🔔' : '通知が許可されませんでした')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.warning_amber, color: Colors.red),
            title: const Text('残高不足チェック'),
            subtitle: const Text('今月末がマイナスなら通知でお知らせ'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final balance = appState.thisMonthBalance;
              if (balance < 0) {
                await NotificationService.instance.notifyShortage(balance);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('残高不足の通知を送りました ⚠')),
                  );
                }
              } else {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('今月末の予想残高は ¥$balance です 👍')),
                  );
                }
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.indigo),
            title: const Text('🔧 楽天メールの中身を確認'),
            subtitle: const Text('最新の楽天メール本文を表示'),
            onTap: () => _showDebug(context, '楽天メール 生テキスト',
                () => GmailService.instance.debugRawBody('from:rakuten-card.co.jp カード利用のお知らせ')),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.indigo),
            title: const Text('🔧 Amazonの取得状況を確認'),
            subtitle: const Text('発送・注文メール件数と抽出結果を表示'),
            onTap: () => _showDebug(context, 'Amazon 取得状況',
                () => GmailService.instance.debugAmazonSummary()),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.indigo),
            title: const Text('🔧 アプリ内のAmazon登録状況'),
            subtitle: const Text('取り込み後にアプリへ残っているAmazon明細'),
            onTap: () {
              final amzn = appState.payments.where((p) => p.cardName == 'Amazonマスター').toList()
                ..sort((a, b) => b.paymentDate.compareTo(a.paymentDate));
              final sb = StringBuffer()
                ..writeln('全支払い: ${appState.payments.length}件')
                ..writeln('Amazonマスター: ${amzn.length}件')
                ..writeln('────────────');
              for (final p in amzn.take(60)) {
                sb.writeln('${p.paymentDate.toString().substring(0, 10)}  ¥${p.amount}  ${p.note}');
              }
              _showDebug(context, 'アプリ内Amazon', () async => sb.toString());
            },
          ),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.indigo),
            title: const Text('🔧 Amazon発送メールの中身を確認'),
            subtitle: const Text('最新の発送メール本文を表示'),
            onTap: () => _showDebug(context, 'Amazon発送 生テキスト',
                () => GmailService.instance.debugRawBody('from:shipment-tracking@amazon.co.jp')),
          ),
          const Divider(),
          // 💡 「直したのに反映されない」がキャッシュのせいか判断できるように、
          //   今動いているビルドを表示する。
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline, color: Colors.grey),
            title: const Text('バージョン', style: TextStyle(fontSize: 14)),
            subtitle: Text(buildLabel, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
