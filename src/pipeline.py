"""Glue layer: route a single comment through Layers 0-3."""
from . import config, rules, safety, state, threads_client


def process(comment: dict, parent_post: dict) -> dict:
    """Route one comment. Returns {action, detail}.

    Actions:
        skip:self / skip:dup / skip:no_text
        human:sensitive_keyword / human:claude_negative
        replied:rule:<name> / replied:diagnostic
        skip:diagnostic
    """
    cid = comment.get("id")
    text = (comment.get("text") or "").strip()
    commenter = comment.get("username", "")

    # Layer 0: hard skips
    if commenter and commenter == config.THREADS_USERNAME:
        return _finish(cid, "skip:self", {})
    if state.is_replied(cid):
        return _finish(cid, "skip:dup", {})
    if not text:
        return _finish(cid, "skip:no_text", {})

    # Layer 1: safety
    if (kw := safety.keyword_flagged(text)):
        state.add_to_human_queue(comment, parent_post, reason=f"sensitive_keyword:{kw}")
        return _finish(cid, "human:sensitive_keyword", {"keyword": kw})

    if safety.claude_says_negative(text):
        state.add_to_human_queue(comment, parent_post, reason="claude_flagged_negative")
        return _finish(cid, "human:claude_negative", {})

    # Layer 2: keyword rules
    if (rule := rules.match(text)):
        return _send(cid, rule["template"], action=f"replied:rule:{rule['name']}",
                     detail={"rule": rule["name"]})

    # Layer 3: diagnostic
    decision = drafter_diagnose(text, parent_post.get("text", ""))
    if decision["should_reply"] and decision["reply"]:
        return _send(cid, decision["reply"], action="replied:diagnostic",
                     detail={"reason": decision["reason"]})
    return _finish(cid, "skip:diagnostic", {"reason": decision.get("reason", "")})


def drafter_diagnose(text: str, parent_text: str) -> dict:
    # Imported here so we can stub it in tests without pulling LLM at import time.
    from . import drafter
    return drafter.diagnose(text, parent_text)


def _send(comment_id: str, reply_text: str, action: str, detail: dict) -> dict:
    detail = {**detail, "reply_text": reply_text}
    if config.DRY_RUN:
        detail["dry_run"] = True
        state.log_action(comment_id, f"{action}:dry_run", detail)
        return {"action": f"{action}:dry_run", "detail": detail}

    result = threads_client.post_reply(comment_id, reply_text)
    state.mark_replied(comment_id)
    detail["published_id"] = result.get("published_id")
    state.log_action(comment_id, action, detail)
    return {"action": action, "detail": detail}


def _finish(comment_id: str | None, action: str, detail: dict) -> dict:
    if comment_id:
        state.log_action(comment_id, action, detail)
    return {"action": action, "detail": detail}
