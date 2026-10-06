@echo off
chcp 65001 >nul
title 安裝 autocut 所需工具
echo ============================================
echo   安裝 autocut 所需工具（Python / ffmpeg / Whisper）
echo ============================================
echo.
set NEED_RESTART=0

where python >nul 2>nul
if errorlevel 1 (
  echo [1/3] 安裝 Python...
  winget install -e --id Python.Python.3.12 --accept-source-agreements --accept-package-agreements
  set NEED_RESTART=1
) else (
  echo [1/3] Python 已安裝
)

where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo [2/3] 安裝 ffmpeg...
  winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
  set NEED_RESTART=1
) else (
  echo [2/3] ffmpeg 已安裝
)

if "%NEED_RESTART%"=="1" (
  echo.
  echo --------------------------------------------
  echo  已安裝新程式，請關閉這個視窗，
  echo  再點兩下 setup.bat 一次，完成最後一步。
  echo --------------------------------------------
  pause
  exit /b
)

echo [3/3] 安裝 faster-whisper...
python -m pip install --upgrade pip
python -m pip install faster-whisper pypinyin
if errorlevel 1 (
  echo 安裝失敗，請把上面的錯誤訊息貼給 Claude。
  pause
  exit /b
)

where nvidia-smi >nul 2>nul
if errorlevel 1 (
  echo 未偵測到 NVIDIA 顯卡，將使用 CPU 辨識。
) else (
  echo [加碼] 偵測到 NVIDIA 顯卡，安裝 GPU 加速元件（約 1GB）...
  python -m pip install nvidia-cublas-cu12 "nvidia-cudnn-cu12==9.*"
  python -c "import torchaudio" >nul 2>nul
  if errorlevel 1 (
    echo [加碼] 安裝精準對齊用的 PyTorch（約 2.5GB）...
    python -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
  )
)
echo.
echo ============================================
echo  全部完成！之後把音檔／影片拖到 run.bat 上即可。
echo ============================================
pause
