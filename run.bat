@echo off
chcp 65001 >nul
set PYTHONIOENCODING=utf-8
title autocut 自動剪輯
if "%~1"=="" (
  echo 請把音檔或影片「拖曳」到 run.bat 圖示上，不要直接點兩下。
  pause
  exit /b
)
set "SCRIPT=%~dp0autocut.py"
set "IN=%~1"
set "BASE=%~dpn1"
set GPU=0
where nvidia-smi >nul 2>nul
if not errorlevel 1 set GPU=1
if "%GPU%"=="1" (
  set "ARGS=--model large-v3 --device cuda --compute-type int8_float16"
  echo 偵測到 NVIDIA 顯卡：使用 GPU + large-v3 模型
) else (
  set "ARGS=--model medium --device cpu --compute-type int8"
  echo 未偵測到 NVIDIA 顯卡：使用 CPU + medium 模型
)

if exist "%BASE%.words.json" (
  echo [1/3] 已有逐字稿，略過辨識（要重新辨識請刪除 .words.json）
) else (
  echo [1/3] 語音辨識中（第一次會先下載模型，請耐心等候）...
  python "%SCRIPT%" transcribe "%IN%" %ARGS%
  if errorlevel 1 (
    if "%GPU%"=="1" (
      echo GPU 辨識失敗，自動改用 CPU 重試...
      python "%SCRIPT%" transcribe "%IN%" --model medium --device cpu --compute-type int8
      if errorlevel 1 goto fail
    ) else (
      goto fail
    )
  )
)

if exist "%BASE%.plan.csv" (
  echo [2/3] 已有 plan.csv，沿用你的修改（要重新產生請刪除 .plan.csv）
) else (
  echo [2/3] 標記要剪的地方...
  python "%SCRIPT%" plan "%BASE%.words.json"
  if errorlevel 1 goto fail
)

set "DEL="
set "MODE=--cut-review"
if exist "%BASE%.deletes.txt" (
  echo       偵測到 deletes.txt：依 Claude 的判斷刪句、剪疑似贅詞
  set "DEL=--deletes"
  set "MODE="
)
if "%GPU%"=="1" (
  echo [3/3] 輸出並反覆檢查：重新辨識成品、補剪殘留語助詞（最多 3 輪，約 5～15 分鐘）...
  if defined DEL (
    python "%SCRIPT%" refine "%IN%" "%BASE%.plan.csv" --deletes "%BASE%.deletes.txt" %ARGS%
  ) else (
    python "%SCRIPT%" refine "%IN%" "%BASE%.plan.csv" %MODE% %ARGS%
  )
) else (
  echo [3/3] 輸出剪好的檔案（沒有 NVIDIA 顯卡，略過反覆檢查）...
  if defined DEL (
    python "%SCRIPT%" render "%IN%" "%BASE%.plan.csv" --deletes "%BASE%.deletes.txt"
  ) else (
    python "%SCRIPT%" render "%IN%" "%BASE%.plan.csv" %MODE%
  )
)
if errorlevel 1 goto fail

echo.
echo 完成！剪好的檔案在原檔旁邊（檔名含 .cut）
echo 想要更好的品質：把 .sentences.txt 全文貼給 Claude（挑重講的句子、判斷哪些贅詞能剪），
echo 回覆存成「原檔名.deletes.txt」，再把原檔拖到 run.bat 一次。
pause
exit /b

:fail
echo.
echo 發生錯誤，請把上面的訊息整段貼給 Claude。
pause
