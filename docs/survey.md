# 現状調査（2026-11-19）

再構築の前に、コード全体を調べた結果。設計方針と移行計画は `docs/architecture-plan.md`、
進捗は `docs/refactor-progress.md` にある。

- 調査開始時のコミット: `84a1c780023cc3e8c0a001bfa353dc6f5c49ca09`（ブランチ `claude/zen-heisenberg-xq1194`、main と同じ位置）
- 調査開始時の作業ツリー: 未コミットの変更なし
- ⚠️ この環境の Flutter（3.50.0 stable、CI と同じ stable チャネル）で `flutter pub get` を行うと、
  `pubspec.lock`（SDK 同梱パッケージの版）と `windows/flutter/generated_*` が書き換わる。
  利用者の変更ではなくツールの再生成なので、コミットには含めない

> 💡 対応状況（2026-11-19 時点）: B1・B2・B5・B6・B7・B8 は修正済み、B3・B4 は確認のうえ仕様を変更、
> B9 は銀行の休業日に年末年始を追加。詳細は `docs/review-handoff.md` §4。
> 下の本文は調査した時点（開始コミット）の記録として残している。

## 1. 変更前の検証結果（ベースライン）

| 項目 | 結果 |
|---|---|
| `flutter test` | 577 件成功・2 件スキップ（スキップは意図的: 手元の実メール再生 `mail_schedule_replay_test` と画面撮影用 `mail_schedule_ui_test` の一部） |
| `flutter analyze lib/` | 46 件（すべて info `deprecated_member_use`）。Flutter 3.47 以降で `package:flutter/material.dart` と `GlobalMaterialLocalizations` 等が `material_ui` / `cupertino_ui` パッケージへ移る予告。以前の Flutter（handoff.md の時点）では 0 件だった。コードの不具合ではない |
| `flutter build web --release --base-href /future-app/` | 成功 |
| ブラウザ表示 | 架空データ（`/tmp` の作業用スクリプトで作成。実データではない）を localStorage に入れて 390×844 で全タブを撮影。描画・タブ移動は正常 |

## 2. 調査の範囲

### 読んだもの（手書きのアプリコード）

- `lib/app_state.dart`（6,269 行）: データ型、予想残高の計算、集計、Gmail 照合（`reconcilePayments`）、
  保存・読込・書き出し・取り込み、自己修復、確認待ち（`homeNotices` / `pendingDraws`）
- `lib/main.dart`、`lib/widgets/app_gate.dart`（起動・ロック・ログインの関所）
- `lib/gmail_sync.dart`（取り込みの全体手順）、`lib/drive_sync.dart`（同期と競合判定）
- `lib/gmail_service.dart` の認証・トークン・キャッシュ・取得の部分（解析規則は構造のみ）
- `lib/google_calendar_sync.dart` の前半（専用カレンダーの用意と作成・更新）
- `lib/screens/income_screen.dart`（ホーム）、`payment_screen.dart`（一覧と合計）、`settings_screen.dart`（項目構成）、
  `history_screen.dart`、`lib/widgets/sync_status.dart`、`add_entry_sheets.dart`（シフトの作成）
- `web/index.html`（Service Worker の切り替え）、`.github/workflows/deploy-web.yml`、`pubspec.yaml`、`analysis_options.yaml`
- 既存文書 `CLAUDE.md`、`docs/handoff.md`

### 構造だけ確認したもの（中身の検証は未実施）

- `lib/mail_schedule_*.dart`・`screens/mail_schedule_screen.dart`・`widgets/mail_schedule_review_sheet.dart`
  （2026-10 下旬の新機能。専用の計画書と評価セット・テスト 8 ファイルがある）
- `lib/shift_image_import.dart`・`shift_calendar_ocr.dart`・`ocr_digits*.dart`・`gemini_client.dart`
- `lib/lock_service.dart`・`notification_service.dart`（端末アプリ専用）
- `calendar_screen.dart`・`todo_screen.dart`・`workplace_*`・`deposit_dialog.dart`・`breakdown_screen.dart` などの残りの画面
- テスト 49 ファイルは名前と一部の中身（`cash_flow_test.dart` など）

### 対象外

- 生成コード・外部ライブラリ（`.dart_tool/`、`build/`、パッケージ）
- `android/`・`ios/`・`macos/`・`windows/`・`linux/` の中身（ビルド設定）。iOS/macOS はこの環境（Linux）でビルドできない

## 3. 現在の構造

```
main.dart ──> AppState（ChangeNotifier・6,269行）<── 画面すべて（context.watch / read）
   │             ├ データ型 20 種（ShiftData, Payment, Loan …）
   │             ├ 計算（予想残高・集計・引落日）
   │             ├ 変更操作（add/update/remove …）＋ saveData + notifyListeners
   │             ├ 保存・読込（SharedPreferences）／書き出し・取り込み（JSON）
   │             └ 自己修復（起動時・取り込み時）
   ├──> GmailService（シングルトン・1,917行: 認証＋トークン＋API＋キャッシュ＋解析）
   ├──> gmail_sync / drive_sync / google_calendar_sync / mail_schedule_service（AppState と GmailService を使う）
   └──> AppGate（ロック・ログイン）
```

### 良い設計（維持する）

- **AppState は外部サービスを import していない**。カレンダーは `CalendarSyncHook` 経由（`app_state.dart:1200` 付近）。
  依存の向きは「サービス → AppState」の一方向で、循環 import は無い
- 取り込みの「1 件でも取れなかったら反映しない」（`gmail_sync.dart` の `_syncGmail`）と、実行中の取得への相乗り（`syncGmail`）
- ドライブ同期の判定が純粋関数（`decideSyncState`）でテストされている。黙って上書きしない
- `importJson` の失敗時の巻き戻し（`app_state.dart:5646`）
- 認証の復帰手順が関数として切り出されテストされている（`google_auth_recovery.dart`、`shouldTrySilentAuth`）
- `MaterialApp.builder` は `Selector` で背景だけを監視（`main.dart` の builder）
- 金額の罠をコメント（💡・⚠️）で残す文化。テストが 577 件あり、多くが実際に踏んだ不具合を固定している

### 変更が波及しやすい原因（コード上の根拠あり）

1. **同じ事実を別の規則で計算する箇所が複数ある**（いちばん大きい原因）
   - 「n 月に何がいくら落ちるか」の計算が 2 系統ある
     - 正: `drawBreakdownOf`（`app_state.dart:4787`）… 設定の引落日、締め期間、分割・ローン・頭金の合算、銀行確定の優先、残高更新日ゲート
     - 旧: `cardChargesOf`（`:4416`）／`cardPaymentsOf`（`:4449`）／`_cardDrawRule`（`:4386`、楽天=27日・三井/Amazon/メル=26日を**コードに焼き付け**）／
       `subscriptionTotal`（`:4453`、銀行確定を見ない）／`installmentTotal`（`:4659`、**今月時点の**分割の合計）
     - 旧系統はホームの「収支の内訳」グラフと「カード請求(未払い)・定期支払い・分割払い(今月)・ATM」の行
       （`screens/income_screen.dart:729-760`）と、収支の履歴（`screens/history_screen.dart:22-53`）で使われている。
       同じホーム画面に、予想残高（正）と支出（旧）が別の規則で並ぶ
   - 予想残高の式「起点＋入金−引き落とし−一度きり」が 7 か所に書かれている:
     `thisMonthBalance`（`:4882`）、`nextMonthBalance`、`monthAfterNextBalance`、`thisMonthBreakdown`・`nextMonthBreakdown`・
     `monthAfterNextBreakdown`（`:5264` 以降）、`cashEventsAhead`（`:4899`）。`cash_flow_test.dart` が一致を固定しているが、
     直すたびに 7 か所をそろえる必要がある
   - 引き落とし日の規則が分散: `cardDrawDateOf`、`drawDateOf`、`drawDateForUsage`、`cardClosingPeriodOf`、`debitDateForNth`（旧）、
     `pendingDraws` 内の定期の日付（`:3139`、**営業日に寄せていない**。予想側の `subscriptionDrawsIn` は `nextBusinessDay` で寄せる）
   - `pendingDraws` の「カードの引き落とし（予定）」の金額（`:3123`）は暦月の `paymentTotalsByCardOf` で、締め期間・分割・ローンの合算を見ない。
     予想側（`drawBreakdownOf`）と金額がずれうる
2. **AppState に責務が集中**: データ型・計算・変更・保存・修復・表示用の文言（`homeNotices` の文章、`Colors` による色）が 1 ファイル。
   `notifyListeners()` 90 回・`saveData(` 82 回・`DateTime.now()` 48 回
3. **時刻が注入できない**: 計算が `DateTime.now()` を直接読む。テストは実行日の日付で組み立てるため、
   12 月→1 月・月末・土日祝の境界を狙ったテストが書けない（実行日によって通る道が変わる）
4. **保存の経路が 2 つ**: `saveData`/`_loadDataInner`（SharedPreferences）と `exportJson`/`_importJson`（ドライブ・バックアップ）が
   それぞれ項目を列挙している。現時点で項目の食い違いは無い（スクリプトで照合済み）が、カード設定だけ別関数で保存しており、
   ここで実際に不具合が出ている（下の B1）
5. **画面が計算している箇所**: `payment_screen.dart:486-500` が合計と「分割を足すか」の判定を画面内で行っている（確定済み判定の規則を複製）。
   `income_screen.dart:751` も支出合計を画面で作っている
6. **GmailService が大きい**: 認証・トークン保存・API・キャッシュ・カード会社ごとの解析が 1 ファイル（1,917 行）

## 4. 見つかった問題

### コードで確定したもの（B1・B2 は使い捨てのテストで実行しても確認）

B2 の実行結果: `id: sh-fixed`・`calendarEventId: ev-123` のシフトを保存して読み込むと、
`id=sh-1795…`（新しい番号）・`calendarEventId=null` になった。

| ID | 内容 | 根拠 | 影響 |
|---|---|---|---|
| B1 | **ドライブから取り込んだ（バックアップを復元した）カードの引落日・締め日が保存されない** | `importJson`（`:5646`）は `saveData(markModified:false)` を呼ぶが、`saveData`（`:5811`）は `saved_card_payment_days`・`saved_card_closing_days` を書かない（`_saveCardPaymentDays` `:5145` だけが書く）。使い捨てのテストで「取り込み → 再読み込み」で元の値に戻ることを確認した | 再読み込み後に古いカード設定へ戻り、別端末で消したカードが復活。次の変更でドライブも古い設定で上書きされる。締め日が違えば予想額も静かに変わる |
| B2 | **起動時の自己修復でシフトの ID とカレンダーの予定 ID が消える** | `_migrateWorkplaces`（`:6205`）が勤務先 ID の無いシフトを `ShiftData(...)` で作り直すとき `id` と `calendarEventId` を渡していない。勤務先を選ばずに入れたシフト（`add_entry_sheets.dart:119/287/447`）や CSV 取り込み（`:5474`）は勤務先 ID が無いので、次の起動で必ずこの処理を通る | ID が変わり、カレンダーの予定が二重にできうる。メールの予定提案の対応（`mailEntityLinks`）も外れうる |
| B3 | **ホームと履歴の「支出」が予想残高と別の規則** | 上記 1。`history_screen.dart` は過去の月にも「今月時点の」`installmentTotal` と全定期 `subscriptionTotal` を足す（`monthlyExpenseOf` `:4356`） | 同じ月の支出が画面ごとに違う。過去月の分割が今の値で上書き表示される |
| B4 | **年間のカード支出が二重に数える** | `cardSpendingOfYear`（`:4349`）は年内の全明細（利用通知・請求予定・銀行確定・記録のみ）をそのまま足す | 同じ買い物を利用通知と銀行確定の両方で数える（ホームの年間サマリーと履歴） |
| B5 | **カード明細の内訳の合計が一覧の合計と合わない** | `expenseDetailOf`（`:4164`）のカードの分岐は分割払いだけを足し、カード払いのローン・頭金を出さない。合計側（`expenseBreakdownOf`）はローン・頭金も足している | 「月ごとの支出詳細」で内訳を足しても合計に届かない |
| B6 | **予想の内訳で同じ名前の行が上書きされる** | `thisMonthBreakdown` などが `Map<String,int>` に `'${ラベル}（月/日）'` をキーとして入れる（`:5264` 以降）。同じ日に同じ名前の予定支出が 2 件あると 1 件ぶん消える | 内訳の合計が予想額と合わない（まれ） |
| B7 | **ドライブへの保存中の変更が「同期済み」扱いになる窓がある** | `pushNow` は先に `exportJson()` を作り、`upload` の中で `driveApi()` を待ってから時刻を取る（`drive_sync.dart:168-172, 288`）。この間の変更は送っていないのに、`driveSyncedAt` がその変更より後になる | 次の自動保存で「最新」と判定され、その変更がドライブに上がらない（次の変更まで） |
| B8 | **起動時・取り込み時の自己修復が一致していない** | `_loadDataInner` は三井住友→三井OLIVE の統合・分割の開始日の復元・勤務先の生成・分割の重複掃除を行うが、`_importJson` は `repairLoanBillingLinks` だけ | 古い端末が上げたデータを取り込むと、次の起動まで修復されないまま計算される |

| B9 | **年末年始（12/31・1/2・1/3）を銀行の休業日として扱っていない** | `isBankHoliday`（`japanese_holidays.dart`）は土日と祝日だけ。銀行は 12/31〜1/3 も休業する | 引落日・給料日が 12/31 や 1/2・1/3 にかかると、実際より早い日（場合によっては前の月）として予想する。今年は 2026-12-31（木）が該当しうる |

### コードからは確定、影響の大きさは実行時の確認が要るもの

- **保存失敗が利用者に見えない**: `saveData` は呼び出し側で待たれておらず（`saveData();` が 82 か所）、例外は未処理の Future のエラーになる。
  Web の localStorage には容量の上限があり、Gmail の解析キャッシュ（最大 4,000 件、`gmail_service.dart:1111`）も同じ場所に入る。
  上限に達したかどうかは実データの量で決まるので未確認
- **明細の ID が取り込みのたびに変わる**: `reconcilePayments` は自動明細を毎回 `_id()` で作り直す（`:2401` 付近）。
  `togglePaid` などは `firstWhere` で ID を引くので、詳細を開いたまま同期が終わると例外になりうる。画面が ID を持ち続ける操作があるかは未確認
- **リスナーの解除漏れ**: `MainNavigationScreen` が `appState.addListener` を 2 つ足すが外さない（`main.dart` の `_startShortfallWatch`/`_startDriveAutoPush`）。
  この画面が作り直されるのはロック解除後などに限られ、実害の有無は未確認
- **起動時の自己修復が「この端末の変更」として記録される**: `if (migrated) saveData()` は変更時刻を進めるので、ドライブ側も変わっていると競合の選択が出る。
  修復が冪等であれば 1 回きり
- **基準日が無いときの給料の入金月**: `incomeForecastIn`（`:4863`）は残高の更新日が無いと、勤務先ごとの給料日のずれではなく最頻値（`paydayOffsetMonths` `:4665`）で計算する。
  勤務先ごとにずれが違う人だけ影響

### UI/UX（撮影した画面と画面コードから）

- ホームが 1 列に長い（撮影で約 5 画面分）。「現在の残高」が上のカードと下の一覧の 2 か所に出る
- 予想の根拠が分かりにくい: 「タップで詳細」で内訳は出るが、確定（銀行の引落確定・入力した実給料）と見込み（シフトからの推定・利用通知）の区別が無い
- 「最低残高」に財布の現金が入るが、「現在の残高」には入らない（撮影例: 現在 ¥85,000、最低残高 ¥88,000）
- 「分割払い(今月) -¥0」「ATM引き出し -¥0」のように 0 円の行が出る
- 金額の増減を色（緑・赤）と記号で示しているが、確定／見込みは文字で示していない
- カレンダーの印（シフト・給料日・引き落とし・予定）は色の点だけで区別（凡例はある）
- 設定は分類されているが、開発用の項目（「見本の提案を入れて試す」）と動かない項目（「三井住友銀行 連携設定 未連携」`settings_screen.dart:1206`）が混ざる
- 画面ごとに色・文字の大きさを直接書いている（`Colors.red`、`fontSize: 11` など）。共通の決まりが無い

## 5. テストで守られている仕様と、守られていない仕様

守られている（テスト名から確認）: 二重計上ゲート、n 月＝n-1 月の利用、一度きりの出費、締め期間、分割のカード合算、
口座払いローンの個別スライス、銀行確定の優先（カードごと）、取り込みの全か無か、削除の墓石・分割変換・メモ・Amazon の付け替え、
`importJson` の巻き戻し、`decideSyncState`、谷と月末の一致、認証の復帰判定。

守られていない:
- 取り込み後に再読み込みしてもカード設定が残ること（B1）
- 自己修復でシフトの ID・予定 ID が保たれること（B2）
- 画面ごとの支出の数字が予想と一致すること（B3〜B5）
- 時刻を固定した月境界（12 月→1 月、2 月末、土日祝）での予想
- 保存→読込、書き出し→取り込みの往復で全項目が残ること（項目の追加漏れの検出）
