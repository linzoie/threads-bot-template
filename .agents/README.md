# `.agents/` — Antigravity 守門

由 `sync-governance.ps1` 從 `project-template/.agents/` 推送到各子專案。

| 檔案 | 用途 |
|---|---|
| `hooks.json` | Antigravity 的 PreToolUse 接線設定 |
| `antigravity-guard.ps1` | 薄 shim，dot-source `../.claude/hooks/guard-core.ps1` 取得判定 |
| `.gitignore` | 排除執行期 `*.log` |
| `hook-calls.log` | 執行期紀錄（不進版控） |

## ⛔ `hooks.json` 裡**絕對不能**放註解欄位

**2026-07-27 花了整輪 debug 才找到的坑。**

Antigravity 的解析器（Go）把 **hooks.json 的每一個頂層 key 都當成 hook 名稱**，
對應到一個 `JSONHookSpec` 物件。放一個 `"_comment": "字串"` 進去，
解析就會失敗：

```
hooks.go:44] Failed to parse hooks file ...\.agents\hooks.json:
  json: cannot unmarshal string into Go struct field ._comment of type jsonhook.JSONHookSpec
```

**而失敗的後果是整個檔案被丟棄——所有 hook 都不生效，且 GUI 上完全沒有任何徵兆。**
唯一的痕跡在 `%APPDATA%\Antigravity\logs\language_server.log`，不會有人主動去看。

當時的症狀與排查（留給下一個人，免得重走）：

- 守門腳本本身完全正常——三種呼叫方式（`cmd /c` + bare 檔名 + cwd、直接
  powershell、絕對路徑）實測皆正確回傳 `{"decision":"deny",...}`
- 曾誤判為：常駐進程沒重讀（重開無效）、專案沒註冊（有註冊）、
  巢狀 git repo 影響 walk-up（非巢狀目錄也一樣）、App 版本過舊（更新到 2.4.2 仍舊）
- 連「零相依最小探針」都不觸發——因為**探針的 hooks.json 也被加了 `_comment`**
- 對照組：2026-07-24 唯一運作過的 fixture，其 hooks.json **只有一個頂層 key、沒有註解**

**要寫說明就寫在這個 README 或 `antigravity-guard.ps1` 的檔頭，不要碰 hooks.json。**

機械防線：`governance-doctor.ps1` 已加入 hooks.json schema 檢查
（頂層 key 必須全部對應到物件），這個錯誤現在會被健檢當場抓到。

## 生效條件

Antigravity 的 rules/hooks 只在該資料夾**已登記為 Antigravity workspace** 時生效
（不像 Claude Code 開目錄即生效）。discovery 從 CWD 往上走到 repository root
（含 `.git` 的資料夾）。

## 判定邏輯要改哪裡

**改 `.claude/hooks/guard-core.ps1`**（三家 adapter 共用），不要改這裡的 shim
——改 shim 只會重建 per-adapter 分歧。shim 只負責 I/O 與輸出映射：

| core 判定 | Antigravity 輸出 |
|---|---|
| `deny` | `{"decision":"deny","reason":...}` |
| `ask` | `{"decision":"force_ask",...}`（**不是** `ask`——force_ask 忽略「Always Allow」快取） |
| `pass` | `{}`（**不是** `allow`——allow 是主動核准，會蓋掉使用者自己的權限設定） |