# レビュー用の案内（再構築 2026-11）

GPT など別のレビュアーが、実際のコードと差分を自分で確かめるための案内。
ここに書いた「確認した」は、書いた側が実行した範囲の記録であって、正しさの結論ではない。
疑わしいところはコードとテストを直接見てほしい。

> ⚠️ **2026-11-20 追記（公開前の確認で分かったこと）**: 以下の 4 点は、この文書の記述より状態が悪い。
> 再現結果と対応方針は `docs/prepublish-review-plan.md`。対応はまだ実装していない。
> - 確認待ちの「引く」で二重に引ける（残高を書き直した後・連打・再起動後の再操作）。§9 の「利用者の判断に任せている」は不十分
> - 休みで翌月にずれた引落に、翌月付けの銀行確定が届くと、同じ金額を 2 回引き、翌月の請求が消える（`a75463d` で表に出た）
> - `importJson` の保存が途中で失敗し続けると、メモリは戻るが**端末の保存内容は新旧が混ざる**（§4 の「取り込む前に戻して」はメモリだけ）
> - カレンダーの引き落とし額（`cardPaymentSummaryOnDay`）が予想と別の規則のまま（最初の調査で見落とし）

## 1. 対象

| 項目 | 値 |
|---|---|
| 作業開始時のコミット | `84a1c780023cc3e8c0a001bfa353dc6f5c49ca09`（開始時点で未コミットの変更なし） |
| 作業ブランチ | `claude/zen-heisenberg-xq1194`（push・公開はしていない） |
| レビュー対象 | `git diff 84a1c78..HEAD`（7 コミット、52 ファイル、+6,805 / −2,363 行） |
| 調査・設計 | `docs/survey.md`（調査と問題の根拠）、`docs/architecture-plan.md`（設計・GPT 設計レビューへの採否・金額の意味 §11） |
| 進捗 | `docs/refactor-progress.md` |

コミットは段階ごとに分けてある。1 つずつ見ると、構造の変更と数字が変わる変更を区別しやすい。

| コミット | 段階 | 数字が変わるか |
|---|---|---|
| `5f6e83b` | 調査・設計の文書 | — |
| `afde9ea` | 時計の注入、手計算のテスト、回帰の記録 | 変わらない |
| `e3db900` | `lib/models/`・`lib/finance/billing_dates.dart` への移動 | 変わらない（回帰の記録が一致） |
| `bbe4179` | 予想を 1 つの行の並びから作る | 変わらない（回帰の記録は記録し直さずに一致）。例外: B6 |
| `049936d` | 不具合の修正 B1・B2・B5・B7・B8、`importJson` の保存待ち | 支出詳細の行だけ |
| `a75463d` | 確認済みの仕様の変更（Q1・Q2・Q3・Q6・月をまたぐ引落） | 変わる（コミットメッセージに項目と理由） |
| `89d8aa3` | UI | 表示だけ（計算は AppState のまま） |

## 2. 目的と新しい設計

目的は「1 か所を直すと別の画面の金額が静かに変わる」を構造で起きにくくすること。全面書き換えはしていない。

- 画面の窓口は今までどおり `AppState`（provider + ChangeNotifier）。状態管理の仕組みは変えていない
- 純粋な部品を AppState の外に出した。依存は `AppState → finance / models` の一方向
  - `lib/models/`: データ型と JSON（移動のみ。`app_state.dart` から再 export）
  - `lib/finance/billing_dates.dart`: 月末へのそろえ・翌営業日の引落日・締め期間・利用日の引落月
  - `lib/finance/forecast.dart`: 予想の行（`ForecastLine`）と月（`MonthForecast`）、最低残高・足りない日
  - `test/architecture_test.dart` が「finance・models は AppState・画面・外部サービス・Flutter を import しない」
    「finance は `DateTime.now()` を読まない」を検査する
- 予想残高は `AppState.forecastMonths` が作る行から、月末・内訳・日ごとの並び・最低残高・足りない日・次の引き落とし・
  収支の内訳のすべてを作る。以前は同じ式が 7 か所にあった（`docs/survey.md` §3）
- 「今日」は `AppState(clock:)` で注入する（`clockNow()`）。既定は現在時刻
- 金額の意味を 3 つに分けた（`docs/architecture-plan.md` §11）。画面ごとにどれを出すかも同じ節にある

## 3. 主な変更箇所（読む順のおすすめ）

1. `lib/finance/billing_dates.dart`・`lib/finance/forecast.dart`（短い。規則の中心）
2. `lib/app_state.dart`
   - `forecastMonths` / `_forecastLinesOf` / `_salaryCertainty` / `_drawCertainty`（予想の行と、月への振り分け）
   - `cardBillAmountOf`（予想と確認待ちが共通で使うカードの請求額）
   - `pendingDraws`（日付・金額の規則と ID）
   - `_expenseItemsOf` / `expenseSummaryOf` / `expenseSummaryOfYear`（利用月の支出と「設定から計算」の内訳）
   - `repairData`（自己修復の共通化）、`_migrateWorkplaces`（ID の引き継ぎ）
   - `importJson`（保存を待つ・失敗時の巻き戻し）、`saveData`（カード設定も書く）
   - `paymentListTotals`（支払い画面から移した合計）
   - 削除: `cardChargesOf`・`cardPaymentsOf`・`monthlyExpenseOf`・`_cardDrawRule`・`debitDateFor(Nth)`・
     `installmentTotal`・`cardSpendingOfYear`・`shortagePayments`
3. `lib/drive_sync.dart`（`DriveStore` の差し替え口、`pushNow`/`pullNow`、`lastDriveSyncState`）、
   `lib/widgets/drive_sync_dialog.dart`
4. `lib/japanese_holidays.dart`（`isBankYearEndHoliday`）
5. UI: `lib/ui/`、`lib/widgets/home_sections.dart`、`lib/screens/income_screen.dart`（ホーム）、
   `history_screen.dart`、`payment_screen.dart`、`settings_screen.dart`

## 4. 意図して変えた挙動

| 内容 | 以前 | 今 | 根拠のテスト |
|---|---|---|---|
| B1 取り込み後の再起動 | カードの引落日・締め日が古い設定に戻る | 残る。空の設定も残る | `persistence_test.dart` |
| B2 起動時の自己修復 | 勤務先の無いシフトの ID・予定 ID が消える | 引き継ぐ（消えたものは戻さない） | `persistence_test.dart` |
| B5 支出詳細のカード | 内訳にローン・頭金・カード未設定の分割が出ない | 出る（内訳の合計＝一覧の金額） | `expense_detail_sum_test.dart` |
| B6 予想の内訳 | 同じ日・同じ名前の予定支出が 1 件ぶん消える | 足す | `forecast_lines_test.dart` |
| B7 ドライブへの保存 | 送信中の変更が同期済み扱いになる窓があった | 書き出した瞬間の状態だけを同期済みにする | `drive_push_pull_test.dart` |
| B8 取り込み時の自己修復 | ローンの紐づけだけ | 起動時と同じ `repairData` | `persistence_test.dart` |
| 取り込みの保存 | 保存を待たずに戻る | 待つ。失敗したら取り込む前に戻して例外 | `persistence_test.dart`・`drive_push_pull_test.dart` |
| 判定後の取り込み | 「別の端末の変更」は判定後の変更を確かめずに置き換え | 判定のあとこの端末で変更していたら取り込まない | `drive_push_pull_test.dart` |
| Q1 ホーム・履歴の支出 | 別の規則（焼き付けた引落日・今月の分割を全月に） | 利用月の支出（予想と同じ規則・ゲート無し） | `expense_meaning_test.dart` |
| Q1 分割の残り回数 | カード名で決め打ちした引落日 | 設定の引落日（予想と同じ） | `workplace_test.dart` |
| Q2 年間 | 「カード支出」＝全明細の単純合計（二重に数える） | 「年間支出」＝利用月の支出の 12 か月合計、うち設定から計算 | `expense_meaning_test.dart` |
| Q3 確認待ちの引き落とし | 定期は休日調整なし、締め日カードも暦月、分割を足さない | 予想と同じ関数。予想のゲートでは消さない。ずれた引落の ID は請求の月 | `pending_draws_rules_test.dart` |
| Q6 銀行の休業日 | 土日祝 | ＋年末年始（12/31〜1/3）。祝日判定は不変 | `bank_holiday_test.dart` |
| 予想の月 | 引落日・給料日が休みで月をまたいでも元の月で計上 | 実際の日付の月に入れる | 回帰の記録の差分（`a75463d`） |
| ホーム | 長い 1 列、残高が 2 か所、別規則の支出 | 残高→見込み→根拠→次の引き落とし→確認待ち→操作、PC は 2 列 | `home_screen_test.dart` |
| 設定 | 動かない「三井住友銀行 連携設定」、見本の提案が通常の一覧 | 前者を削除、後者を詳細設定へ | — |

回帰の記録（`test/regression/forecast_snapshot.json`）は `049936d` と `a75463d` で記録し直した。
差分の要約はそれぞれのコミットメッセージにある。記録は正しさの根拠ではなく、正しさは手計算のテスト
（`forecast_hand_calc_test.dart`・`billing_dates_test.dart`・`bank_holiday_test.dart`・`pending_draws_rules_test.dart`・
`expense_meaning_test.dart`）に置いた。

## 5. 維持した挙動

- 保存キー（`flutter.saved_*`）と JSON の形、書き出しファイルの `version: 1`。新しい保存キーは足していない
- 二重計上ゲート、n 月＝n-1 月の利用、締め期間、分割・ローン・頭金のカード合算、口座払いローンの個別スライス、
  銀行確定の優先（カードごと）、一度きりの出費の日付どおりの月、墓石・変換済み・メモ・付け替え・別名の記録
- Gmail の取り込み（全か無か・相乗り・解析規則・キャッシュのバージョン）は変えていない
- ドライブ同期の判定（`decideSyncState`）と、競合時に選ばせる流れ
- 認証（リダイレクト方式・黙っての取り直し）、Web と iOS の分岐（`kIsWeb`・条件付き import）は触っていない

## 6. 保存データの互換性と移行

- 形は変えていないので、移行処理は追加していない
- 起動時の自己修復は `repairData` にまとめただけで、直す内容は同じ（＋B2 の ID の引き継ぎ）。
  2 回目は何も変えないこと、直すものが無ければ保存しないことをテストしている
- 確認待ちの処理済み記録（`handledDrawIds`）: ずれていない引落の ID は以前と同じ。休みで翌月にずれた引落だけ
  ID が「引落日の月」から「請求の月」に変わる。以前の ID で処理済みならその引落は出さない（互換）。
  ただし以前の ID は同じ月の別の引落と同じ文字列なので、以前から「片方を処理するともう片方も消える」状態はそのまま残る

## 7. 実行した検証

この環境（Linux、Flutter 3.50.0 stable を手で導入。CI も stable チャネル）で実行した。

| 検証 | 変更前 | 変更後 |
|---|---|---|
| `flutter test` | 577 成功・2 スキップ | 656 成功・2 スキップ（スキップは変更前と同じ 2 件で意図的） |
| `flutter analyze lib/` | 46 件（すべて info `deprecated_member_use`） | 49 件（すべて同じ種類。新しく作った `lib/ui/` 等 3 ファイルの `material.dart` の import の分） |
| `flutter build web --release --base-href /future-app/` | 成功 | 成功 |

⚠️ `flutter analyze` は info があると終了コード 1 を返す（変更前も同じ）。CI はビルドだけで analyze を実行していない。

## 8. UI の確認

- リリースビルドを `/future-app/` 配下で配信し、Chromium（Playwright）で表示した。データは架空（勤務先 1、カード 3、定期 2）を
  localStorage に入れた。CanvasKit はこの環境で外部から取れないため、ビルドに含まれるものを返すようにした
- 幅 390 で全タブ、幅 1280 でホームを撮影。ホームで「根拠を見る」のシート、残高の書き直し（85,000→90,000 で見込みと
  「今日入力」が更新される）、「引き落としを反映」のシートを操作した。ブラウザのコンソールエラーは 0 件
- ウィジェットテストで、ホームが幅 320/390/1280 × 文字 1.0/1.3 倍ではみ出さないこと、根拠の確定/見込みの表示、
  以前のホームの操作が残っていること、同期の競合の表示を確かめた
- 色だけで区別しない: 金額は +/− と記号、確定/見込みは文字、足りない日は「⚠ 残高が足りない日」の文字

## 9. 未検証のこと・既知の問題・残っている懸念

### 実環境で確かめていないもの

- **Google 連携（Gmail・Drive・Calendar）は実アカウントで動かしていない。** Drive は偽の `DriveStore` でのテストだけ。
  Gmail の取り込みとカレンダーは今回コードを変えていないが、`GoogleDriveStore` は旧 `fetch`/`upload` を移した新しいクラスなので、
  実際のドライブでの読み書きは要確認
- **iOS・Android はビルドしていない**（この環境では iOS はビルドできない）
- 実データでの見え方（明細の多い月、長いカード名、localStorage の容量）

### 既知の問題・判断して残したもの

- 休みで翌月にずれた引落の**銀行確定メール**は、日付だけではどの月の請求か分からず、翌月の確定として数えられる（メールに請求月が無い）
- 確認待ちの引き落としは予想のゲートで消さない（レビューの指示どおり）。残高を引落日の後に書き直した場合、
  確認待ちで「引く」を押すと二重に引ける。今は利用者の判断に任せている
- 残高を一度も書いていないときの給料の入金月は、勤務先ごとではなく最頻値の締め（`paydayOffsetMonths`）で計算する（変更前のまま）
- 年間支出の「うち設定から計算」には、アプリを使う前の月の定期も入る（定期に開始日が無いため）。推定であることは表示している
- `thisMonthBreakdown` などの Map 版の内訳は、画面では使わなくなりテストだけが使う（互換のため残した）
- `MainNavigationScreen` が足すリスナーは外していない（変更前のまま）
- 明細の ID は取り込みのたびに作り直される（変更前のまま。画面が ID を持ち続ける操作があるかは未確認）
- `saveData` の失敗は、取り込み以外の通常の操作では利用者に見えない（変更前のまま）
- Flutter 3.47 以降の `material_ui` への移行は未対応（予告の info だけで、今のビルドには影響しない）
- 金額の表示形式が 2 種類ある（`AnimatedAmount` の「¥ 85,000」と `MoneyText` の「¥85,000」）
- 計画にあった「カレンダーの一覧で種類を文字で出す」と、推移・内訳など他の画面の見た目の統一は手を付けていない
- `GmailService` から解析を分ける作業（計画の「任意」）はしていない
- `pubspec.lock` は、この環境の Flutter で `pub get` すると SDK 同梱パッケージの版が変わるが、コミットしていない

### レビューで特に見てほしいところ

- `forecastMonths` の振り分け（前月分の行・今月以前にずれた行の扱い）が意図どおりか
- `pendingDraws` の ID の互換の扱い
- `importJson` の失敗時の巻き戻し（保存の途中で失敗したとき、メモリと端末の保存内容の関係）
- `pushNow` で同期済みにする時刻（`dataUpdatedAt` を使う）が、`decideSyncState` の判定と食い違わないか
- `_expenseItemsOf` の `fromSettings` の定義（何を「設定から計算」とみなすか）
