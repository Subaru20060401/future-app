#!/bin/bash
# 💡 iPhoneがMacに繋がったら、ポケットメイドを自動でビルド＆再インストールする。
#   次のどちらかに当てはまるときだけ動く（それ以外は数秒で終了）:
#     ① 前回のインストールから5日以上（無料署名は7日で失効するため）
#     ② ソースコードが前回のインストール時から変わっている（新機能をすぐ届ける）
#   launchd（com.subaru.pocketmaid.autoinstall）から5分おきに呼ばれる。

set -u

# launchd から起動されると PATH が最小限なので、必要なコマンドの場所を明示する
export PATH="/Users/subaru/development/flutter/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin"

PROJECT="/Users/subaru/development/my_counter_app"
FLUTTER="/Users/subaru/development/flutter/bin/flutter"
DEVICE="00008150-00057D3636F8401C"        # iPhone の UDID
STAMP="$HOME/.pocket-maid-last-install"    # 最後に成功した日時
HASHFILE="$HOME/.pocket-maid-last-hash"    # 最後にインストールしたソースの指紋
LOG="$HOME/Library/Logs/pocket-maid-autoinstall.log"
INTERVAL_DAYS=5                            # 何日ごとに入れ直すか（署名は7日で失効）

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"ポケットメイド\"" >/dev/null 2>&1; }

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# ── 二重起動を防ぐ（ビルド中にもう1つ走るとXcodeがぶつかって失敗する） ──
LOCKDIR="/tmp/pocket-maid-autoinstall.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # 30分以上残っているロックは、前回異常終了とみなして奪う
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rm -rf "$LOCKDIR" && mkdir "$LOCKDIR" 2>/dev/null || exit 0
    log "古いロックを解除しました"
  else
    exit 0 # すでに実行中
  fi
fi
trap 'rm -rf "$LOCKDIR"' EXIT

# ── ソースコードの指紋（lib配下・pubspec・iOS設定の中身から作る） ──
source_hash() {
  {
    find "$PROJECT/lib" -type f -name '*.dart' -exec md5 -q {} \; 2>/dev/null
    md5 -q "$PROJECT/pubspec.yaml" 2>/dev/null
    md5 -q "$PROJECT/ios/Runner/Info.plist" 2>/dev/null
  } | sort | md5 -q
}

CURRENT_HASH="$(source_hash)"
LAST_HASH="$(cat "$HASHFILE" 2>/dev/null || echo '')"

# ── ① 入れ直す理由があるか判定（無ければ何もしない＝CPUを使わない） ──
REASON=""
if [ $FORCE -eq 1 ]; then
  REASON="手動実行"
elif [ "$CURRENT_HASH" != "$LAST_HASH" ]; then
  REASON="新しいバージョン"
elif [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  AGE_DAYS=$(( ($(date +%s) - LAST) / 86400 ))
  [ "$AGE_DAYS" -ge "$INTERVAL_DAYS" ] && REASON="署名の更新（${AGE_DAYS}日経過）"
else
  REASON="初回"
fi
[ -z "$REASON" ] && exit 0

# ── ② iPhoneが繋がっているか（数秒で判定。繋がっていなければ静かに終了） ──
if ! /usr/bin/xcrun devicectl device info details --device "$DEVICE" --timeout 8 >/dev/null 2>&1; then
  exit 0
fi

# ── 署名の残り日数を確認し、切れる前に知らせる ──
#   無料アカウントのプロファイルは7日で失効する。失効後の再作成には
#   XcodeにApple IDのログインが必要なので、余裕のあるうちに促す。
check_profile_expiry() {
  local dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  local newest
  newest="$(ls -t "$dir"/*.mobileprovision 2>/dev/null | head -1)" || return 0
  [ -z "$newest" ] && return 0
  local exp
  exp="$(security cms -D -i "$newest" 2>/dev/null | python3 -c "
import sys,plistlib,datetime
try:
    d=plistlib.loads(sys.stdin.buffer.read())
    print(int((d['ExpirationDate']-datetime.datetime.now()).total_seconds()//86400))
except Exception:
    print(99)
" 2>/dev/null)"
  [ -z "$exp" ] && return 0
  if [ "$exp" -le 2 ]; then
    log "署名の残り ${exp}日"
    notify "署名の残りあと${exp}日です。Xcode → Settings → Accounts でサインインしておくと安心です"
  fi
}
check_profile_expiry

log "iPhoneを検出（$REASON）。ビルドを開始します。"

# ── ③ ビルド ──
cd "$PROJECT" || { log "プロジェクトが見つかりません: $PROJECT"; exit 1; }
BUILD_OUT="$(mktemp)"
build_once() { LANG=en_US.UTF-8 "$FLUTTER" build ios --release >"$BUILD_OUT" 2>&1; }

if ! build_once; then
  cat "$BUILD_OUT" >> "$LOG"
  # 「No Accounts / No profiles」は署名セッション切れ。少し待って1回だけ再試行する
  #   （Xcodeがプロファイルを作り直せることがあるため）
  if grep -qE "No Accounts|No profiles for" "$BUILD_OUT"; then
    log "署名エラーを検出。60秒待って再試行します。"
    sleep 60
    if build_once; then
      cat "$BUILD_OUT" >> "$LOG"
      log "再試行でビルド成功"
    else
      cat "$BUILD_OUT" >> "$LOG"
      log "❌ 署名エラー（XcodeでApple IDに再サインインしてください）"
      notify "署名が切れています。Xcode → Settings → Accounts で再サインインしてください"
      rm -f "$BUILD_OUT"
      exit 1
    fi
  else
    log "❌ ビルド失敗"
    notify "ビルドに失敗しました（ログを確認してください）"
    rm -f "$BUILD_OUT"
    exit 1
  fi
fi
cat "$BUILD_OUT" >> "$LOG"
rm -f "$BUILD_OUT"

# ── ④ インストール（データは保持される） ──
if /usr/bin/xcrun devicectl device install app --device "$DEVICE" \
      "$PROJECT/build/ios/iphoneos/Runner.app" >>"$LOG" 2>&1; then
  date +%s > "$STAMP"
  echo "$CURRENT_HASH" > "$HASHFILE"
  log "✅ インストール成功（$REASON）"
  notify "アプリを最新に更新しました（$REASON）"
else
  log "❌ インストール失敗（iPhoneのロックを解除してください）"
  notify "インストールに失敗しました。iPhoneのロックを解除してください"
  exit 1
fi
