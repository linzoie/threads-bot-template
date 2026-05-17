"""Interactive CLI to review pending drafts and (manually) post them.

Each draft you 'approve' is copied to your clipboard and the original post is
opened in your browser. You then paste + post by hand. Nothing is sent via API.
"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

import webbrowser

import pyperclip

from src import draft_state


def show(draft: dict, idx: int, total: int) -> None:
    print("\n" + "=" * 72)
    print(f"  [{idx}/{total}]   score: {draft.get('score', 0):.2f}   keyword: {draft.get('matched_keyword','')}")
    print("=" * 72)
    print(f"By       : @{draft.get('post_username','?')}")
    print(f"Posted   : {draft.get('post_timestamp','')[:19]}")
    print(f"Permalink: {draft.get('post_permalink','(none)')}")
    print(f"\n--- Original post ---")
    print(f"  {draft.get('post_text','').strip()}")
    print(f"\n--- Claude's reasoning ---")
    print(f"  {draft.get('reason','')}")
    print(f"\n--- Draft reply ---")
    print(f"  {draft.get('reply','')}")
    print()


def prompt_action() -> str:
    print("[A]pprove (copy + open browser) | [E]dit | [S]kip | [D]elete | [N]ext page | [Q]uit")
    return input("> ").strip().lower()


def main():
    drafts = draft_state.load_pending()
    if not drafts:
        print("No pending drafts. Run find_drafts.py first.")
        return

    drafts.sort(key=lambda d: d.get("score", 0), reverse=True)
    print(f"\n{len(drafts)} pending draft(s), highest score first.\n")

    for i, draft in enumerate(drafts, 1):
        show(draft, i, len(drafts))
        while True:
            action = prompt_action()
            if action in ("a", "approve"):
                pyperclip.copy(draft.get("reply", ""))
                if draft.get("post_permalink"):
                    webbrowser.open(draft["post_permalink"])
                draft_state.mark_processed(draft, "approved")
                print("✅ Reply copied to clipboard. Browser opened. Paste + post manually.")
                break
            if action in ("e", "edit"):
                print("Edit reply (paste your edited version, end with empty line):")
                lines = []
                while True:
                    line = input()
                    if not line:
                        break
                    lines.append(line)
                edited = "\n".join(lines).strip()
                if not edited:
                    print("(empty edit — try again)")
                    continue
                pyperclip.copy(edited)
                if draft.get("post_permalink"):
                    webbrowser.open(draft["post_permalink"])
                draft_state.mark_processed(draft, "edited", edited_reply=edited)
                print("✅ Edited reply copied. Browser opened.")
                break
            if action in ("s", "skip"):
                draft_state.mark_processed(draft, "skipped")
                print("→ skipped")
                break
            if action in ("d", "delete"):
                draft_state.mark_processed(draft, "deleted")
                print("→ deleted")
                break
            if action in ("n", "next"):
                print("→ leave for later (not processed)")
                break
            if action in ("q", "quit"):
                print(f"\n[stopped at {i}/{len(drafts)}]")
                return
            print("(unrecognized — pick A / E / S / D / N / Q)")

    print(f"\nDone. Reviewed {len(drafts)} draft(s).")


if __name__ == "__main__":
    main()
