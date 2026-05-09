@echo off
chcp 65001 > nul
cd /d %~dp0

if not exist .venv\Scripts\python.exe (
    echo [錯誤] 還沒跑過 setup.bat！
    echo 請先雙擊 setup.bat 安裝環境。
    pause
    exit /b 1
)

.venv\Scripts\python.exe configure.py
pause
