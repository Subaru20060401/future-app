# 引き継ぎメモ（未対応の課題）

Mac で行ったコード全体の点検（2026-10-21）の結果と、決まっていないこと。
対応したら該当の項目を消すこと。全部片付いたらこのファイルごと消してよい。

点検は「どこからも参照されていないか」「同じコードが複数あるか」を機械的に数えたうえで、
中身を確認して判断した。

## A. 先に直すべき不具合（データが消えうる）

**Gmail 取り込みの入口が 2 つあり、片方が安全装置を通っていない。**

- 普段の更新: `syncGmail`（`lib/gmail_sync.dart`）
  → 取得できなかったメールが 1 件でもあれば反映しない（`lastFetchFailures`）。先月 1 日から取得
- 設定 →「メールの取得結果を見る」→ 取得: `GmailScreen._fetch`（`lib/screens/gmail_screen.dart`）
  → `fetchCardPayments()` を `since` なしで呼び（毎回 2 年分）、
  **`lastFetchFailures` を見ずに `reconcilePayments` する**。
  取りこぼしがあると、その明細が消える

直し方: `GmailScreen` も `syncGmail(appState, full: true)` を通す。
画面で取得結果の一覧を見せたいなら、`syncGmail` か `GmailService` から一覧を受け取れるようにする。

## B. 確実に使われていないもの（消してよい）

- `lib/calendar_sync.dart`（Apple カレンダー連携。Google カレンダーに置き換えて以来どこからも読まれていない）
  と、それだけが使っている依存 `device_calendar`
- 依存 `cupertino_icons`（参照ゼロ）
- `app_state.dart` の関数: `addEvent`（`upsertEvent` に置き換わった）、`paydayDaysInMonth`、
  `paymentDaysInMonth`（カレンダーの点は画面側で数えている）、`loanTotalFromAccountOf`、
  `subscriptionFromAccountTotal`
- `GmailSyncResult.notSignedIn`（立てる箇所がゼロ）

⚠️ `download_file_web.dart` と `google_redirect_auth_web.dart` は条件付きエクスポートで
使われているので消さない（単純な import 検索では「未使用」に見える）。

## C. 重複（同じものが複数ある）

お金の計算に関わるものから先にまとめる。

- **「分割の何回目か」の計算** `(month.year - start.year) * 12 + (month.month - start.month)` が
  `app_state.dart` に 5 か所
- **連携判定が `hasGmailAccess` と `isUsable` の 2 種類**。
  以前「設定では連携済みなのに更新は未連携」になった原因と同じ種類の食い違いが再発しうる。`isUsable` に寄せる
- `PlannedExpense` と `PlannedIncome` がクラスまるごと同じ。シート
  （`planned_expense_sheet.dart` / `planned_income_sheet.dart`）もほぼ同じ
- シフトの入力（`add_entry_sheets.dart`）と編集（`calendar_screen.dart`）のフォームが別々に約 70 行
- 分割に変換／分割を編集のダイアログ（`payment_screen.dart`）の回数・金利表示
- ローン画面が総額・支払総額をその場で計算している（`Loan.totalPrice` / `totalCost` を使うべき）
- 小さなヘルパー: `_toSource` が 2 ファイル、日付整形の `_fmt` が 4 ファイル

## D. 機能はあるのに画面から使えない（足すか消すか要判断）

テストからしか呼ばれていない: `markPlannedExpensePaid`（予定支出を払い済みに）、
`unmergeCardName`（カードのまとめを解除）、`lockNow`（今すぐロック）。
ほかに本番で使われなくなったもの: `installmentTotalOf`（分割をカード別に変えたため。テストが 7 か所で使う）、
`setActualSalary`（旧方式の月合計。今は勤務先別）。

## E. iOS をやめたことで役目を終えたもの（要判断）

Web 版では一切動かない: `tools/auto_install.sh`、`ios/`・`macos/`、
Face ID（`local_auth`）、端末通知（`flutter_local_notifications` / `notification_service.dart`）、
端末アプリの自動バックアップと共有（`path_provider` / `share_plus`）。
消すと将来アプリ版に戻すとき作り直しになるので、本人の判断で。

設定の 🔧 デバッグ 4 項目は、カード会社がメールの書式を変えたときの調査に使うので残す。

## 決まっていないこと

- **Gemini の課金**: Gemini API キーのプロジェクトに請求先アカウントが紐づいていて（有料 Tier 1・前払い残高 0 円）、
  API は `402 Payment Required` で止まっている。自動では無料枠に戻らない。
  無料で使うなら Google Cloud コンソールで「課金を無効にする」（プロジェクトのリンク解除）。
  解除すると無料枠になり、送ったデータが Google の改善に使われる（下の CLAUDE.md の Gemini 節）。
  本人がどちらにするか未決定
- **402 の表示**: `describeGeminiError` が 402 を扱っておらず「Geminiでエラーが起きました（402）」としか出ない。
  「前払い残高が 0 円で止まっている」と分かる文にする
- **Android（Galaxy）での Google ログインは未確認**: 端末を Galaxy に変え、Chrome から PWA としてインストール済み。
  リダイレクト認証に切り替える `isPopupUnfriendly` は iPhone/iPad しか見ていない。
  Android で連携できなければ、ここに Android を足す
- **メールから予定を提案する案**: メール本文を Gemini に送ることになる。無料枠は個人情報を送るべきでない
  （規約）ので、有料にするか、AI を使わず定型メールからルールで日時を抜き出すかを先に決める
