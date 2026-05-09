"""Persistent state: which comments we've already replied to, and the human-review queue."""
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
DATA.mkdir(exist_ok=True)

REPLIED_FILE = DATA / "replied_ids.json"
HUMAN_QUEUE = DATA / "human_queue.jsonl"
ACTION_LOG = DATA / "actions.jsonl"


def _load_replied() -> set[str]:
    if not REPLIED_FILE.exists():
        return set()
    return set(json.loads(REPLIED_FILE.read_text(encoding="utf-8")).get("ids", []))


def is_replied(comment_id: str) -> bool:
    return comment_id in _load_replied()


def mark_replied(comment_id: str) -> None:
    ids = _load_replied()
    ids.add(comment_id)
    REPLIED_FILE.write_text(
        json.dumps({"ids": sorted(ids)}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def add_to_human_queue(comment: dict, parent_post: dict, reason: str) -> None:
    entry = {
        "queued_at": datetime.now(timezone.utc).isoformat(),
        "reason": reason,
        "comment": comment,
        "parent_post": {"id": parent_post.get("id"), "text": parent_post.get("text")},
    }
    with HUMAN_QUEUE.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def log_action(comment_id: str, action: str, detail: dict | None = None) -> None:
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "comment_id": comment_id,
        "action": action,
        "detail": detail or {},
    }
    with ACTION_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
