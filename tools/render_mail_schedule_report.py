"""実メールの評価結果を、外部通信しないローカルHTMLにする。本文はGit管理外に置く。"""
import html
import json
import sys
from pathlib import Path
from collections import Counter

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".dart_tool/mail_schedule_eval")
before = json.loads((root / "before.json").read_text(encoding="utf-8"))
after = json.loads((root / "after.json").read_text(encoding="utf-8"))
app = json.loads((root / "app-result.json").read_text(encoding="utf-8"))
old = {m["id"]: m for m in before["mails"]}
pending = {s["messageId"] for s in app["pending"]}
pending_entities = {s["entityKey"] for s in app["pending"]}
scanned = set(app.get("scannedMessageIds", [m["id"] for m in after["mails"]]))
rows = []
counts = Counter()
for m in after["mails"]:
    ss = m["suggestions"]
    if m["id"] not in scanned:
        status, reason = "期間外", "初回の取り込み期間（直近30日）より前"
    elif m["id"] in pending:
        status, reason = "確認待ち", "本人の予約確定と日時を確認"
    elif ss and any(s["entityKey"] in pending_entities for s in ss):
        status, reason = "重複抑制", "同じ予約の別メールと照合し、候補を1件にまとめました"
    elif ss and all(s["action"] == "cancel" for s in ss):
        status, reason = "取消履歴", "登録先がない取消は照合履歴だけに残す"
    elif ss and all(s["past"] for s in ss):
        status, reason = "過去", "終了した予定は追加しない"
    else:
        status, reason = "除外", m["skipReason"] or "対象外"
    counts[status] += 1
    values = "<br>".join(html.escape(str(s.get("start") or "未定") + " ～ " + str(s.get("end") or "終了未記載")) for s in ss)
    prev = old.get(m["id"], {}).get("suggestions", [])
    previous = "<br>".join(html.escape(str(s.get("start") or "日時未定") + " / " + s["action"]) for s in prev) or "候補なし"
    actual = "cancellation" if any(s["action"] in ("cancel", "change") for s in ss) else "keep" if ss else "exclude"
    evidence = " / ".join(s.get("evidence", "") for s in ss)
    rows.append(f'<tr data-status="{status}" data-actual="{actual}" data-id="{html.escape(m["id"], quote=True)}"><td>{status}</td><td>{html.escape(m["subject"])}<details><summary>本文・根拠を確認</summary><p>{html.escape(evidence)}</p><pre>{html.escape(m["body"])}</pre></details></td><td>{previous}</td><td>{values or "候補なし"}<p>{html.escape(reason)}</p></td><td><select class="verdict"><option value="">未評価</option><option value="keep">予定として必要</option><option value="exclude">不要</option><option value="cancellation">取消・変更として必要</option></select><p class="assessment"></p></td></tr>')
summary = " / ".join(f"{k} {v}通" for k, v in counts.items())
candidate_rows = "".join(f'<tr><td>{html.escape(s["title"])}</td><td>{html.escape(s["start"] or "未定")} ～ {html.escape(s["end"] or "終了未記載")}</td><td>{html.escape(s["location"])}</td></tr>' for s in app["pending"])
page = """<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>メール予定抽出の比較結果</title>
<style>body{font:16px/1.7 system-ui,sans-serif;margin:24px;color:#232332;background:#faf9fc}h1{font-size:26px}header{max-width:1100px}.note{color:#555}nav{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}input,select,button{padding:10px;font:inherit;border:1px solid #bbb;border-radius:8px;background:white}table{border-collapse:collapse;width:100%;background:white}th,td{text-align:left;vertical-align:top;padding:14px;border-bottom:1px solid #ddd}th{background:#f0eafa}td:nth-child(2){min-width:240px}td:nth-child(3),td:nth-child(4){min-width:160px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.6 system-ui;max-height:480px;overflow:auto;background:#f6f5fa;padding:12px}details{margin-top:12px}summary{cursor:pointer;color:#6041a0}.table{overflow:auto}button{cursor:pointer}td:first-child{font-weight:bold}tr[data-status="確認待ち"]{background:#edf9f2}</style>
<header><h1>メールから予定を探す：変更前後の比較</h1>
<p>評価基準：__NOW__（日本時間）／規則版__VERSION__／AI APIは使用していません。</p>
<p><b>取得__TOTAL__通 → 取り込み期間内__CHECKED__通 → 確認待ち__PENDING__件</b></p>
<p>__SUMMARY__</p>
<p class="note">抽出のみは__BEFORE__件→__AFTER__件。変更後の抽出には過去の予約と取消履歴が含まれ、確認待ちとは件数が異なります。件数の減少は精度の証明ではありません。「不要」だけでなく、除外した中に必要な予定がないかも評価してください。</p>
<p class="note">スマホと同じDartの解析・取り込みサービス・AppStateで再生。メール取得は接続済みGmailツールを利用しているため、スマホの認証・取得通信そのものの検証ではありません。文字化けや未対応の旅程表は見逃す可能性があります。スマホ固有の登録履歴・見本データは含みません。</p>
<p class="note">このファイルにはメール本文が含まれます。ローカル専用・Git管理外です。公開サイトへの配置やコミットはしないでください。ページを閉じる前に評価JSONを保存すれば、次回の比較へ読み込めます。</p></header>
<h2>アプリに出る確認待ち</h2><div class="table"><table><thead><tr><th>予定</th><th>日時</th><th>場所</th></tr></thead><tbody>__CANDIDATES__</tbody></table></div>
<h2>メールごとの比較・評価</h2>
<p>手動評価は抽出の正誤を比較します。過去・重複でも、実際の予約なら「予定として必要」を選んでください。未評価のメールは一致率の分母に含めません。</p><p id="metrics"></p>
<nav><input id="search" placeholder="件名・本文・理由で検索"><select id="filter"><option value="">全件</option><option>確認待ち</option><option>重複抑制</option><option>除外</option><option>過去</option><option>取消履歴</option><option>期間外</option><option value="mismatch">手動評価と不一致</option></select><button id="export">手動評価をJSONで保存</button><label>保存した評価を読む <input id="import" type="file" accept="application/json,.json"></label><span id="count"></span></nav>
<div class="table"><table><thead><tr><th>結果</th><th>メール</th><th>変更前の抽出</th><th>変更後・理由</th><th>あなたの判断</th></tr></thead><tbody>__ROWS__</tbody></table></div>
<script>
const rows=[...document.querySelectorAll('tr[data-id]')], search=document.querySelector('#search'), filter=document.querySelector('#filter');
function update(){let n=0,labeled=0,matched=0,falsePositive=0,missed=0;for(const r of rows){const expected=r.querySelector('.verdict').value, mismatch=!!expected&&expected!==r.dataset.actual;if(expected){labeled++;if(!mismatch)matched++;if(expected==='exclude'&&r.dataset.actual!=='exclude')falsePositive++;if(expected!=='exclude'&&r.dataset.actual==='exclude')missed++;}r.querySelector('.assessment').textContent=expected?(mismatch?'不一致':'一致'):'';r.hidden=(filter.value==='mismatch'?!mismatch:!!(filter.value&&r.dataset.status!==filter.value))||!r.textContent.toLowerCase().includes(search.value.toLowerCase());if(!r.hidden)n++;}document.querySelector('#count').textContent=n+'通を表示';document.querySelector('#metrics').textContent=`評価済み ${labeled}通 / 一致 ${matched}通 / 不一致 ${labeled-matched}通（不要な抽出 ${falsePositive}通・見逃し ${missed}通） / 未評価 ${rows.length-labeled}通`;}
search.addEventListener('input',update);filter.addEventListener('change',update);update();
for(const r of rows)r.querySelector('.verdict').addEventListener('change',update);
document.querySelector('#import').onchange=async e=>{try{const data=JSON.parse(await e.target.files[0].text());if(!Array.isArray(data.labels))throw new Error('labels配列がありません');const labels=new Map(data.labels.filter(x=>x&&typeof x.id==='string'&&['keep','exclude','cancellation'].includes(x.expected)).map(x=>[x.id,x.expected]));for(const r of rows)if(labels.has(r.dataset.id))r.querySelector('.verdict').value=labels.get(r.dataset.id);update();}catch(err){alert('評価JSONを読めませんでした: '+err.message);}};
document.querySelector('#export').onclick=()=>{const labels=rows.filter(r=>r.querySelector('.verdict').value).map(r=>({id:r.dataset.id,expected:r.querySelector('.verdict').value}));const url=URL.createObjectURL(new Blob([JSON.stringify({labels},null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='mail-schedule-labels.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
</script></html>"""
(root / "report.html").write_text(page.replace("__SUMMARY__", html.escape(summary)).replace("__CANDIDATES__", candidate_rows).replace("__ROWS__", "".join(rows)).replace("__NOW__", html.escape(after["now"])).replace("__VERSION__", str(after["rulesVersion"])).replace("__TOTAL__", str(after["checked"])).replace("__CHECKED__", str(app["checked"])).replace("__PENDING__", str(len(app["pending"]))).replace("__BEFORE__", str(sum(len(m["suggestions"]) for m in before["mails"]))).replace("__AFTER__", str(sum(len(m["suggestions"]) for m in after["mails"]))), encoding="utf-8")
print(summary)
print(root / "report.html")
