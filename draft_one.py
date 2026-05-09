r"""Paste any stranger post text → Claude drafts a reply in your brand voice.

Workaround for dev-mode keyword_search limit. You scroll Threads manually,
find interesting posts, paste them here, get an AI draft you can post.

Usage:
    .\.venv\Scripts\python.exe draft_one.py
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

import pyperclip
import webbrowser

from src import drafter


def read_post_text() -> str:
    print("\n貼上貼文內容（多行 OK，最後留一個空行結束）：")
    print("-" * 60)
    lines = []
    while True:
        line = input()
        if not line and lines:
            break
        if line:
            lines.append(line)
    return "\n".join(lines).strip()


def main():
    print("=" * 70)
    print("  Stranger Post Drafter")
    print("=" * 70)
    print("把你在 Threads 看到的貼文文字貼進來，Claude 會用你的品牌語氣")
    print("評估該不該留言並草擬回覆。Ctrl+C 隨時離開。")

    while True:
        try:
            text = read_post_text()
        except (KeyboardInterrupt, EOFError):
            print("\n[bye]")
            break

        if not text:
            print("（空白，跳過）")
            continue

        username = input("作者 @ (可省略，按 Enter 跳過): ").strip()
        url = input("貼文連結 URL (可省略，按 Enter 跳過): ").strip()

        print("\n正在請 Claude 評估...")
        try:
            decision = drafter.draft_for_stranger_post(text, username)
        except Exception as e:
            print(f"[error] {e}")
            continue

        print("\n" + "=" * 70)
        print(f"score        : {decision.get('score', 0):.2f}")
        print(f"should_engage: {decision.get('should_engage')}")
        print(f"reason       : {decision.get('reason', '')}")
        print(f"\nClaude 草稿：")
        print(f"  {decision.get('reply') or '(略過，不建議留言)'}")
        print("=" * 70)

        if decision.get("should_engage") and decision.get("reply"):
            action = input("\n[A] 複製並開瀏覽器  [E] 編輯  [N] 下一則  [Q] 結束 > ").strip().lower()
            if action == "a":
                pyperclip.copy(decision["reply"])
                if url:
                    webbrowser.open(url)
                print("✅ 草稿已複製到剪貼簿。" + ("瀏覽器已開啟。" if url else ""))
            elif action == "e":
                print("輸入修改後的回覆（單行）：")
                edited = input("> ").strip()
                if edited:
                    pyperclip.copy(edited)
                    if url:
                        webbrowser.open(url)
                    print("✅ 修改後的草稿已複製到剪貼簿。")
            elif action == "q":
                break
            # n 或其他 → 直接下一則
        else:
            cont = input("\nClaude 建議不要留言。按 Enter 試下一則，Q 結束 > ").strip().lower()
            if cont == "q":
                break


if __name__ == "__main__":
    main()
