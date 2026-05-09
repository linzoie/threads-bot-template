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
echo   啟動 Threads Bot（功能 ① 自動回覆自家留言）
echo ============================================================
echo.
echo 提示：要停止，按 Ctrl+C
echo.

.venv\Scripts\python.exe run_loop.py
pause
