@echo off
chcp 65001 > nul
cd /d %~dp0

echo ============================================================
echo   Threads Bot 環境安裝
echo ============================================================
echo.

where python >nul 2>nul
if errorlevel 1 (
    echo [錯誤] 找不到 Python！
    echo.
    echo 請先到 https://www.python.org/downloads/ 下載 Python 3.11+
    echo 安裝時務必勾選「Add Python to PATH」
    echo 裝好之後再回來執行這個檔案。
    pause
    exit /b 1
)

echo [1/3] 建立虛擬環境...
python -m venv .venv
if errorlevel 1 (
    echo [錯誤] 虛擬環境建立失敗
    pause
    exit /b 1
)

echo [2/3] 升級 pip...
.venv\Scripts\python.exe -m pip install --upgrade pip --quiet

echo [3/3] 安裝套件（這步可能要 1-2 分鐘）...
.venv\Scripts\python.exe -m pip install -r requirements.txt --quiet
if errorlevel 1 (
    echo [錯誤] 套件安裝失敗
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   ✅ 安裝完成！
echo ============================================================
echo.
echo 下一步：雙擊 configure.bat 填入你的設定值
echo.
pause
