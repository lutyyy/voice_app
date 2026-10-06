# 語音剪輯（iOS 版 autocut）

在 iPhone 上自動剪掉影音檔裡的語助詞（嗯、呃、欸…）、口吃重複、過長的停頓，以及停頓中的呼吸聲。語音辨識與剪輯都在手機上完成，不會上傳檔案。

## 使用方式

1. 首頁按「從『檔案』選擇」或「從『照片』選擇影片」。也可以在其他 App 按「分享」，選「語音剪輯」。
   - Google 雲端硬碟：安裝並登入「Google 雲端硬碟」App，再到「檔案」App › 瀏覽 › ⋯ › 編輯，打開 Google 雲端硬碟。之後在「從『檔案』選擇」的「瀏覽」裡就能選雲端硬碟的檔案（會先下載到手機）。iCloud 雲碟、Dropbox、OneDrive 也一樣。
2. 選擇處理範圍：拖曳聲波兩側的把手（可以試聽開頭結尾），或直接「用整段」。之後可以在專案右上角「⋯ › 變更處理範圍」。
3. App 會自動辨識並標記要剪的地方。處理畫面會顯示步驟、聲波掃描進度、即時辨識出的句子與預估剩餘時間。第一次使用會先下載辨識模型（約 140～630MB，建議連 Wi-Fi）。處理時請讓 App 保持在前景、不要鎖定螢幕。
4. （建議）處理「重講的句子與贅詞」：
   - 在「設定」輸入自己的 Claude API 金鑰，並同意傳送逐字稿。之後按「請 Claude 判斷」就會自動完成。
   - 或者按「複製逐句稿」，貼到 claude.ai，再把 Claude 的回覆複製回來，按「貼上 Claude 的回覆」。
   - 兩種都不做時，可以用「疑似贅詞全部剪掉」開關決定。
5. 選剪輯風格（自然／標準／精簡），會即時顯示預估剪後長度；「微調剪輯參數」可以調整全部參數。
6. 想微調時，按「檢視／修改逐字稿」：
   - 點字切換保留／剪掉；長按字可以試聽、修改錯字、把所有同樣的字一起剪掉或保留。
   - 句子向左滑整句剪掉、向右滑整句保留；每句可以試聽原音與剪後的效果。
   - 上方聲波標出所有剪掉的地方，點一下跳到該處；可以篩選、搜尋、復原／重做。
7. 按「輸出剪好的檔案」。完成後可以直接播放，或按「分享／儲存剪好的檔案」。剪好的檔案也能在「檔案」App 的「我的 iPhone › 語音剪輯」找到。
8. 「逐字稿、字幕、說話者、AI 整理」：匯出 TXT 逐字稿與 SRT／VTT 字幕（可對齊剪好的檔案或原始檔案）、辨識說話者並命名，或請 Claude 潤飾成文章、寫重點摘要、產生 YouTube 章節。

### 設定

| 設定 | 選項 |
|---|---|
| 剪輯風格 | 自然（停頓留多、最自然）、標準（與電腦版相同）、精簡（剪到最短）；套用後可再微調全部參數 |
| 處理速度 | 快速（Base 模型）、標準（Small＋漏字補抓＋補剪 1 輪）、極致（Large v3 Turbo＋補剪 2 輪）。這支手機跑不動的等級會標 ⚠︎ 並在選擇時警告 |

## 用 SideStore 安裝與自動更新（建議）

在 SideStore 的「Sources」按「＋」，輸入以下網址加入來源：

```
https://github.com/lutyyy/voice_app/releases/latest/download/source.json
```

之後在「Browse」找到「語音剪輯」安裝。每次程式更新、雲端編譯成功後會自動發布新版本（版本號 1.0.編譯次數），SideStore 的「My Apps」會出現「Update」，按一下就更新，專案資料會保留。

## 安裝到 iPhone（沒有 Mac 也可以）

iOS App 必須用 Mac 上的 Xcode 編譯。這個專案改用 GitHub 的雲端 Mac 自動編譯：

1. 每次推送程式碼到 GitHub，「Actions」頁籤的 **iOS App** 流程會自動執行。
2. 執行成功後，在該次執行的頁面最下方「Artifacts」下載 **VoiceCut-unsigned-ipa**，解壓縮得到 `VoiceCut-unsigned.ipa`。
3. 這個 IPA 還沒有簽章，需要用你的 Apple ID 簽章才能安裝。在 Windows 上可以用 [Sideloadly](https://sideloadly.io/)：
   1. 安裝 iTunes 與 iCloud（Sideloadly 需要它們的驅動程式；請用 Apple 官網下載的版本，不要用 Microsoft Store 版）。
   2. iPhone 用傳輸線接上電腦，按「信任這部電腦」。
   3. 開啟 Sideloadly，把 IPA 拖進去，輸入 Apple ID，按 Start。
   4. iPhone 上到「設定 › 隱私權與安全性 › 開發者模式」開啟並重新開機，再到「設定 › 一般 › VPN 與裝置管理」信任你的 Apple ID。
4. 用免費 Apple ID 簽章的 App **7 天後會失效**，需要重新用 Sideloadly 安裝一次（資料會保留）。加入 Apple Developer Program（年費 US$99）後可以用一年，也才能用 TestFlight 或上架 App Store。

> 私人 repo 的 GitHub Actions 每月有免費額度（macOS 執行時間以 10 倍計算，免費方案約可編譯 15～20 次）。

## 與電腦版的差異

| 項目 | 電腦版（autocut.py） | iOS 版 |
|---|---|---|
| 語音辨識 | faster-whisper large-v3（顯示卡） | WhisperKit：依裝置自動選 Large v3 Turbo／Small／Base |
| 字的時間校正 | torchaudio MMS_FA 強制對齊 | 沒有（沿用 Whisper 的時間，再用人聲區間校正） |
| 被聽成正常字的語助詞（第三輪） | 有 | 沒有（需要強制對齊） |
| 人聲偵測 | Silero VAD | 依音量判斷 |
| Claude 判斷 | 手動貼上 | API 一鍵判斷，或手動貼上 |
| 逐字稿／字幕 | 無 | TXT／SRT／VTT、說話者辨識（SpeakerKit）、Claude 整理 |
| 輸出格式 | mp3／m4a／wav／flac…、影片 mp4 | m4a／wav、影片 mp4 |

標記規則（語助詞、口吃、拖音、疑似贅詞）、剪接點、停頓壓縮、呼吸聲壓低、合成底噪、交叉淡化與反覆補剪的邏輯都和電腦版相同，並用電腦版產生的資料做了比對測試。

## 專案結構

| 路徑 | 內容 |
|---|---|
| `AutoCutCore/` | 剪輯邏輯（純 Swift，可在 Linux 跑測試）：`Planner` 標記、`Review` 逐句稿與 Claude 回覆、`Analysis` 音量／人聲／底噪、`Renderer` 剪接與交叉淡化、`Refiner` 反覆補剪 |
| `AutoCutCore/Tests/` | 單元測試；`Fixtures/` 是用 `autocut.py` 產生的對照資料 |
| `VoiceCut/` | SwiftUI App：匯入、WhisperKit 辨識、解碼與輸出（AVFoundation）、Claude API、畫面 |
| `project.yml` | XcodeGen 設定（CI 用它產生 Xcode 專案） |

在 Mac 上開發：`brew install xcodegen && cd ios && xcodegen generate && open VoiceCut.xcodeproj`。
只跑剪輯邏輯測試：`cd ios/AutoCutCore && swift test`。

## 上架前還需要

對照 `iOS App 上架前審核檢查表.md`，程式已處理：Privacy Manifest、`ITSAppUsesNonExemptEncryption = NO`、App 內隱私說明、傳給第三方 AI 前取得同意、不需登入、無追蹤、1024 圖示（無透明）。
上架前還需要：Apple Developer 帳號、隱私權政策網址、技術支援網址、截圖、CI 簽章與上傳（需要把憑證與 App Store Connect API 金鑰設成 GitHub Secrets），以及在實機上完整測試。
