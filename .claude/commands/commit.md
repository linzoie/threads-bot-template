---
description: 依 staged 變更產生 Conventional Commits 訊息並提交
model: haiku
allowed-tools: Bash(git:*)
---

檢視目前 staged 的變更：

- staged 摘要：!`git diff --cached --stat`
- staged 內容：!`git diff --cached`
- 近期 commit 風格參考：!`git log --oneline -5`

任務：

1. 若沒有任何 staged 變更，提醒使用者先 `git add`，然後停止。
2. 先確認沒有 `.env` 或機密檔案被 staged；若有，**停止並警告使用者**，不要提交。
3. 依 Conventional Commits 格式（`feat` / `fix` / `refactor` / `docs` / `test` / `chore`）
   寫一行精準的 commit 標題；變更較複雜時可加簡短內文。
4. 執行 `git commit`。不要額外加說明文字或 emoji。