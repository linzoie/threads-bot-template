"""互動式 .env 設定精靈。給非工程師朋友雙擊用。"""
import sys
sys.stdout.reconfigure(encoding="utf-8")

from pathlib import Path


ROOT = Path(__file__).resolve().parent
ENV_PATH = ROOT / ".env"


def ask(num: int, total: int, name: str, hint: str, example: str = "") -> str:
    print()
    print("-" * 60)
    print(f"  [{num}/{total}]  {name}")
    print("-" * 60)
    print(f"  💡 {hint}")
    if example:
        print(f"  📋 範例：{example}")
    while True:
        val = input("  > ").strip()
        if val:
            return val
        print("  （空白，請再輸入一次）")


def main():
    print("=" * 60)
    print("  Threads Bot 設定精靈")
    print("=" * 60)
    print()
    print("我會問你 6 個問題，幫你建好 .env 設定檔。")
    print("這些值你應該都已經從前面的步驟拿到了。")
    print()
    print("⚠️  輸入時不要加引號、不要前後空格。")
    print()

    if ENV_PATH.exists():
        print(f"⚠️  {ENV_PATH.name} 已存在。覆蓋會清掉舊內容。")
        ans = input("  要覆蓋嗎？ [y/N] > ").strip().lower()
        if ans != "y":
            print("取消，保留原檔。")
            return
        print()

    app_id = ask(
        1, 6,
        "Threads App ID",
        "從 Meta Dashboard → 使用案例 → 設定 → 「Threads 應用程式編號」",
        "1307654111459229",
    )

    app_secret = ask(
        2, 6,
        "Threads App Secret",
        "同一頁的「Threads 應用程式密鑰」，點「顯示」之後複製貼上",
        "9a958ebdb9e3683b1c50dfe6c5529456",
    )

    user_id = ask(
        3, 6,
        "Threads User ID（17 位數字）",
        "PowerShell 換 token 時看到的 user_id（也可以用 verify.bat 驗證後從輸出複製）",
        "27545236108397861",
    )

    username = ask(
        4, 6,
        "Threads username（不含 @）",
        "你 Threads 個人頁那個英文帳號名",
        "your_threads_handle",
    )

    long_token = ask(
        5, 6,
        "Threads 60 天 Token",
        "PowerShell 換完 token 後 longResp.access_token 那串（很長，THAA 開頭）",
        "THAASlTfLNd51BYmIyblFld...",
    )

    anthropic_key = ask(
        6, 6,
        "Anthropic API Key",
        "從 https://console.anthropic.com/settings/keys 取得，sk-ant-api03 開頭",
        "sk-ant-api03-xxxxxxx...",
    )

    env_content = f"""# === Threads API ===
THREADS_APP_ID={app_id}
THREADS_APP_SECRET={app_secret}
THREADS_USER_ID={user_id}
THREADS_USERNAME={username}
THREADS_LONG_LIVED_TOKEN={long_token}

# === LLM ===
LLM_PROVIDER=claude
ANTHROPIC_API_KEY={anthropic_key}
CLAUDE_MODEL=claude-sonnet-4-6

# === Behavior ===
MAX_REPLIES_PER_DAY=80
MAX_REPLIES_PER_HOUR=15
QUIET_HOURS_START=3
QUIET_HOURS_END=7
DRY_RUN=true
"""

    ENV_PATH.write_text(env_content, encoding="utf-8")

    print()
    print("=" * 60)
    print("  ✅ 設定完成！")
    print("=" * 60)
    print(f"  寫入檔案：{ENV_PATH}")
    print()
    print("下一步：雙擊 verify.bat 驗證你的設定能跟 Threads / Anthropic 連線")
    print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\n[取消，沒有寫入任何東西]")
