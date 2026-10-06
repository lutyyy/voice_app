# autocut 專案交接文件

最後更新：2026-10-01

## 目標

自動剪輯口語影音檔（中文為主），刪除：

- 無意義語助詞（嗯、呃、欸…）
- 口吃／立即重複（我我我、這個這個）
- 過長停頓，以及停頓中的呼吸聲、雜音
- 講錯重講、語意重複的句子，以及口頭禪式的贅詞（交由 Claude 判斷）

剪接處要自然：不能切在聲音中間、不能黏在一起、不能有爆音。

使用者環境：Windows 11、RTX 4070 SUPER 12GB、Python 3.10、ffmpeg 7.1；非開發者，偏好「點兩下／拖曳」操作。測試檔：`C:\Users\QQ\Downloads\TEST\test.m4a`（10:50，16kHz 單聲道 AAC，兩人訪談，幾乎沒有純靜音）。

## 背景決策

- 先試過 CapCut「去除語氣詞／停頓」：屬 Pro 付費功能，且使用者反映中文偵測不準。
- 詢問過 Jev（TypeSafe，2026/9 發布）：它是輕量分類／決策 API，不能處理音訊，不適用。
- 最後改走技術路線：Whisper 逐字時間碼 + VAD 校正 + 規則標記 + Claude 語意判斷 + numpy 接合音訊 + ffmpeg 編碼。

## 檔案

三個檔案需放在同一個資料夾。

| 檔案 | 用途 |
|---|---|
| `autocut.py` | 主程式，子指令 `transcribe` / `plan` / `render` / `refine` |
| `setup.bat` | 一鍵安裝 Python 3.12、ffmpeg（winget）、faster-whisper、pypinyin；偵測到 NVIDIA 時加裝 `nvidia-cublas-cu12`、`nvidia-cudnn-cu12==9.*`，沒有 torchaudio 時再裝 CUDA 版 torch／torchaudio（約 2.5GB） |
| `run.bat` | 把影音檔拖曳到圖示上執行完整流程 |

## 使用流程

1. 點兩下 `setup.bat`。若有新安裝程式，會要求關閉視窗再執行一次（PATH 需重新載入）。
2. 把影音檔拖到 `run.bat` 上：辨識 → 標記 → 有 NVIDIA 時跑 `refine`（輸出並反覆補剪，最多 3 輪），沒有則跑 `render`。產生 `原檔名.cut.mp3`（44100Hz；影片則為 `.cut.mp4`）。格式與取樣率可用 `--format m4a`、`--sample-rate 0`（跟原檔相同）改回。
3. （建議）把 `原檔名.sentences.txt` 全文貼給 Claude，回覆存成 `原檔名.deletes.txt`，再拖一次原檔到 `run.bat`。
   - 沒有 deletes.txt：review（疑似贅詞）全部剪（`--cut-review`）。
   - 有 deletes.txt：只剪清單上的 R 編號，其餘 review 保留。

`run.bat` 的快取行為：已有 `.words.json` 就跳過辨識；已有 `.plan.csv` 就沿用（保留手動修改與 refine 補剪的列）。要重來就刪除對應檔案。

**編號安全**：重新產生 plan.csv（或改了 plan 參數）後 S／R 編號可能改變。sentences.txt 帶有版本碼（`plan_code`：seg、rid、文字的指紋），Claude 回覆的第一行要寫上；render 發現版本碼不符會停下並提示，不會刪錯。沒有版本碼的舊 deletes 只警告。斷句用拖音修剪前的時間（`fit_end`），調整拖音參數不會影響編號。曾因拖音參數改變導致編號位移、刪錯句子，才加上這個檢查。

### 手動指令

```
python autocut.py transcribe test.m4a --model large-v3 --device cuda --compute-type int8_float16
python autocut.py plan test.words.json
python autocut.py render test.m4a test.plan.csv --deletes test.deletes.txt
python autocut.py refine test.m4a test.plan.csv --deletes test.deletes.txt --device cuda --compute-type int8_float16
```

## 產出的中間檔

| 檔案 | 內容 |
|---|---|
| `*.words.json` | 每個字的起訖時間、所屬句子（seg）、`prob`；第二輪補回的片段有 `extra: true` 與 `logprob` |
| `*.plan.csv` | 每個字一列：`seg,start,end,text,action,reason,rid`。action 為 keep / cut / review；rid 為 review 組的編號（R###）。UTF-8 with BOM，Excel 改完需另存「CSV UTF-8」。refine 會把補剪的列寫回這裡 |
| `*.sentences.txt` | Claude 指令＋第一部分 `S### [時間] 文字`（逐句稿）＋第二部分 `R### …前文【候選】後文…`（疑似贅詞） |
| `*.deletes.txt` | Claude 回覆，第一行 `版本碼 xxxxxx`，接著 `S012`、`S012-S014`、`R003-R005` 等，可夾雜理由；`#` 開頭的行視為註解 |

## 技術設計重點

**辨識（transcribe，`asr()`）**

- faster-whisper，`word_timestamps=True`、`vad_filter=False`（避免 VAD 吃掉語助詞）、`condition_on_previous_text=False`（減少幻覺與重複）。
- 繁中語助詞範例以 `hotwords` 傳入（舊版 fallback 為 `initial_prompt`）。`initial_prompt` 在 `condition_on_previous_text=False` 時只作用於第一個 30 秒視窗，之後會變簡體、語助詞被美化；`hotwords` 每個視窗都會帶入。
- **強制對齊（`align_words`，`--no-align` 關閉）**：Whisper 只負責文字，每個字的起訖時間改用 torchaudio 的 MMS_FA 聲學模型重新對齊（中文以 pypinyin 轉拼音、英文直接用字母）。以 VAD 找靜音，把全檔切成 40～90 秒的區塊、邊界落在靜音中間，區塊內一次對齊。**不要逐段對齊**：段落前後的緩衝會吃到隔壁段的聲音，遇到「非常開心，非常榮幸」這種相鄰都有同一個詞的情況，字會被對到隔壁（實測 55 處跨段時間重疊、字序錯亂；改區塊後剩 1 處）。CTC 給的時間偏發聲點，結尾往後延到聲音結束（最多 0.3 秒、不超過下一個字），開頭往前找起音（最多 0.08 秒）。偏離原時間超過 2 秒視為對齊失敗、沿用原時間。
  - 為什麼需要：Whisper 的字時間常整段偏移 0.2～0.4 秒，還會把語助詞併進相鄰的字。實例（原檔 17～20 秒）：「就是說／將來／可能」都偏早，真正的「能」被第二輪補抓聽成「弄」而剪掉，同時保留了「預」前面 0.4 秒的「呃」，成品聽起來像「可啊」。對齊後兩者都正確。
  - 效果：plan 自動抓到的語助詞 74 → 122 處（原本藏在字裡的被挖出來），拖音 38 → 13 處。
  - **cuDNN 衝突**：PyTorch 必須比 faster-whisper 先 import（`load_model` 開頭），否則兩邊的 cuDNN（pip 的 9.27 與 torch 內建的 9.1）衝突，出現 `Could not load symbol cudnnGetLibConfig` 後直接結束（exit 127）。
  - 需要 torch、torchaudio、pypinyin；模型第一次使用時下載約 1.2GB 到 `~/.cache/torch/hub`。沒有這些套件會印出提示並沿用 Whisper 的時間。
- 第二輪漏字補抓（`fill_gaps`）：以 VAD 校正時間碼後，找出「有人聲但沒有字覆蓋」的片段（>0.15 秒），前後補 0.5 秒靜音單獨再辨識。實測 148 段，多為語助詞；也救回整句被主辨識漏掉的內容（否則會被當停頓剪掉）。
- 第三輪：被聽成正常字的語助詞（`check_misheard`，需要強制對齊）：對齊時記下每個字的聲學可信度（`chars` 欄：[起, 訖, 分數]）。詞的第一個字分數 < 0.1、卻佔了 0.35 秒以上且大半有聲音，就把那段單獨再辨識；只聽到語助詞時，多字詞把那段切成補抓片段（plan 當語助詞剪），單字詞標 `misheard` → plan 列 review「疑似聽錯」。實例：原檔 15.6 秒「James 呃 剛有提到」被寫成「剛剛有提到」，第一個「剛」分數 0.03（第二個 0.96），呃因此被當內容保留。全檔 5 處：剛剛→呃（自動剪）、take care→啊（review，Claude 判斷保留：care 是內容）、太大了 是→啊、重要 是→嗯嗯嗯（Claude 剪）。分數門檻不能單獨用：全檔分數 < 0.15 的字有 250 個，大多是正常字，一定要搭配「佔時間長＋單獨重聽是語助詞」。
- Windows 上 `add_nvidia_dll_paths()` 會把 site-packages 下 `nvidia/*/bin` 加入 DLL 搜尋路徑。

**標記（plan）**

- Silero VAD（faster-whisper 內建）取得人聲區間，把每個字的時間碼縮到與人聲重疊最多的一段（Whisper 常把字拉長、蓋住停頓）。
- 單一中文字校正後仍 > `--max-char`（0.6 秒）視為拖音：保留前 `--trim-to`（0.4 秒），尾巴另成一列 `～` cut。
- `SURE_FILLERS` → cut；`MAYBE_FILLERS` → review。
- 口吃／立即重複（1～4 個單位）→ cut 前一次。比對時跳過已剪的語助詞與補抓到的雜音（否則「做［呃］做」「能［啊﹏］能」比不到）；兩次相隔 2 秒內、前一次不是句尾（。！？）、時間沒有重疊才算。多字單位（「我們我們」）一律算；單字重複預設算口吃，只有 `REDUP` 清單中的正常疊字（謝謝、看看、剛剛…）且無停頓時保留。舊規則要求單位重複必須中間有停頓，漏掉「我們我們」「你你」「太太大了」等十多處。
- 第二輪補回的片段：全由 `FILLER_CHARS` 組成 → cut；`HALLUCINATION`（字幕、訂閱、Amara、李宗盛…）或字數多到講不完（> 12 字/秒）→ cut；只有標點 → cut；附和（是、好、對）→ review；`logprob` < -1.0 → review；其餘保留。
- 標記完成後依標點或停頓重新編號 seg（短句）；必須在重複偵測之後。連續 review 字編成一組 R###。

**輸出（render）**

- 不再用 ffmpeg `aselect`，改為 numpy 自己接合音訊後以管線送進 ffmpeg 編碼（`Source` 類別解碼成 PCM memmap，長檔也不吃記憶體）。
- `plan_pieces`：只決定保留哪些內容；要剪的內容合計 < `--min-cut`（0.1 秒）就不剪，避免多餘剪接點。
- `snap_pieces`：剪接點移到附近最安靜的 5ms 格，**只往被剪掉的那一側找 40ms、往保留的字最多 10ms**。對稱搜尋會在「產生【這個】價值」這類連續說話中切掉前字的尾音（實測 12 處，聽起來卡卡的）。
- `shape_silence`：停頓長短**依實際音量**決定（呼吸壓低後也算安靜，門檻 floor + `--quiet-db` 12dB），不看字的時間碼。片段內部或剪接處的安靜段 > `--max-pause`（0.35 秒）→ 壓成 `--keep-pause`（0.22 秒，依原長最多加 0.08）；剪接處太短 → 句間補到 0.12 秒、句中只補到 0.03 秒。開頭最多留 0.15 秒、結尾 0.4 秒。舊版依字的時間碼判斷，留下 67 段 ≥0.3 秒空白，又在句中補底噪（共 25 秒），聽起來斷斷續續。
- 不足的停頓用**合成底噪**補（`noise_profile` 取最安靜無人聲的幀的平均頻譜，`make_noise` 隨機相位合成）。不直接複製原音：此類錄音最長的純靜音只有 0.2 秒，重複貼上會被聽出來，實測還讓 Whisper 聽出「嗯」。影片不補（會影響影格）。
- `synth_audio`：每個接點做長度不變的等功率交叉淡化（20ms；接點有聲音時 60ms），總長 = 片段長度總和，影片因此能同步。
- `breath_gain`：停頓中高出底噪 8dB 以上的聲音（呼吸、雜音）最多壓低 18dB，而不是刪除。
- 影片：`fps=` 固定影格率 → 區間邊界對齊影格 → `select` 以「前移半格」判斷 → `setpts='round(N*den/num/TB)'` → `-fps_mode passthrough`。
  - **舊版 bug（已修）**：`setpts=N/FRAME_RATE/TB` 浮點誤差會把 11 算成 10.9999 截成 10，產生重複時間碼，ffmpeg 預設 CFR 模式就丟掉 674 格；加上 `select` 邊界四捨五入到小數 4 位也會少選影格。
- 音訊編碼：m4a/aac → AAC 128k；mp3 → LAME VBR q2；wav → PCM；flac、ogg、opus 各自對應。影片 AAC 192k。
- 選項：`--denoise`（afftdn）、`--loudnorm`（-16 LUFS）、`--no-roomtone`、`--breath-cut 0`、`--report`（輸出片段 JSON）。

**反覆補剪（refine）**

- 成品的停頓已被壓短，對齊區塊改成「20～60 秒內挑最長的停頓切開」；舊規則要求 ≥0.25 秒靜音，在成品上切不開，形成數分鐘的區塊而顯示卡記憶體不足。對齊完會釋放顯示卡記憶體。
- 輸出 → 用同一個模型重新辨識成品 → 找殘留語助詞 → 用片段表把成品時間對回原檔 → 新增 cut 列 → 寫回 plan.csv → 再輸出。沒有新發現或到 `--rounds` 就停。每輪約 3～5 分鐘（GPU）。
- **必須保守**：只信主辨識 prob ≥ 0.5 的確定語助詞，以及漏字補抓中 logprob ≥ -0.7 且只含嗯呃欸等字的片段；與保留字重疊時，字至少要留 80%，否則略過。第一版較寬鬆，短片段重聽時把正常字的一部分聽成「嗯、欸」，結果削短了 143 個字（最短 0.06 秒），是「卡卡」的主因。保守版三輪補剪 11 處、只微修 6 個字。

## 測試狀況（2026-10-01，使用者電腦實測）

評估工具在 scratchpad（`evalcut.py`）：量剪接點爆音、切在聲音中、剪接處附近是否有 ≥50ms 靜音，並重新辨識成品比對文字。

| 指標 | 舊版（aselect，全剪 review） | 第二版（10/01 凌晨） | 第三版 | 第四版（強制對齊，目前） |
|---|---|---|---|---|
| 剪接點切在聲音中 | 67% | 16% | — | — |
| 剪接點切進保留字中間且有聲音 | — | 22 | 0 | 0 |
| 成品中 ≥0.4 秒的安靜段 | — | 25 | 0 | 0（≥0.3 秒 30 → 13） |
| 補的合成底噪總長 | 0 | 25 秒 | 9.4 秒 | 7.9 秒 |
| 成品主辨識殘留確定語助詞 | 1 | 2 | 7 | **0**（區塊對齊＋新口吃規則＋refine） |
| 文字相似度（有無誤剪內容） | 0.866 | 0.922 | 0.905 | **0.954** |
| 長度 | 8:33 | 9:05 | 9:13 | 9:01 |

成品重新辨識後偶爾出現「其實其實」「說說」等相鄰重複，逐一對回 plan 都只有一次，是全檔辨識在接縫處的誤差；評估重複時要對回 plan 確認。

- 影片（合成 29.97fps 測試片）：15917 格全數保留、間隔一致，影音長度一致。mp3、wav 輸出正常。
- 「殘留語助詞」若用漏字補抓的結果算會高估：短片段單獨辨識常把正常字聽成欸、啊，或在底噪上幻覺。以主辨識的確定語助詞為準。
- **.bat 必須維持 UTF-8 + CRLF**：用 sed 修改會變成 LF，cmd 解讀中文會整個壞掉。修改請用 Python 讀寫 bytes。
- 尚未實測：setup.bat（環境原本已裝好）、真實影片檔、CPU 路徑的 render、長檔（1 小時以上）的速度與記憶體。

## 已知限制與風險

- Whisper 每次辨識結果略有不同（溫度退避），偶爾有幻覺字（例如「cockpit要0123…」）；音訊照樣保留，只影響逐字稿與判斷。
- 語助詞若和正常字完全黏在一起（同一個時間碼），refine 會因矛盾而略過。
- 「嗯」有時表示肯定，會被誤剪；台語、中英夾雜會降低準確度。
- 疑似贅詞的判斷需要 Claude 看上下文；沒有 deletes.txt 時一律剪掉，可能造成「最重要的就是意願 → 最重要的意願」這類不通順。
- GPU：只支援 NVIDIA。沒有 NVIDIA 時不跑 refine。

## 可能的下一步

1. 以 Anthropic API 自動完成 sentences.txt 的判斷（挑句＋R 編號），省去手動貼上。
2. 依聽感微調 `--min-gap-*`、`--keep-pause`、`--xfade*`。
3. 輸出 EDL / FCPXML，讓使用者在 Premiere 或 DaVinci Resolve 內微調。
4. 擴充台灣口語語助詞（齁、吼、欸對…）。
