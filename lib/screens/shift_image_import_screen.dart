// 💡 シフト表の画像から、シフトをまとめて登録する画面（Gemini で読み取り）。
//   流れ: 画像を選ぶ → 名前・年月・勤務先を指定 → 送信内容を確認して読み取る
//        → 候補を確認・修正 → 選んだものだけ登録（すぐ「元に戻す」もできる）
// ⚠️ 読み取りに失敗・途中終了・形式違いのときは1件も登録しない。
//   閉じたときも既存のシフトは変わらない（登録ボタンを押すまで何も保存しない）。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../gemini_client.dart';
import '../shift_image_import.dart';
import '../widgets/app_sheet.dart';

const int kMaxShiftImageBytes = 8 * 1024 * 1024; // 8MB（実機で様子を見て調整）
const String _kPerson = 'local_shift_person_name'; // ⚠️ 同期しない（saved_ で始めない）

String? shiftImageMime(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
  }
  return null;
}

class ShiftImageImportScreen extends StatefulWidget {
  const ShiftImageImportScreen({
    super.key,
    this.initialMonth,
    this.testImage,
    this.testResult,
    this.testWorkplaceId,
  });
  final DateTime? initialMonth;
  // 💡 テスト用（確認画面を直接開くため。画像選択とGeminiを通さない）
  @visibleForTesting
  final Uint8List? testImage;
  @visibleForTesting
  final ShiftReadResult? testResult;
  @visibleForTesting
  final String? testWorkplaceId;

  @override
  State<ShiftImageImportScreen> createState() => _ShiftImageImportScreenState();
}

class _ShiftImageImportScreenState extends State<ShiftImageImportScreen> {
  Uint8List? _bytes;
  String? _fileName;
  String? _mime;
  final _person = TextEditingController();
  late DateTime _month;
  String? _workplaceId;
  bool _reading = false;
  String? _error;
  ShiftReadResult? _result;
  final _bulkBreak = TextEditingController();

  @override
  void initState() {
    super.initState();
    final m = widget.initialMonth ?? DateTime.now();
    _month = DateTime(m.year, m.month);
    final wps = context.read<AppState>().workplaces;
    if (wps.isNotEmpty) _workplaceId = wps.first.id;
    if (widget.testResult != null) {
      _bytes = widget.testImage;
      _result = widget.testResult;
      _workplaceId = widget.testWorkplaceId ?? _workplaceId;
      _person.text = 'テスト';
    }
    GeminiClient.instance.load().then((_) {
      if (mounted) setState(() {});
    });
    SharedPreferences.getInstance().then((p) {
      final name = p.getString(_kPerson);
      if (name != null && mounted && _person.text.isEmpty) {
        setState(() => _person.text = name);
      }
    });
  }

  @override
  void dispose() {
    _person.dispose();
    _bulkBreak.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      withData: true,
    );
    if (r == null || r.files.isEmpty) return;
    final f = r.files.single;
    final mime = shiftImageMime(f.name);
    String? err;
    if (mime == null) {
      err = 'JPEG・PNG・WebP の画像を選んでください';
    } else if (f.bytes == null) {
      err = '画像を読み込めませんでした';
    } else if (f.size > kMaxShiftImageBytes) {
      err = '画像が大きすぎます（${(f.size / 1024 / 1024).toStringAsFixed(1)}MB）。8MB以下にしてください';
    }
    setState(() {
      _error = err;
      _result = null;
      if (err == null) {
        _bytes = f.bytes;
        _fileName = f.name;
        _mime = mime;
      }
    });
  }

  bool get _ready =>
      _bytes != null &&
      _person.text.trim().isNotEmpty &&
      _workplaceId != null &&
      GeminiClient.instance.hasKey &&
      !_reading;

  Future<void> _read() async {
    if (!_ready) return;
    setState(() {
      _reading = true;
      _error = null;
    });
    final name = _person.text.trim();
    try {
      (await SharedPreferences.getInstance()).setString(_kPerson, name);
    } catch (_) {}
    try {
      final raw = await GeminiClient.instance.readShiftImage(
        bytes: _bytes!,
        mimeType: _mime!,
        personName: name,
        year: _month.year,
        month: _month.month,
      );
      final r = parseShiftReadJson(raw, year: _month.year, month: _month.month);
      if (!mounted) return; // 閉じた後に返ってきた結果は使わない
      final app = context.read<AppState>();
      final w = app.workplaceById(_workplaceId);
      markDuplicates(r.candidates, app.shifts,
          workplaceName: w?.name ?? '', workplaceId: w?.id);
      setState(() => _result = r);
    } on GeminiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = '${e.message}。もう一度読み取ってください');
    } catch (e) {
      if (mounted) setState(() => _error = '読み取りに失敗しました（$e）');
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  void _register() {
    final app = context.read<AppState>();
    final w = app.workplaceById(_workplaceId);
    final r = _result;
    if (w == null || r == null) return;
    final chosen = r.candidates.where((c) => c.selected).toList();
    final dupSkipped = r.candidates.where((c) => c.duplicate && !c.selected).length;
    final added = app.addShiftsBatch(w, [
      for (final c in chosen)
        (date: c.date, start: c.start, end: c.end, breakMinutes: c.breakMinutes ?? 0),
    ]);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(SnackBar(
      content: Text('${added.length}件のシフトを登録しました'
          '${dupSkipped > 0 ? '（重複$dupSkipped件は外しました）' : ''}'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: '元に戻す',
        onPressed: () {
          final n = app.undoShiftsBatch(added);
          messenger.showSnackBar(SnackBar(content: Text('$n件の登録を取り消しました')));
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('画像からシフト追加'),
        actions: [
          IconButton(
            tooltip: 'Geminiの設定',
            icon: const Icon(Icons.key),
            onPressed: () async {
              await showGeminiSettingsSheet(context);
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: _result == null ? _inputView(app) : _reviewView(app),
    );
  }

  // ───── 読み取り前 ─────
  Widget _inputView(AppState app) {
    final months = [for (var d = -1; d <= 2; d++) DateTime(DateTime.now().year, DateTime.now().month + d)];
    if (!months.contains(_month)) months.add(_month);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!GeminiClient.instance.hasKey)
          Card(
            color: Colors.amber[50],
            child: ListTile(
              leading: const Icon(Icons.key, color: Colors.orange),
              title: const Text('GeminiのAPIキーが必要です'),
              subtitle: const Text('Google AI Studio で発行したキーを入れてください'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await showGeminiSettingsSheet(context);
                if (mounted) setState(() {});
              },
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _reading ? null : _pick,
          icon: const Icon(Icons.image_outlined),
          label: Text(_bytes == null ? 'シフト表の画像を選ぶ' : '画像を選び直す'),
        ),
        if (_bytes != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: Image.memory(_bytes!, fit: BoxFit.contain),
            ),
          ),
          Text('$_fileName（${(_bytes!.length / 1024).round()}KB）',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
        const SizedBox(height: 16),
        TextField(
          controller: _person,
          decoration: const InputDecoration(
            labelText: '表の中の自分の名前',
            helperText: '他の人のシフトと取り違えないための目印です',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<DateTime>(
          initialValue: _month,
          decoration: const InputDecoration(labelText: 'シフトの年月', border: OutlineInputBorder()),
          items: [
            for (final m in months)
              DropdownMenuItem(value: m, child: Text(DateFormat('yyyy年M月').format(m))),
          ],
          onChanged: (v) => setState(() => _month = v ?? _month),
        ),
        const SizedBox(height: 12),
        if (app.workplaces.isEmpty)
          const Text('先に 設定→勤務先の管理 で勤務先を登録してください（時給などはそこから使います）',
              style: TextStyle(color: Colors.red))
        else
          DropdownButtonFormField<String>(
            initialValue: _workplaceId,
            decoration: const InputDecoration(labelText: '勤務先', border: OutlineInputBorder()),
            items: [
              for (final w in app.workplaces) DropdownMenuItem(value: w.id, child: Text(w.name)),
            ],
            onChanged: (v) => setState(() => _workplaceId = v),
          ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.blueGrey[50],
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '「読み取る」を押すと、この画像と、名前・年月を Google（Gemini API）へ送ります。'
            '家計のデータやメールは送りません。\n'
            '・利用状況によってはAPIの料金がかかることがあります\n'
            '・他の人の名前が写っているときは、自分の行の周りだけ切り出してから選ぶと安心です',
            style: TextStyle(fontSize: 12),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _ready ? _read : null,
          icon: _reading
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(_reading ? '読み取り中…（数十秒かかることがあります）' : '読み取る'),
        ),
      ],
    );
  }

  // ───── 確認・修正 ─────
  Widget _reviewView(AppState app) {
    final r = _result!;
    final w = app.workplaceById(_workplaceId);
    final period = w == null ? null : app.wagePeriodFor(w, _month);
    final noWage = period == null || period.hourlyWage <= 0;
    final chosen = r.candidates.where((c) => c.selected).toList();
    final missingBreak = chosen.where((c) => c.needsBreak).length;
    final blocked = noWage || missingBreak > 0 || chosen.isEmpty;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              Text('${DateFormat('yyyy年M月').format(_month)} ・ ${w?.name ?? ''} ・ ${_person.text.trim()}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('画像と見比べて、違うところは直してください。チェックしたものだけ登録します。',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              if (r.warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                _Notice(
                  color: Colors.orange,
                  lines: ['読み取りで気になった点', ...r.warnings.map((e) => '・$e')],
                ),
              ],
              if (noWage) ...[
                const SizedBox(height: 8),
                const _Notice(color: Colors.red, lines: [
                  'この勤務先に時給が設定されていません。',
                  '設定→勤務先の管理 で時給を入れてから登録してください（給料の見込みが0円になるため）。',
                ]),
              ],
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('元の画像を見る', style: TextStyle(fontSize: 14)),
                children: [
                  InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(_bytes!, fit: BoxFit.contain),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      for (final c in r.candidates) {
                        c.selected = !c.duplicate;
                      }
                    }),
                    child: const Text('すべて選ぶ'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      for (final c in r.candidates) {
                        c.selected = false;
                      }
                    }),
                    child: const Text('選択を外す'),
                  ),
                  if (r.candidates.any((c) => c.needsBreak))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('空欄の休憩を', style: TextStyle(fontSize: 13)),
                        SizedBox(
                          width: 56,
                          child: TextField(
                            controller: _bulkBreak,
                            keyboardType: TextInputType.number,
                            textAlign: TextAlign.center,
                            decoration: const InputDecoration(isDense: true, suffixText: '分'),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            final v = int.tryParse(_bulkBreak.text);
                            if (v == null || v < 0) return;
                            setState(() {
                              for (final c in r.candidates.where((c) => c.needsBreak)) {
                                c.breakMinutes = v;
                              }
                            });
                          },
                          child: const Text('にする'),
                        ),
                      ],
                    ),
                ],
              ),
              if (r.candidates.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('登録できるシフトが見つかりませんでした。名前・年月・画像を確認してください。',
                      textAlign: TextAlign.center),
                ),
              for (final c in r.candidates)
                _CandidateTile(
                  c: c,
                  onChanged: () => setState(() {
                    final wp = app.workplaceById(_workplaceId);
                    markDuplicates(r.candidates, app.shifts,
                        workplaceName: wp?.name ?? '', workplaceId: wp?.id);
                  }),
                  onToggle: (v) => setState(() => c.selected = v),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (missingBreak > 0)
                  Text('休憩が空欄のシフトが$missingBreak件あります。入れてから登録してください',
                      style: const TextStyle(fontSize: 12, color: Colors.red)),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _result = null),
                      child: const Text('読み取りに戻る'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        onPressed: blocked ? null : _register,
                        child: Text('選んだ${chosen.length}件を登録'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.color, required this.lines});
  final MaterialColor color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color[50],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Text(l, style: TextStyle(fontSize: 12, color: color[900])),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.c, required this.onChanged, required this.onToggle});
  final ShiftCandidate c;
  final VoidCallback onChanged;
  final ValueChanged<bool> onToggle;

  static final _md = DateFormat('M/d(E)', 'ja_JP');
  static final _hm = DateFormat('H:mm');

  @override
  Widget build(BuildContext context) {
    final endText = '${c.overnight ? '翌' : ''}${_hm.format(c.end)}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _edit(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
          child: Row(
            children: [
              Checkbox(value: c.selected, onChanged: (v) => onToggle(v ?? false)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_md.format(c.date)}  ${_hm.format(c.start)}〜$endText',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                      c.needsBreak ? '休憩: 未入力（タップして入れる）' : '休憩: ${c.breakMinutes}分',
                      style: TextStyle(
                          fontSize: 12, color: c.needsBreak ? Colors.red : Colors.black54),
                    ),
                    Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: [
                        if (c.duplicate) const _Tag('登録済みと重複', Colors.grey),
                        if (c.overlapWith != null) _Tag('${c.overlapWith}と時間が重なる', Colors.orange),
                        if (c.uncertain) const _Tag('要確認', Colors.orange),
                        if (c.note.isNotEmpty) _Tag(c.note, Colors.blueGrey),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.edit, size: 18, color: Colors.black38),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    var start = TimeOfDay.fromDateTime(c.start);
    var end = TimeOfDay.fromDateTime(c.end);
    var date = c.date;
    final breakCtrl = TextEditingController(text: c.breakMinutes?.toString() ?? '');
    final ok = await showAppSheet<bool>(
      context,
      (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('シフトを直す',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ListTile(
                title: const Text('日付'),
                trailing: Text(DateFormat('M/d(E)', 'ja_JP').format(date)),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(date.year, date.month, 1),
                    lastDate: DateTime(date.year, date.month + 1, 0),
                  );
                  if (d != null) setSheet(() => date = d);
                },
              ),
              ListTile(
                title: const Text('開始'),
                trailing: Text(start.format(ctx)),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: start);
                  if (t != null) setSheet(() => start = t);
                },
              ),
              ListTile(
                title: const Text('終了'),
                subtitle: const Text('開始より前なら翌日として扱います', style: TextStyle(fontSize: 11)),
                trailing: Text(end.format(ctx)),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: end);
                  if (t != null) setSheet(() => end = t);
                },
              ),
              TextField(
                controller: breakCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '休憩（分）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('反映')),
            ],
          ),
        ),
      ),
    );
    if (ok == true) {
      c.date = DateTime(date.year, date.month, date.day);
      c.start = c.date.add(Duration(hours: start.hour, minutes: start.minute));
      var e = c.date.add(Duration(hours: end.hour, minutes: end.minute));
      if (!e.isAfter(c.start)) e = e.add(const Duration(days: 1));
      c.end = e;
      final b = int.tryParse(breakCtrl.text.trim());
      c.breakMinutes = (b != null && b >= 0) ? b : null;
      onChanged();
    }
    breakCtrl.dispose();
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final MaterialColor color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color[50],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: color[800])),
    );
  }
}

// 💡 APIキーとモデルの設定（設定画面と読み取り画面の両方から開く）
Future<void> showGeminiSettingsSheet(BuildContext context) async {
  final g = GeminiClient.instance;
  await g.load();
  final keyCtrl = TextEditingController();
  final modelCtrl = TextEditingController(text: g.model);
  var remember = g.keySaved;
  var hide = true;
  String? info;
  var busy = false;
  if (!context.mounted) return;
  await showAppSheet<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Gemini（シフト画像の読み取り）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 6),
            const Text(
              'Google AI Studio（aistudio.google.com）で発行した自分のAPIキーを使います。'
              'キーはこの端末の中だけで使い、バックアップやドライブ同期には入りません。',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              obscureText: hide,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: g.hasKey ? 'APIキー（入力済み・変えるときだけ入力）' : 'APIキー',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setSheet(() => hide = !hide),
                ),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: remember,
              onChanged: (v) => setSheet(() => remember = v ?? false),
              title: const Text('この端末に保存する', style: TextStyle(fontSize: 14)),
              subtitle: const Text('オフにすると、アプリを開き直すたびに入力が必要です',
                  style: TextStyle(fontSize: 11)),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: modelCtrl,
              decoration: const InputDecoration(
                labelText: 'モデル',
                helperText: '分からなければ「一覧から選ぶ」を押してください',
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.list),
                label: const Text('一覧から選ぶ'),
                onPressed: busy
                    ? null
                    : () async {
                        if (keyCtrl.text.trim().isNotEmpty) {
                          await g.setKey(keyCtrl.text, remember: remember);
                        }
                        setSheet(() {
                          busy = true;
                          info = null;
                        });
                        try {
                          final models = await g.listModels();
                          if (!ctx.mounted) return;
                          final picked = await showAppSheet<String>(
                            ctx,
                            (c2) => Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Text('使えるモデル',
                                      style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                                for (final m in models)
                                  ListTile(
                                    dense: true,
                                    title: Text(m),
                                    onTap: () => Navigator.pop(c2, m),
                                  ),
                              ],
                            ),
                          );
                          if (picked != null) modelCtrl.text = picked;
                          if (models.isEmpty) info = '使えるモデルが見つかりませんでした';
                        } catch (e) {
                          info = '$e';
                        } finally {
                          if (ctx.mounted) setSheet(() => busy = false);
                        }
                      },
              ),
            ),
            if (info != null) Text(info!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            const SizedBox(height: 8),
            Row(
              children: [
                if (g.hasKey)
                  TextButton(
                    onPressed: () async {
                      await g.clearKey();
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: const Text('キーを消す', style: TextStyle(color: Colors.red)),
                  ),
                const Spacer(),
                FilledButton(
                  onPressed: () async {
                    if (keyCtrl.text.trim().isNotEmpty) {
                      await g.setKey(keyCtrl.text, remember: remember);
                    } else if (g.hasKey && remember != g.keySaved) {
                      // 保存のオン／オフだけ変えた
                      await g.setKey(g.currentKeyForResave, remember: remember);
                    }
                    await g.setModel(modelCtrl.text);
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  keyCtrl.dispose();
  modelCtrl.dispose();
}
