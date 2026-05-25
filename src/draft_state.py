"""Persistent draft queue for Feature #2.

draft_queue.jsonl     pending drafts awaiting review
processed_drafts.jsonl drafts you've acted on (approved / edited / skipped / deleted)
"""
import json
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)

QUEUE = DATA / "draft_queue.jsonl"
PROCESSED = DATA / "processed_drafts.jsonl"


def append_draft(draft: dict) -> None:
    with QUEUE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(draft, ensure_ascii=False) + "\n")


def load_pending() -> list[dict]:
    if not QUEUE.exists():
        return []
    out = []
    for line in QUEUE.read_text(encoding="utf-8").splitlines():
        if line.strip():
            out.append(json.loads(line))
    return out


def already_drafted_ids() -> set[str]:
    """Posts we've already drafted for (in pending + processed). Avoid duplicates."""
    ids = set()
    if QUEUE.exists():
        for line in QUEUE.read_text(encoding="utf-8").splitlines():
            if line.strip():
                ids.add(json.loads(line).get("post_id"))
    if PROCESSED.exists():
        for line in PROCESSED.read_text(encoding="utf-8").splitlines():
            if line.strip():
                ids.add(json.loads(line).get("post_id"))
    ids.discard(None)
    return ids


def mark_processed(draft: dict, action: str, edited_reply: str | None = None) -> None:
    """Move draft from QUEUE → PROCESSED with action recorded.

    action: approved | edited | skipped | deleted
    """
    entry = {
        **draft,
        "action": action,
        "processed_at": datetime.now(UTC).isoformat(),
        "final_reply": edited_reply if edited_reply else draft.get("reply"),
    }
    with PROCESSED.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    # Rewrite QUEUE without this draft
    remaining = [d for d in load_pending() if d.get("post_id") != draft.get("post_id")]
    QUEUE.write_text(
        "\n".join(json.dumps(d, ensure_ascii=False) for d in remaining) + ("\n" if remaining else ""),
        encoding="utf-8",
    )
