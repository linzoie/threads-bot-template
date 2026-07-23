---
paths:
  - "**/*.js"
  - "**/*.mjs"
  - "**/*.cjs"
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.jsx"
---

# Node/前端專案紀律（碰到 JS/TS 才載入）

> format 由 after-edit hook 自動跑（prettier），這裡只講「驗證與完成」該確認的事，
> 不重述 hook 已強制的東西。

## 驗證與 DoD

- `prettier --check .` **0 errors**（after-edit 已自動 --write；驗證階段確認無殘留）。
- 有 `test` script → Stop hook 會跑；宣稱完成前**自己也實跑一次**貼輸出。
  無 test script 的專案：Stop hook 只驗格式（**綠燈只代表格式對、不代表行為對**），
  改動涉及邏輯時必須手動實跑或補測試，勿僅憑 hook 放行宣稱完成。
- 有 build（vite/自製 build.mjs）→ 手動確認產出正常（Stop hook 因耗時未納入）。
- 有 `lint` script（eslint）→ **0 errors** 才算完成（抓孤兒 import／未用變數；
  僅已有 devDeps 的專案逐案引入，「零相依」專案不為此破戒——2026-07-21 裁定）。
- 完成門檻：測試綠（若有）+ prettier 綠 + lint 綠（若有）+ 跑得起來的功能用實際執行確認（UI 工具要眼睛看）。

## 慣例

- 不確定外部函式庫 API → 查最新官方文件，不憑記憶編造。
- **改既有 code 先用 Grep 結構檢索**（符號、精確 pattern）定位真實定義再動手，勝過憑語意/
  記憶猜測——結構檢索 precision 遠高，避免改到過期或想像的位置（grounding 機械化 2026-07-11）。
- 平台/工具特定行為（wrangler/Cloudflare/Netlify/建置設定）→ 查官方文件確認版本行為，不憑記憶。
- 模組化與命名見專案自身 CLAUDE.md 的 module conventions。
