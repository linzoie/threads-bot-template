---
paths:
  - "**/*.py"
---

# Python 專案紀律（碰到 .py 才載入）

> format 由 after-edit hook 自動跑（ruff format），這裡只講「驗證與完成」該確認的事，
> 不重述 hook 已強制的東西。

## 驗證與 DoD

- `ruff check` **0 errors**（after-edit 已自動 format+fix；驗證階段確認無殘留）。
- 測試多為純 `assert` 腳本（無 pytest）。有 `tests/run_all.py` 就是統一入口，
  Stop hook 會自動跑；宣稱完成前**自己也實跑一次**貼輸出。
- 若有 mypy／pytest（venv 內存在才跑）→ 一併綠燈。
- 完成門檻：ruff 綠 + 測試綠（實跑看到）+ 跑得起來的功能用實際執行確認行為。

## 慣例

- 不確定外部函式庫 API → 查最新官方文件，不憑記憶編造。
- **改既有 code 先用 Grep 結構檢索**（符號、精確 pattern）定位真實定義再動手，勝過憑語意/
  記憶猜測——結構檢索 precision 遠高，避免改到過期或想像的位置（grounding 機械化 2026-07-11）。
- 純 assert 測試的斷言要驗**行為**不是只驗「跑得完」；別 mock 掉要驗的東西。
