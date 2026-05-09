"""Thin LLM abstraction so we can swap Claude <-> Groq via LLM_PROVIDER env."""
from . import config


def draft(system: str, user: str, max_tokens: int = 500) -> str:
    """Generate a single completion. Returns plain text."""
    provider = config.LLM_PROVIDER

    if provider == "claude":
        from anthropic import Anthropic
        client = Anthropic(api_key=config.ANTHROPIC_API_KEY)
        resp = client.messages.create(
            model=config.CLAUDE_MODEL,
            max_tokens=max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        return resp.content[0].text.strip()

    if provider == "groq":
        from groq import Groq
        client = Groq(api_key=config.GROQ_API_KEY)
        resp = client.chat.completions.create(
            model=config.GROQ_MODEL,
            max_tokens=max_tokens,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return resp.choices[0].message.content.strip()

    raise ValueError(f"Unknown LLM_PROVIDER: {provider!r}. Use 'claude' or 'groq'.")
