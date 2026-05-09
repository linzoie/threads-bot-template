@echo off
chcp 65001 > nul
cd /d %~dp0

if not exist .venv\Scripts\python.exe (
    echo [錯誤] 還沒跑過 setup.bat！
    pause
    exit /b 1
)

if not exist .env (
    echo [錯誤] 還沒跑過 configure.bat！
    pause
    exit /b 1
)

echo ============================================================
echo   啟動 Threads Bot（功能 ② 陌生人貼文 AI 草擬）
echo ============================================================
echo.

.venv\Scripts\python.exe draft_one.py
pause
