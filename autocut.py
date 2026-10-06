#!/usr/bin/env python3
"""
autocut.py — 自動剪掉語助詞、口吃重複、過長停頓（含停頓裡的呼吸聲）

流程：
  1. transcribe  用 Whisper 產生逐字（含每個字的時間碼）
  2. plan        自動標記要剪的地方，輸出可檢查的 plan.csv 與給 Claude 看的 sentences.txt
  3. （可選）把 sentences.txt 貼給 Claude，請它挑出重複／講錯重講的句子，存成 deletes.txt
  4. render      依照 plan.csv（+ deletes.txt）用 ffmpeg 輸出剪好的檔案

需求：Python 3.9+、ffmpeg、pip install faster-whisper
"""
import argparse
import csv
import json
import os
import re
import subprocess
import sys
import tempfile
from fractions import Fraction

# 一定是贅詞：直接剪
SURE_FILLERS = {"嗯", "嗯嗯", "呃", "呃呃", "額", "额", "欸", "誒", "恩", "唔",
                "um", "uh", "umm", "uhh", "erm", "hmm", "mm"}
# 可能是贅詞：只標記 review，讓你（或 Claude）決定
MAYBE_FILLERS = {"那個", "就是", "就是說", "然後", "然後呢", "對", "對對", "對對對",
                 "啊", "喔", "哦", "齁", "吼", "這個", "反正", "其實", "基本上", "所以說", "好像",
                 # Whisper 有時輸出簡體，一併涵蓋
                 "那个", "然后", "然后呢", "对", "对对", "对对对", "这个", "其实", "所以说"}
# 正常的疊字：中間沒有停頓時不當成口吃
REDUP = {w * 2 for w in "謝看剛常慢媽爸哥姐弟妹天人好試想說談走聽等往漸個偏明稍大小多星寶默紛輕悄統通僅處時年層步點一乖剛謝"} | {
    "谢谢", "刚刚", "妈妈", "爸爸", "试试", "说说", "谈谈", "听听", "渐渐", "个个", "稍稍", "宝宝", "纷纷", "轻轻",
    "统统", "通通", "仅仅", "处处", "时时", "层层", "步步", "点点"}
# 第二輪補回的片段只由這些字組成 → 視為語助詞（含呼吸聲常被聽成的嗨、哈、哎）
FILLER_CHARS = set("嗯呃額额欸誒诶恩唔啊阿喔哦噢耶嗨哈哎呦呀嘿")
BACKCHANNELS = {"是", "是是", "好", "好好", "對", "对", "對啊", "對阿", "对啊", "嗯對", "是的", "對對", "对对"}
PUNCT = re.compile(r"[\s，。、！？,.!?；;：:「」『』\"'（）()…—\-~﹗﹐﹑﹔﹖﹕]+")
END_PUNCT = re.compile(r"[，。、！？,.!?；;：…﹗﹐﹑﹔﹖]\s*$")
# Whisper 在雜音上常見的幻覺字幕
HALLUCINATION = re.compile(r"字幕|訂閱|订阅|頻道|频道|Amara|感謝觀看|感谢观看|點贊|点赞|請不吝|请不吝|明鏡|明镜|李宗盛|剪輯|作詞|作曲|字幕by|MING PAO|明報|明报", re.I)
AUDIO_EXT = {".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".opus", ".wma"}


def norm(t):
    return PUNCT.sub("", t).lower()


def fmt(t):
    t = max(0.0, t)
    return f"{int(t // 3600):02d}:{int(t % 3600 // 60):02d}:{t % 60:06.3f}"


def base_of(path):
    return os.path.splitext(path)[0]


# ---------------------------------------------------------------- transcribe
def add_nvidia_dll_paths():
    """Windows：讓 pip 安裝的 CUDA 函式庫（nvidia-cublas / nvidia-cudnn）可以被找到"""
    if os.name != "nt":
        return
    import site
    roots = site.getsitepackages() + [site.getusersitepackages()]
    for root in roots:
        nv = os.path.join(root, "nvidia")
        if not os.path.isdir(nv):
            continue
        for pkg in os.listdir(nv):
            b = os.path.join(nv, pkg, "bin")
            if os.path.isdir(b):
                os.add_dll_directory(b)
                os.environ["PATH"] = b + os.pathsep + os.environ.get("PATH", "")


def uncovered_speech(words, speech, min_len=0.15):
    """人聲區間中沒有被任何字覆蓋的片段（Whisper 漏掉的語助詞，偶爾是整句）"""
    spans = sorted((w["start"], w["end"]) for w in words)
    out = []
    for a, b in speech:
        t = a
        for s, e in spans:
            if e <= t or s >= b:
                continue
            if s - t > min_len:
                out.append((t, s))
            t = max(t, e)
        if b - t > min_len:
            out.append((t, b))
    return out


def fill_gaps(model, path, words, language, verbose=True):
    """把每個漏字片段單獨再辨識一次，補進逐字稿（標記 extra），由 plan 判斷是語助詞還是內容"""
    import numpy as np
    from faster_whisper.audio import decode_audio
    import copy
    sr = 16000
    audio = decode_audio(path, sampling_rate=sr)
    speech = speech_regions(path)
    fitted = copy.deepcopy(words)
    fit_words(fitted, speech, 0, 0)  # 只校正時間碼，不切拖音
    pad = np.zeros(sr // 2, np.float32)
    extra = []
    for a, b in uncovered_speech(fitted, speech):
        clip = np.concatenate([pad, audio[int(a * sr):int(b * sr)], pad])
        segs, _ = model.transcribe(clip, language=language, beam_size=5, vad_filter=False,
                                   condition_on_previous_text=False, hotwords="嗯，呃，欸，啊，喔")
        segs = list(segs)
        text = "".join(s.text for s in segs).strip()
        if not norm(text):
            continue
        lp = min(s.avg_logprob for s in segs)  # 信心分數，雜音被硬聽成字時通常 < -1
        seg = max((w["seg"] for w in words if w["start"] <= a), default=0)
        extra.append({"seg": seg, "start": round(a, 3), "end": round(b, 3), "text": text,
                      "extra": True, "logprob": round(lp, 2)})
        if verbose:
            print(f"[{fmt(a)}] {text}  ({lp:.2f})", flush=True)
    print(f"補回 {len(extra)} 個片段")
    return sorted(words + extra, key=lambda w: w["start"])


def check_misheard(model, path, words, language, verbose=True):
    """找出被 Whisper 聽成正常字的語助詞（例如「James 呃 剛有提到」被寫成「剛剛有提到」）。
    線索：對齊時詞的第一個字聲學可信度很低（< 0.1），卻佔了 0.35 秒以上、而且大半有聲音。
    把那段單獨再辨識一次，若只聽到語助詞：
      - 多字詞 → 把那段切出來成為補抓片段（plan 會當語助詞剪掉），詞本身從下一個字開始
      - 單字詞 → 標記 misheard，由 plan 列為 review（可能是「是」後面拖了「啊」，不敢直接剪）"""
    import numpy as np
    from faster_whisper.audio import decode_audio
    sr = 16000
    audio = decode_audio(path, sampling_rate=sr)
    f = audio[:len(audio) // 80 * 80].reshape(-1, 80)
    E = 20 * np.log10(np.sqrt((f ** 2).mean(1)) + 1e-9)
    voiced = E > np.percentile(E, 5) + 12
    chars = sorted((c[0], c[2], i, j) for i, w in enumerate(words) for j, c in enumerate(w.get("chars", [])))
    pad = np.zeros(sr // 2, np.float32)
    extra, n = [], 0
    for k, (s, sc, i, j) in enumerate(chars):
        nxt = chars[k + 1][0] if k + 1 < len(chars) else words[i]["end"]
        w = words[i]
        if sc >= 0.1 or j > 0 or w.get("extra") or not 0.35 <= nxt - s < 3:
            continue
        if voiced[int(s * 200):int(nxt * 200)].sum() / 200 < 0.3:
            continue
        segs, _ = model.transcribe(np.concatenate([pad, audio[int(s * sr):int(nxt * sr)], pad]), language=language,
                                   beam_size=5, vad_filter=False, condition_on_previous_text=False,
                                   hotwords="嗯，呃，欸，啊，喔")
        heard = "".join(x.text for x in segs).strip()
        if not norm(heard) or not set(norm(heard)) <= FILLER_CHARS:
            continue
        n += 1
        if len(w["chars"]) > 1 and nxt < w["end"]:
            extra.append({"seg": w["seg"], "start": round(s, 3), "end": round(nxt, 3), "text": heard,
                          "extra": True, "logprob": 0.0, "misheard": w["text"]})
            w["start"] = round(nxt, 3)
        else:
            w["misheard"] = heard
        if verbose:
            print(f"[{fmt(s)}] 「{w['text']}」其實是「{heard}」", flush=True)
    print(f"找到 {n} 處被聽成正常字的語助詞")
    return sorted(words + extra, key=lambda w: w["start"])


DEFAULT_PROMPT = "嗯，這個，呃，就是說，我們今天，然後，那個，欸，對，我覺得啊，喔。"


def romanize(text):
    """把一個 token 拆成「字」，回傳每個字的拼音字母（英文單字照原樣；數字等無法對齊的回傳 None）"""
    from pypinyin import lazy_pinyin, Style
    out = []
    for ch in re.findall(r"[A-Za-z]+|[㐀-鿿]|\d", text):
        if ch.isdigit():
            out.append(None)
        elif ch.isascii():
            out.append(ch.lower())
        else:
            py = lazy_pinyin(ch, style=Style.NORMAL, errors="ignore")
            out.append(re.sub(r"[^a-z]", "", (py[0] if py else "").replace("ü", "u")) or None)
    return out


def align_words(words, path, device):
    """強制對齊：Whisper 只負責文字，每個字的起訖時間改用聲學模型（torchaudio MMS_FA）重新對齊。
    Whisper 的字時間常偏移 0.2～0.4 秒，還會把語助詞併進相鄰的字（例如「呃預」整段標成「預」），
    導致切點偏掉：該剪的語助詞留下來、該留的字被剪掉一半。對齊後空出來的語助詞會由 fill_gaps 補抓"""
    try:
        import numpy as np
        import torch
        import torchaudio
        from faster_whisper.audio import decode_audio
        romanize("測")
    except Exception as e:  # 沒裝 torch / torchaudio / pypinyin
        print(f"（略過精準對齊：{e}。可執行 setup.bat 安裝）")
        return words
    dev = "cuda" if device in ("cuda", "auto") and torch.cuda.is_available() else "cpu"
    print("精準對齊每個字的時間（第一次會下載約 1.2GB 的對齊模型）…")
    bundle = torchaudio.pipelines.MMS_FA
    model = bundle.get_model(with_star=False).to(dev)
    dic = bundle.get_dict(star=None)
    sr = 16000
    audio = decode_audio(path, sampling_rate=sr)
    f = audio[:len(audio) // 80 * 80].reshape(-1, 80)
    E = 20 * np.log10(np.sqrt((f ** 2).mean(1)) + 1e-9)  # 5ms 一格
    voiced = E > np.percentile(E, 5) + 12

    # 分成 40～90 秒的區塊、邊界切在靜音中間，區塊內一次對齊。
    # 不逐段對齊：段落前後要留緩衝，緩衝會吃到隔壁段的聲音，遇到「非常開心，非常榮幸」這種
    # 相鄰都有同一個詞的情況，會把字對到隔壁的聲音上
    dur = len(audio) / sr
    speech = speech_regions(path)
    gaps = [((e0 + s1) / 2, s1 - e0) for (_, e0), (s1, _) in zip(speech, speech[1:])]
    bounds, cur = [0.0], 0.0
    while dur - cur > 60:  # 每 20～60 秒挑最長的停頓切開（剪好的成品停頓很短，不能要求固定長度）
        cand = [g for g in gaps if cur + 20 <= g[0] <= cur + 60] or [g for g in gaps if cur < g[0] <= cur + 60]
        cur = max(cand, key=lambda g: g[1])[0] if cand else cur + 60
        bounds.append(cur)
    bounds.append(dur)
    blocks = [(a, b, [w for w in words if a <= (w["start"] + w["end"]) / 2 < b]) for a, b in zip(bounds, bounds[1:])]
    moved = failed = 0
    for lo, hi, ws in blocks:
        if not ws:
            continue
        units = [(i, r) for i, w in enumerate(ws) for r in romanize(w["text"]) if r]
        tokens = [dic[c] for _, r in units for c in r if c in dic]
        if not tokens:
            continue
        try:
            x = torch.from_numpy(audio[int(lo * sr):int(hi * sr)]).unsqueeze(0).to(dev)
            with torch.inference_mode():
                em, _ = model(x)
            al, sc = torchaudio.functional.forced_align(em, torch.tensor([tokens], device=dev), blank=0)
            spans = torchaudio.functional.merge_tokens(al[0], sc[0].exp())
        except Exception:  # 例如顯示卡記憶體不足：這一塊沿用原時間，並釋放記憶體繼續
            failed += 1
            if dev == "cuda":
                torch.cuda.empty_cache()
            continue
        ratio = x.shape[1] / em.shape[1] / sr
        k, span_of, chars = 0, {}, {}
        for i, r in units:
            m = sum(1 for c in r if c in dic)
            if not m:
                continue
            sp = spans[k:k + m]
            k += m
            s, e = lo + sp[0].start * ratio, lo + sp[-1].end * ratio
            a, b = span_of.get(i, (s, e))
            span_of[i] = (min(a, s), max(b, e))
            # 每個字的聲學可信度：很低代表這段聲音其實不是這個字（例如「呃」被 Whisper 聽成「剛」）
            chars.setdefault(i, []).append([round(s, 3), round(e, 3), round(float(np.mean([t.score for t in sp])), 3)])
        for i, w in enumerate(ws):
            if i not in span_of:
                continue
            s, e = span_of[i]
            if abs(s - w["start"]) > 2.0:  # 偏太多多半是對齊失敗，保留原時間
                continue
            w["w_start"], w["w_end"] = w["start"], w["end"]
            w["start"], w["end"] = s, e
            w["chars"] = chars[i]
            moved += 1
        # CTC 的時間偏「發聲點」：結尾往後延到聲音結束（不超過下一個字），開頭往前找到起音
        for i, w in enumerate(ws):
            nxt = ws[i + 1]["start"] if i + 1 < len(ws) else hi
            prv = ws[i - 1]["end"] if i else lo
            j = int(w["end"] * 200)
            while j < len(voiced) and voiced[j] and (j + 1) / 200 < nxt and (j + 1) / 200 - w["end"] < 0.3:
                j += 1
            w["end"] = round(max(w["end"], min(j / 200, nxt)), 3)
            j = int(w["start"] * 200) - 1
            while j >= 0 and voiced[j] and j / 200 > prv and w["start"] - j / 200 < 0.08:
                j -= 1
            w["start"] = round(min(w["start"], max((j + 1) / 200, prv)), 3)
    print(f"對齊完成：{moved} 個字" + (f"（{failed} 段失敗，沿用原時間）" if failed else ""))
    del model
    if dev == "cuda":
        torch.cuda.empty_cache()  # 讓出顯示卡記憶體給 Whisper（refine 會在同一個程序裡繼續辨識）
    return words


def load_model(a):
    add_nvidia_dll_paths()
    try:  # PyTorch（對齊用）必須比 Whisper 先載入：反過來兩邊的 cuDNN 版本會衝突而崩潰
        import torch  # noqa: F401
        import torchaudio  # noqa: F401
    except Exception:
        pass
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        sys.exit("請先安裝：pip install faster-whisper")
    print(f"載入模型 {a.model}（第一次會下載，需要一點時間）…")
    return WhisperModel(a.model, device=a.device, compute_type=a.compute_type)


def asr(model, path, language, prompt, gapfill=True, verbose=True, device="auto", align=True):
    """主辨識 → 強制對齊每個字的時間 → 第二輪漏字補抓；回傳 (segments, words, duration)"""
    # 在提示中放語助詞，Whisper 比較願意把「嗯、呃」寫出來，而不是自動美化掉
    kw = dict(language=language, word_timestamps=True, vad_filter=False,
              condition_on_previous_text=False, beam_size=5)
    # initial_prompt 只作用在第一個 30 秒視窗；hotwords 每個視窗都會帶入，才能全程保留語助詞、維持繁體
    try:
        segments, info = model.transcribe(path, hotwords=prompt, **kw)
    except TypeError:  # 舊版 faster-whisper 沒有 hotwords
        segments, info = model.transcribe(path, initial_prompt=prompt, **kw)
    segs, words = [], []
    for si, s in enumerate(segments):
        segs.append({"id": si, "start": s.start, "end": s.end, "text": s.text.strip()})
        for w in (s.words or []):
            words.append({"seg": si, "start": round(w.start, 3), "end": round(w.end, 3),
                          "text": w.word.strip(), "prob": round(w.probability, 3)})
        if verbose:
            print(f"[{fmt(s.start)}] {s.text.strip()}", flush=True)
    if align:
        words = align_words(words, path, device)
    if gapfill:
        print("\n第二輪：檢查漏字（有人聲但沒有對應文字的片段）…")
        words = fill_gaps(model, path, words, language, verbose)
        if align:
            print("\n第三輪：檢查被聽成正常字的語助詞…")
            words = check_misheard(model, path, words, language, verbose)
    return segs, words, info.duration


def cmd_transcribe(a):
    model = load_model(a)
    segs, words, duration = asr(model, a.input, a.language, a.prompt or DEFAULT_PROMPT, not a.no_gapfill,
                                device=a.device, align=not a.no_align)
    out = base_of(a.input) + ".words.json"
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"input": os.path.abspath(a.input), "duration": duration,
                   "segments": segs, "words": words}, f, ensure_ascii=False, indent=1)
    print(f"\n完成 → {out}")


# ---------------------------------------------------------------- plan
def mark(w, action, reason):
    w["action"], w["reason"] = action, reason


def boundary_before(words, i):
    if i == 0 or words[i - 1]["seg"] != words[i]["seg"]:
        return True
    return words[i]["start"] - words[i - 1]["end"] >= 0.15 or bool(END_PUNCT.search(words[i - 1]["text"]))


def boundary_after(words, j):
    if j == len(words) - 1 or words[j + 1]["seg"] != words[j]["seg"]:
        return True
    return words[j + 1]["start"] - words[j]["end"] >= 0.15 or bool(END_PUNCT.search(words[j]["text"]))


def speech_regions(path):
    """用 Silero VAD（faster-whisper 內建）找出真正有人聲的區間，呼吸聲與雜音不算"""
    from faster_whisper.audio import decode_audio
    from faster_whisper.vad import get_speech_timestamps, VadOptions
    sr = 16000
    ts = get_speech_timestamps(decode_audio(path, sampling_rate=sr), VadOptions(
        threshold=0.5, min_silence_duration_ms=150, speech_pad_ms=30, min_speech_duration_ms=100))
    return [(t["start"] / sr, t["end"] / sr) for t in ts]


def fit_words(words, speech, max_char, trim_to):
    """Whisper 常把字的時間碼拉長、蓋住停頓或拖長音：
    1) 把每個字縮到它與人聲區間重疊最多的那一段
    2) 單一中文字仍長於 max_char → 只留前 trim_to 秒，尾巴另成一列標記 cut（拖音）
    回傳拖音列，由呼叫端在標記完語助詞／重複後再併入"""
    drags = []
    for w in words:
        s, e = w["start"], w["end"]
        ov = [(max(s, a), min(e, b)) for a, b in speech if a < e and b > s]
        if ov:
            ns, ne = max(ov, key=lambda x: x[1] - x[0])
            if ne - ns >= 0.08:
                s, e = ns, ne
        w["start"], w["end"] = round(s, 3), round(e, 3)
        w["fit_end"] = w["end"]  # 斷句用修剪前的結尾，調整拖音參數時句子編號才不會跟著變
        t = norm(w["text"])
        if max_char and len(t) == 1 and not t.isascii() and e - s > max_char:
            w["end"] = round(s + trim_to, 3)
            drags.append({"seg": w["seg"], "start": w["end"], "end": round(e, 3), "text": "～",
                          "action": "cut", "reason": "拖音"})
    return drags


def resegment(words, split_gap):
    """Whisper 的 segment 常長達 30 秒；在標點或停頓處重新切成短句，讓 Claude 能逐句挑選。
    需在標記完重複之後才做，否則跨標點的「那，那所以」會被切開而偵測不到"""
    seg, prev, prev_orig = 0, None, None
    for w in words:
        orig = w["seg"]
        if w["text"] != "～":
            if prev is not None and (orig != prev_orig or END_PUNCT.search(prev["text"])
                                     or w["start"] - prev.get("fit_end", prev["end"]) >= split_gap):
                seg += 1
            prev, prev_orig = w, orig
        w["seg"] = seg


def cmd_plan(a):
    with open(a.words, encoding="utf-8") as f:
        d = json.load(f)
    words = d["words"]
    for w in words:
        mark(w, "keep", "")
    src, drags = d.get("input", ""), []
    if a.no_vad or not os.path.exists(src):
        print("（略過人聲偵測：" + ("已用 --no-vad 關閉" if a.no_vad else f"找不到原檔 {src}") + "）")
    else:
        print("偵測人聲區間（校正字的時間碼）…")
        drags = fit_words(words, speech_regions(src), a.max_char, a.trim_to)
    n = [norm(w["text"]) for w in words]
    N = len(words)

    # 1) 確定的語助詞；第二輪補回的片段若全是語助詞字也剪，只有附和（是、好、對）標 review
    for i, w in enumerate(words):
        if n[i] in SURE_FILLERS:
            mark(w, "cut", "語助詞")
        elif w.get("misheard") and not w.get("extra"):
            mark(w, "review", f"疑似聽錯（單獨重聽是「{w['misheard']}」）")
        elif not w.get("extra"):
            continue
        elif not n[i]:  # 只辨識出標點：多半是雜音
            mark(w, "cut", "雜音")
        elif n[i] and set(n[i]) <= FILLER_CHARS:
            mark(w, "cut", "語助詞（漏字補抓）")
        elif HALLUCINATION.search(w["text"]) or len(n[i]) > 12 * (w["end"] - w["start"]) + 2:  # 字數多到講不完
            mark(w, "cut", "雜音（辨識幻覺）")
        elif n[i] in BACKCHANNELS:
            mark(w, "review", "附和")
        elif w.get("logprob", 0) < a.min_logprob:
            mark(w, "review", "漏字（不確定，多半是雜音或語助詞）")

    # 2) 口吃／立即重複：「我我我們」「這個這個」「做［呃］做」→ 剪掉前面的
    #    跳過已剪掉的語助詞再比對（對齊後語助詞常夾在兩次重複之間）；兩次相隔 2 秒內都算
    idx = [k for k in range(N) if n[k] and words[k]["action"] != "cut"
           and not (words[k].get("extra") and words[k]["action"] == "review")]  # 補抓到的雜音也跳過
    M = len(idx)
    for p in range(M):
        for L in (4, 3, 2, 1):
            if p + 2 * L > M:
                continue
            A = [n[idx[q]] for q in range(p, p + L)]
            B = [n[idx[q]] for q in range(p + L, p + 2 * L)]
            if A != B or any(words[idx[q]]["action"] != "keep" for q in range(p, p + L)):
                continue
            last, nxt = words[idx[p + L - 1]], words[idx[p + L]]
            gap = nxt["start"] - last["end"]
            if gap > 2.0 or gap < -0.05:  # 隔太久不算；時間重疊是同一段聲音被辨識兩次，不是口吃
                continue
            if re.search(r"[。！？!?]\s*$", last["text"]):  # 前一次已是句尾（例如兩人各說一次「謝謝。」）
                continue
            if L == 1 and len(A[0]) == 1 and A[0] * 2 in REDUP and gap < 0.12:
                continue  # 正常疊字（謝謝、看看）
            for q in range(p, p + L):
                mark(words[idx[q]], "cut", "重複")
            break

    # 3) 可能的贅詞：標 review
    i = 0
    while i < N:
        hit = False
        for L in (3, 2, 1):
            j = i + L - 1
            if j >= N or words[i]["seg"] != words[j]["seg"]:
                continue
            if "".join(n[i:j + 1]) not in MAYBE_FILLERS:
                continue
            if any(words[k]["action"] != "keep" for k in range(i, j + 1)):
                continue
            if len("".join(n[i:j + 1])) == 1 and not (boundary_before(words, i) and boundary_after(words, j)):
                continue  # 單字（對、啊）只在前後有停頓時才標記
            for k in range(i, j + 1):
                mark(words[k], "review", "疑似贅詞")
            i, hit = j + 1, True
            break
        if not hit:
            i += 1

    words = sorted(words + drags, key=lambda w: (w["start"], w["text"] == "～"))
    resegment(words, a.split_gap)

    # 連續的 review 字編成一組 R###，讓 Claude 看上下文逐一決定
    rid, prev = 0, None
    for w in words:
        w["rid"] = ""
        if w["action"] == "review":
            if not (prev and prev["action"] == "review" and prev["seg"] == w["seg"]):
                rid += 1
            w["rid"] = rid
        prev = w

    base = base_of(a.words).removesuffix(".words")
    plan_path, sent_path = base + ".plan.csv", base + ".sentences.txt"
    write_plan(plan_path, words)

    by_seg = {}
    for w in words:
        by_seg.setdefault(w["seg"], []).append(w)
    lines = []
    for sid, ws in by_seg.items():
        txt = "".join(w["text"] if w["action"] != "cut" else "" for w in ws).strip()
        if txt:
            lines.append(f"S{sid:03d} [{fmt(ws[0]['start'])[:8]}] {txt}")
    shown = [w for w in words if w["action"] != "cut"]
    rlines, i = [], 0
    while i < len(shown):
        if shown[i]["action"] != "review":
            i += 1
            continue
        j = i
        while j + 1 < len(shown) and shown[j + 1]["rid"] == shown[i]["rid"]:
            j += 1
        ctx = lambda ws: "".join(w["text"] for w in ws)
        rlines.append(f"R{shown[i]['rid']:03d} …{ctx(shown[max(0, i - 8):i])}【{ctx(shown[i:j + 1])}】"
                      f"{ctx(shown[j + 1:j + 9])}…")
        i = j + 1
    with open(sent_path, "w", encoding="utf-8") as f:
        f.write(CLAUDE_PROMPT.replace("{code}", plan_code(words)) + "\n\n## 第一部分：逐句稿\n\n" + "\n".join(lines)
                + "\n\n## 第二部分：疑似贅詞\n\n" + "\n".join(rlines) + "\n")

    cnt = lambda act, r=None: sum(1 for w in words if w["action"] == act and (r is None or w["reason"] == r))
    print(f"語助詞 {cnt('cut', '語助詞')} 處、重複 {cnt('cut', '重複')} 處、拖音 {cnt('cut', '拖音')} 處 → 會剪")
    print(f"疑似贅詞 {cnt('review')} 處 → 標記 review（預設保留，render 加 --cut-review 才剪）")
    print(f"\n檢查／修改：{plan_path}（action 欄可改成 keep / cut / review）")
    print(f"給 Claude：  {sent_path}（整個檔案內容貼給 Claude，回覆存成 deletes.txt）")


CLAUDE_PROMPT = """以下是一段影片的逐字稿（語音辨識產生，可能有錯字），要剪掉冗詞讓節奏更緊湊。請做兩件事：

【第一部分】逐句稿，每句前面有編號（S###）。找出應該刪掉的句子：
1. 講錯後重講的片段（刪掉講錯的那一句，保留重講的版本）
2. 意思完全重複的句子，或對方重複剛剛那句話的附和（保留說得比較好的那一句）
3. 明顯的廢話或離題的自言自語（例如「等一下我想一下」「剛剛講到哪」）
不要刪除只是口語化、但有內容的句子。

【第二部分】疑似贅詞，每個有編號（R###），【】內是候選字，前後是上下文。
判斷刪掉【】內的字之後，句子是否仍然通順、意思不變：
- 是口頭禪、填空用的（例如「然後…然後」、「就是說」、「這個…」停頓用）→ 列出編號，要剪
- 是句子的必要成分（例如「最重要的【就是】意願」、「【這個】產業」指稱特定東西、「【其實】」帶轉折語氣）→ 不要列
- 拿不準時不要列（保留比較安全）

請只輸出要刪除的編號，一行一個，可用範圍（例如 S012-S014、R003-R005），後面可加簡短理由。
回覆的第一行請原樣寫上：版本碼 {code}"""


# ---------------------------------------------------------------- render
def load_plan(path):
    words = []
    with open(path, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            words.append({"seg": int(r["seg"]), "start": float(r["start"]), "end": float(r["end"]),
                          "text": r["text"], "action": (r["action"] or "keep").strip().lower(),
                          "reason": r["reason"], "rid": (r.get("rid") or "").strip()})
    return words


def plan_code(words):
    """句子／贅詞編號的指紋。plan.csv 重新產生後編號可能改變，用來擋下過期的 deletes.txt"""
    import hashlib
    # 排序後再算：refine 會微調時間，存檔後列的順序可能改變，但編號本身沒變
    key = "|".join(sorted(f"{w['seg']}:{w.get('rid', '')}:{w['text']}" for w in words
                          if w["text"] != "～" and "補剪" not in w["reason"]))
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:6]


def apply_deletes(words, path):
    """S### = 刪整句；R### = 要剪的疑似贅詞。有 deletes 檔時，沒被列出的 review 一律保留"""
    sids, rids = set(), set()
    with open(path, encoding="utf-8") as f:
        text = "".join(ln for ln in f if not ln.lstrip().startswith("#"))  # # 開頭是註解（例如保留清單）
    code, m = plan_code(words), re.search(r"版本碼\s*[:：]?\s*([0-9a-f]{6})", text)
    if m and m.group(1) != code:
        sys.exit(f"\n{path} 是針對舊版 plan.csv 做的（版本碼 {m.group(1)}，目前是 {code}），句子編號已經不同，\n"
                 f"直接套用會刪錯內容。請把新的 sentences.txt 重新貼給 Claude，回覆覆蓋 deletes.txt 後再執行。")
    if not m:
        print(f"（注意：{os.path.basename(path)} 沒有版本碼，無法確認是否對應目前的 plan.csv）")
    for m in re.finditer(r"\b([SR])(\d+)(?:\s*[-~～到]\s*[SR]?(\d+))?", text, re.I):
        lo = int(m.group(2))
        hi = int(m.group(3)) if m.group(3) else lo
        (sids if m.group(1).upper() == "S" else rids).update(range(lo, hi + 1))
    for w in words:
        if w["seg"] in sids:
            mark(w, "cut", "AI標記刪句")
        elif w["action"] == "review":
            hit = w["rid"].isdigit() and int(w["rid"]) in rids
            mark(w, "cut" if hit else "keep", w["reason"] + ("（Claude：剪）" if hit else "（Claude：留）"))
    return sids, rids


def audio_info(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                        "stream=sample_rate,channels", "-of", "json", path],
                       capture_output=True, text=True, check=True)
    st = json.loads(r.stdout)["streams"][0]
    return int(st["sample_rate"]), int(st["channels"])


def read_pcm(path, sr, ch, tmpdir):
    """解碼成 16-bit PCM 暫存檔再用 memmap 讀，長檔案也不會吃光記憶體"""
    import numpy as np
    raw = os.path.join(tmpdir, "src.raw")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vn", "-f", "s16le", "-acodec", "pcm_s16le",
                    "-ar", str(sr), "-ac", str(ch), raw], check=True)
    return np.memmap(raw, dtype=np.int16, mode="r").reshape(-1, ch)


def energy_db(pcm, hop):
    """每 5ms 一格的音量（dB）"""
    import numpy as np
    n = len(pcm) // hop
    out = np.empty(n, np.float32)
    step = hop * 20000
    for i in range(0, n * hop, step):
        x = np.asarray(pcm[i:min(i + step, n * hop)], np.float32).mean(1) / 32768
        f = x.reshape(-1, hop)
        out[i // hop:i // hop + len(f)] = 20 * np.log10(np.sqrt((f ** 2).mean(1)) + 1e-9)
    return out


def resolve(words, cut_review):
    for w in words:
        if w["action"] == "review":
            mark(w, "cut" if cut_review else "keep", w["reason"])
    return sorted(words, key=lambda w: w["start"])


def plan_pieces(words, a, duration):
    """決定要保留的原始片段（只管內容；停頓長短之後由 shape_silence 依實際音量決定）。
    剪掉的內容合計太短（< min_cut）就不剪：多一個剪接點的代價比留下一小段聲音大。
    回傳 [[start, end, 是否句與句之間], ...]"""
    kept = [w for w in words if w["action"] == "keep"]
    cuts = [w for w in words if w["action"] == "cut"]
    if not kept:
        sys.exit("全部都被剪掉了，請檢查 plan.csv")
    first = kept[0]
    before = [c["end"] for c in cuts if c["end"] <= first["start"] + 1e-3]
    cur = max(before) if before else 0.0
    pieces, ci = [], 0
    for A, B in zip(kept, kept[1:]):
        while ci < len(cuts) and cuts[ci]["end"] <= A["end"] + 1e-3:
            ci += 1
        between, j = [], ci
        while j < len(cuts) and cuts[j]["start"] < B["start"] - 1e-3:
            between.append(cuts[j])
            j += 1
        removed = sum(min(c["end"], B["start"]) - max(c["start"], A["end"]) for c in between)
        if removed < a.min_cut:
            continue
        lsil = max(0.0, min(c["start"] for c in between) - A["end"])
        rsil = max(0.0, B["start"] - max(c["end"] for c in between))
        boundary = bool(END_PUNCT.search(A["text"])) or A["seg"] != B["seg"]
        pieces.append([cur, A["end"] + lsil, boundary])
        cur = B["start"] - rsil
    last = kept[-1]
    after = [c["start"] for c in cuts if c["start"] >= last["end"] - 1e-3]
    pieces.append([cur, min(after) if after else duration, False])
    return pieces


def shape_silence(pieces, quiet, hop_s, a, video):
    """依實際音量調整停頓（呼吸聲壓低後也算安靜）：
    - 片段內部或剪接處的安靜段 > max_pause → 壓成約 keep_pause（依原長略加，保留節奏變化）
    - 剪接處的安靜段太短 → 句與句之間補合成底噪到 min_gap_sentence；句中只補到 min_gap_phrase
    回傳 [[start, end, 之後要補的底噪秒數], ...]"""
    n = len(quiet)

    def run(t, step, limit):
        k = int(round(t / hop_s)) - (1 if step < 0 else 0)
        c = 0
        while 0 <= k < n and quiet[k] and c * hop_s < limit:
            c += 1
            k += step
        return min(c * hop_s, limit)

    def target(L):
        return a.keep_pause + min(0.08, 0.08 * (L - a.max_pause))

    split = []
    for s, e, bnd in pieces:  # 1) 片段內部的長停頓：從中間切掉多餘的部分
        k0, k1 = int(round(s / hop_s)), int(round(e / hop_s))
        cur, i = s, k0
        while i < k1:
            if not quiet[i]:
                i += 1
                continue
            j = i
            while j < k1 and quiet[j]:
                j += 1
            L = (j - i) * hop_s
            if i > k0 and j < k1 and L > a.max_pause:
                h = target(L) / 2
                split.append([cur, i * hop_s + h, True])
                cur = j * hop_s - h
            i = j
        split.append([cur, e, bnd])

    res = [[s, e, 0.0] for s, e, _ in split]
    for i in range(len(res) - 1):  # 2) 剪接處：前段尾巴＋後段開頭的安靜合計
        A, B = res[i], res[i + 1]
        tail, head = run(A[1], -1, A[1] - A[0]), run(B[0], 1, B[1] - B[0])
        J = tail + head
        if J > a.max_pause:
            t = target(J)
            lt = min(tail, t / 2)
            ht = min(head, t - lt)
            lt = min(tail, t - ht)
            A[1] -= tail - lt
            B[0] += head - ht
        elif not video:
            mn = a.min_gap_sentence if split[i][2] else a.min_gap_phrase
            A[2] = max(0.0, mn - J)
    head = run(res[0][0], 1, res[0][1] - res[0][0])  # 3) 開頭最多留 0.15 秒、結尾 0.4 秒
    res[0][0] += max(0.0, head - 0.15)
    tail = run(res[-1][1], -1, res[-1][1] - res[-1][0])
    res[-1][1] -= max(0.0, tail - 0.4)
    return [p for p in res if p[1] - p[0] > 0.02]


def snap_pieces(pieces, E, hop_s, win):
    """把每個剪接點移到附近最安靜的位置。只往「被剪掉的那一側」找 win 秒，
    往保留的字裡最多 10ms：連續說話中語助詞緊貼前一個字時，對稱搜尋會切掉前字的尾音，聽起來卡卡的"""
    import numpy as np

    def best(t, back, fwd):
        lo, hi = max(0, int((t - back) / hop_s)), min(len(E) - 1, int((t + fwd) / hop_s))
        if hi <= lo:
            return t
        seg = E[lo:hi + 1]
        cand = np.flatnonzero(seg <= seg.min() + 1.0)  # 差不多安靜的格子裡，選最靠近原位置的
        k = cand[np.argmin(np.abs((lo + cand) * hop_s + hop_s / 2 - t))]
        return (lo + k) * hop_s + hop_s / 2

    for i, p in enumerate(pieces):
        if i > 0:
            p[0] = best(p[0], win, 0.01)
        if i < len(pieces) - 1:
            p[1] = best(p[1], 0.01, win)
    merged = []
    for p in pieces:
        if merged and p[0] <= merged[-1][1] + 0.01:
            merged[-1][1] = max(merged[-1][1], p[1])
            merged[-1][2] = p[2]
        else:
            merged.append(p)
    return [p for p in merged if p[1] - p[0] >= 0.02]


def noise_profile(pcm, E, speech, hop, sr, floor):
    """取最安靜、沒有人聲的片段，算出底噪的平均頻譜，用來合成「環境底噪」填補太短的停頓。
    不直接複製原音：口語錄音常常找不到夠長的純靜音，短片段重複貼上會聽得出來、甚至帶到人聲"""
    import numpy as np
    hop_s = hop / sr
    quiet = E < floor + 3
    for s, e in speech:
        quiet[max(0, int((s - 0.1) / hop_s)):int((e + 0.1) / hop_s)] = False
    idx = np.flatnonzero(quiet)
    if len(idx) < 20:
        return None
    N = 1024
    P, cnt = np.zeros(N // 2 + 1), 0
    for k in idx[np.linspace(0, len(idx) - 1, min(300, len(idx))).astype(int)]:
        x = np.asarray(pcm[k * hop:k * hop + N], np.float32).mean(1) / 32768
        if len(x) == N:
            P += np.abs(np.fft.rfft(x * np.hanning(N))) ** 2
            cnt += 1
    if not cnt:
        return None
    rms = float(np.sqrt(np.mean([10 ** (E[k] / 10) for k in idx])))
    return {"psd": P / cnt, "rms": rms}


def make_noise(n, ch, prof, seed):
    """依底噪頻譜合成指定長度的雜訊（每次隨機，不會有重複感）"""
    import numpy as np
    rng = np.random.default_rng(seed)
    m = max(2048, 1 << int(np.ceil(np.log2(max(n, 2)))))
    X = np.fft.rfft(rng.standard_normal(m))
    f = np.linspace(0, 1, len(X))
    X *= np.sqrt(np.interp(f, np.linspace(0, 1, len(prof["psd"])), prof["psd"]))
    y = np.fft.irfft(X, m)[:n]
    y *= prof["rms"] / (np.sqrt(np.mean(y ** 2)) + 1e-12)
    return np.repeat(y[:, None].astype(np.float32), ch, axis=1)


def breath_gain(E, speech, keep_words, hop_s, floor, margin, max_cut):
    """停頓中高出底噪 margin dB 以上的聲音（呼吸、雜音）壓到接近底噪；人聲與保留的字不動"""
    import numpy as np
    ns = np.ones(len(E), bool)
    for s, e in list(speech) + [(w["start"], w["end"]) for w in keep_words]:
        ns[max(0, int((s - 0.06) / hop_s)):int((e + 0.06) / hop_s) + 1] = False
    over = E - (floor + margin)
    idx = ns & (over > 0)
    g = np.zeros(len(E), np.float32)
    g[idx] = -np.minimum(over[idx], max_cut)
    if idx.any():  # 前後 25ms 取最小值再平滑，避免增益跳動
        from numpy.lib.stride_tricks import sliding_window_view
        g = sliding_window_view(np.pad(g, 5, mode="edge"), 11).min(1)
        g = np.convolve(g, np.ones(8) / 8, mode="same")
    return (10 ** (g / 20)).astype(np.float32)


def synth_audio(pcm, sr, segs, gain, hop, E, floor, prof, a, write):
    """依序接合片段；每個接點做長度不變的等功率交叉淡化（前段多取 h、後段提早 h 開始）。
    接點附近有聲音時用較長的淡化，避免爆音與突兀。segs：[start, end, kind]，kind="noise" 為合成底噪"""
    import numpy as np
    ch = pcm.shape[1]
    n = [int(round(e * sr)) - int(round(s * sr)) for s, e, _ in segs]

    def level(t):
        return E[min(len(E) - 1, max(0, int(t * sr / hop)))]

    hs = []
    for i in range(1, len(segs)):
        (_, pe, pk), (ns_, _, nk) = segs[i - 1], segs[i]
        loud = max(level(pe) if pk != "noise" else floor, level(ns_) if nk != "noise" else floor)
        h = a.xfade_long if loud > floor + 20 else a.xfade
        hs.append(max(1, min(int(h / 2 * sr), n[i - 1] // 2, n[i] // 2)))
    tail, total = None, 0
    for i, (s, e, kind) in enumerate(segs):
        hin = hs[i - 1] if i > 0 else 0
        hout = hs[i] if i < len(segs) - 1 else 0
        L = n[i] + hin + hout
        if kind == "noise":
            buf = make_noise(L, ch, prof, i)
        else:
            a0 = int(round(s * sr)) - hin
            buf = np.zeros((L, ch), np.float32)
            lo, hi = max(0, a0), min(len(pcm), a0 + L)
            if hi > lo:
                buf[lo - a0:hi - a0] = pcm[lo:hi] / 32768.0
                gl, gh = lo // hop, min(len(gain), (hi + hop - 1) // hop)
                if gh > gl:
                    gs = np.repeat(gain[gl:gh], hop)[lo - gl * hop:hi - gl * hop]
                    buf[lo - a0:lo - a0 + len(gs)] *= gs[:, None]
        if hin:
            buf[:2 * hin] *= np.sin(np.linspace(0, np.pi / 2, 2 * hin, dtype=np.float32))[:, None]
            buf[:2 * hin] += tail
        if hout:
            buf[-2 * hout:] *= np.cos(np.linspace(0, np.pi / 2, 2 * hout, dtype=np.float32))[:, None]
            write(buf[:-2 * hout])
            tail = buf[-2 * hout:].copy()
            total += L - 2 * hout
        else:
            write(buf)
            total += L
    return total / sr


def audio_codec(ext, video):
    if video or ext in (".m4a", ".aac", ".mp4", ".mov"):
        return ["-c:a", "aac", "-b:a", "192k" if video else "128k"]
    return {".mp3": ["-c:a", "libmp3lame", "-q:a", "2"], ".wav": ["-c:a", "pcm_s16le"],
            ".flac": ["-c:a", "flac"], ".ogg": ["-c:a", "libvorbis", "-q:a", "6"],
            ".opus": ["-c:a", "libopus", "-b:a", "128k"]}.get(ext, [])


class Source:
    """原始檔的音訊與分析結果；refine 多輪輸出時共用，不必每輪重新解碼"""

    def __init__(self, path):
        import numpy as np
        self.path = path
        self.fps, duration = probe(path)
        self.ext = os.path.splitext(path)[1].lower()
        if self.ext in AUDIO_EXT:
            self.fps = None
        self.sr, self.ch = audio_info(path)
        self.hop = self.sr // 200
        self.hop_s = self.hop / self.sr
        self.tmpdir = tempfile.mkdtemp(prefix="autocut_")
        self.pcm = read_pcm(path, self.sr, self.ch, self.tmpdir)
        self.duration = min(duration, len(self.pcm) / self.sr)
        self.E = energy_db(self.pcm, self.hop)
        self.floor = float(np.percentile(self.E, 5))
        print("偵測人聲區間…")
        self.speech = speech_regions(path)
        self.prof = noise_profile(self.pcm, self.E, self.speech, self.hop, self.sr, self.floor)

    def close(self):
        import shutil
        self.pcm = None
        shutil.rmtree(self.tmpdir, ignore_errors=True)


def render(src, words, a, out):
    """words 須已決定 keep / cut；回傳實際輸出的片段 [[start, end, kind], ...]（kind="noise" 為合成底噪）"""
    import numpy as np
    video = bool(src.fps)
    keep_words = [w for w in words if w["action"] == "keep"]
    gain = (breath_gain(src.E, src.speech, keep_words, src.hop_s, src.floor, a.breath_margin, a.breath_cut)
            if a.breath_cut > 0 else np.ones(len(src.E), np.float32))
    quiet = src.E + 20 * np.log10(gain + 1e-9) < src.floor + a.quiet_db  # 呼吸聲壓低後也算安靜
    pieces = plan_pieces(words, a, src.duration)
    pieces = snap_pieces(pieces, src.E, src.hop_s, a.snap)
    pieces = shape_silence(pieces, quiet, src.hop_s, a, video)
    if video:  # 對齊影格，避免多次剪接後影音不同步
        snap = lambda t: float(round(Fraction(t).limit_denominator(100000) * src.fps) / src.fps)
        pieces = [[snap(s), snap(e), 0.0] for s, e, _ in pieces]
        pieces = [p for p in pieces if p[1] > p[0]]
    pieces = [[max(0.0, s), min(src.duration, e), f] for s, e, f in pieces]
    pieces = [p for p in pieces if p[1] - p[0] > 0.01]
    segs = []
    for s, e, fill in pieces:
        segs.append([s, e, "src"])
        if fill > 0.005 and src.prof and not a.no_roomtone:
            segs.append([0.0, fill, "noise"])

    af = []
    if a.denoise:
        af.append("afftdn=nf=-25")
    if a.loudnorm:
        af.append("loudnorm=I=-16:TP=-1.5:LRA=11")
    cmd = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
           "-f", "s16le", "-ar", str(src.sr), "-ac", str(src.ch), "-i", "-"]
    if video:
        # 邊界已對齊影格；用「前移半格」判斷，避免小數四捨五入少選或多選一格造成影音不同步
        hf = 0.5 / float(src.fps)
        expr = "+".join(f"gte(t,{s - hf:.6f})*lt(t,{e - hf:.6f})" for s, e, _ in segs)
        # round()：N/FRAME_RATE/TB 的浮點誤差會把 11 算成 10.9999 被截成 10，造成重複時間碼、影格被丟
        r = src.fps
        graph = (f"[1:v]fps={r},select='{expr}',"
                 f"setpts='round(N*{r.denominator}/{r.numerator}/TB)'[v]")
        if len(graph) < 20000:
            fc = ["-filter_complex", graph]
        else:  # 太長會超過 Windows 命令列上限，改用檔案
            gpath = os.path.join(src.tmpdir, "graph.txt")
            with open(gpath, "w", encoding="utf-8") as f:
                f.write(graph)
            fc = ["-/filter_complex", gpath] if ffmpeg_major() >= 7 else ["-filter_complex_script", gpath]
        # 預設的固定影格率模式會誤丟影格（影音因此差半秒以上）；時間碼已由 setpts 排好，直接沿用
        vsync = ["-fps_mode", "passthrough"] if ffmpeg_major() >= 5 else ["-vsync", "passthrough"]
        cmd += ["-i", src.path] + fc + vsync + ["-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-preset", a.preset,
                                        "-crf", str(a.crf), "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    cmd += (["-af", ",".join(af)] if af else []) + audio_codec(os.path.splitext(out)[1].lower(), video) + ["-ar", str(a.sample_rate or src.sr), out]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    write = lambda buf: proc.stdin.write(np.clip(buf * 32768, -32768, 32767).astype(np.int16).tobytes())
    try:
        length = synth_audio(src.pcm, src.sr, segs, gain, src.hop, src.E, src.floor, src.prof, a, write)
    finally:
        proc.stdin.close()
        proc.wait()
    if proc.returncode:
        sys.exit("ffmpeg 輸出失敗")
    fills = sum(1 for s in segs if s[2] == "noise")
    print(f"原長 {fmt(src.duration)} → 剪後 {fmt(length)}（省下 {fmt(src.duration - length)}，"
          f"{len(pieces)} 段、補底噪 {fills} 處）")
    return segs


def decide(raw, a):
    """依 deletes / --cut-review 決定每個字 keep 或 cut（不改動 raw，方便 refine 回寫 plan.csv）"""
    import copy
    words = copy.deepcopy(raw)
    cut_review = a.cut_review
    if a.deletes:
        sids, rids = apply_deletes(words, a.deletes)
        print(f"套用 Claude 標記：刪除 {len(sids)} 句、剪掉 {len(rids)} 個疑似贅詞（其餘保留）")
        cut_review = False
    return resolve(words, cut_review)


def out_path(src, a):
    return a.output or base_of(src.path) + ".cut" + (".mp4" if src.fps else "." + a.format)


def cmd_render(a):
    if a.max_pause < a.keep_pause:
        sys.exit("--max-pause 不能小於 --keep-pause")
    src = Source(a.input)
    try:
        out = out_path(src, a)
        print("輸出中（交叉淡化、壓低呼吸聲、補環境底噪）…")
        segs = render(src, decide(load_plan(a.plan), a), a, out)
    finally:
        src.close()
    if a.report:
        with open(a.report, "w", encoding="utf-8") as f:
            json.dump({"segs": segs}, f)
    print(f"完成 → {out}")


# ---------------------------------------------------------------- refine
# 成品裡仍聽得到、一定是贅詞的字；啊、喔等只有前面有停頓（不是接在字後面的語尾）才算
REFINE_SURE = {"嗯", "呃", "額", "额", "欸", "誒", "诶", "恩", "唔", "噢", "哎", "um", "uh", "hmm", "mm"}
REFINE_LOOSE = {"啊", "阿", "喔", "哦", "呀", "耶"}
REFINE_CHARS = set("嗯呃額额欸誒诶恩唔")


def write_plan(path, words):
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["seg", "start", "end", "text", "action", "reason", "rid"])
        for w in sorted(words, key=lambda w: w["start"]):
            wr.writerow([w["seg"], w["start"], w["end"], w["text"], w["action"], w["reason"], w.get("rid", "")])


def to_source(segs, t0, t1):
    """成品時間 [t0, t1] 對回原檔時間（可能跨多個片段；合成底噪的部分略過）"""
    out, pos = [], 0.0
    for s, e, kind in segs:
        L = e - s
        a0, a1 = max(t0, pos), min(t1, pos + L)
        if a1 > a0 and kind != "noise":
            out.append((s + a0 - pos, s + a1 - pos))
        pos += L
    return out


def find_residual(words_out, speech_out):
    """在成品的辨識結果中找殘留的語助詞"""
    fit_words(words_out, speech_out, 0, 0)
    found = []
    for i, w in enumerate(words_out):
        t = norm(w["text"])
        if not t:
            continue
        # 要很有把握才補剪：短片段單獨重聽時，常把正常字的一部分聽成嗯、欸（實測曾因此把 143 個字削短）
        gap = w["start"] - words_out[i - 1]["end"] if i else 1.0
        if w.get("extra"):
            ok = set(t) <= REFINE_CHARS and w.get("logprob", -9) >= -0.7
        elif t in REFINE_SURE:
            ok = w.get("prob", 1) >= 0.5
        else:
            ok = t in REFINE_LOOSE and gap >= 0.15 and w.get("prob", 1) >= 0.6
        if ok:
            found.append(w)
    return found


def cmd_refine(a):
    """輸出 → 重新辨識成品 → 把殘留語助詞對回原檔補剪 → 再輸出，重複到沒有新發現或達到輪數"""
    if a.max_pause < a.keep_pause:
        sys.exit("--max-pause 不能小於 --keep-pause")
    raw = load_plan(a.plan)
    model = load_model(a)
    src = Source(a.input)
    out = out_path(src, a)
    try:
        for rnd in range(1, a.rounds + 1):
            print(f"\n===== 第 {rnd} 輪：輸出 =====")
            segs = render(src, decide(raw, a), a, out)
            print(f"===== 第 {rnd} 輪：重新辨識成品，找殘留語助詞 =====")
            _, wo, _ = asr(model, out, a.language, a.prompt or DEFAULT_PROMPT, True, verbose=False, device=a.device)
            found = find_residual(wo, speech_regions(out))
            added = 0
            for w in found:
                for fs, fe in to_source(segs, w["start"], w["end"]):
                    if fe - fs < 0.04:
                        continue
                    if any(x["action"] == "cut" and x["start"] <= fs + 0.02 and x["end"] >= fe - 0.02 for x in raw):
                        continue  # 已經標過（可能因太短沒實際剪），不重複新增
                    # 與保留的字重疊：只允許把字稍微修短（保留至少 80%），否則代表兩次辨識矛盾，保守略過
                    hit = [x for x in raw if x["action"] != "cut" and x["text"] != "～"
                           and x["start"] < fe - 0.01 and x["end"] > fs + 0.01]
                    ok = True
                    for x in hit:
                        left, right = fs - x["start"], x["end"] - fe
                        if max(left, right) < 0.8 * (x["end"] - x["start"]):
                            ok = False
                    if not ok:
                        continue
                    for x in hit:
                        if fs - x["start"] >= x["end"] - fe:
                            x["end"] = round(fs, 3)
                        else:
                            x["start"] = round(fe, 3)
                    seg = min(raw, key=lambda x: abs(x["start"] - fs))["seg"]
                    raw.append({"seg": seg, "start": round(fs, 3), "end": round(fe, 3), "text": w["text"],
                                "action": "cut", "reason": f"語助詞（第{rnd}輪補剪）", "rid": ""})
                    added += 1
            print(f"找到 {len(found)} 個殘留語助詞，補剪 {added} 處")
            write_plan(a.plan, raw)
            if not added:
                break
        else:
            print("\n===== 最終輸出 =====")
            render(src, decide(raw, a), a, out)
    finally:
        src.close()
    print(f"完成 → {out}")


def probe(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
                        "stream=codec_type,avg_frame_rate:stream_disposition=attached_pic:format=duration",
                        "-of", "json", path], capture_output=True, text=True, check=True)
    info = json.loads(r.stdout)
    fps = None
    for s in info.get("streams", []):
        if s.get("codec_type") == "video" and not s.get("disposition", {}).get("attached_pic"):
            rate = s.get("avg_frame_rate", "0/0")
            if rate not in ("0/0", "0"):
                fps = Fraction(rate)
            break
    return fps, float(info["format"].get("duration", 0))


def ffmpeg_major():
    r = subprocess.run(["ffmpeg", "-version"], capture_output=True, text=True)
    m = re.search(r"ffmpeg version n?(\d+)", r.stdout)
    return int(m.group(1)) if m else 0


# ---------------------------------------------------------------- main
def main():
    p = argparse.ArgumentParser(description="自動剪語助詞、重複與停頓")
    sub = p.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("transcribe", help="語音辨識（逐字時間碼）")
    t.add_argument("input")
    t.add_argument("--model", default="large-v3", help="large-v3（準、需顯卡較快）/ medium / small")
    t.add_argument("--language", default="zh")
    t.add_argument("--device", default="auto", help="auto / cuda / cpu")
    t.add_argument("--compute-type", default="default", help="顯卡可用 float16，CPU 可用 int8 加速")
    t.add_argument("--prompt", default=None, help="自訂提示詞（可放專有名詞，提升辨識）")
    t.add_argument("--no-gapfill", action="store_true", help="不做第二輪漏字檢查")
    t.add_argument("--no-align", action="store_true", help="不做強制對齊（沿用 Whisper 的字時間，較不準）")
    t.set_defaults(func=cmd_transcribe)

    pl = sub.add_parser("plan", help="自動標記要剪的地方")
    pl.add_argument("words", help="transcribe 產生的 .words.json")
    pl.add_argument("--max-char", type=float, default=0.6, help="單一中文字超過幾秒算拖音（預設 0.6，0 = 不處理）")
    pl.add_argument("--trim-to", type=float, default=0.4, help="拖音字保留前幾秒（預設 0.4）")
    pl.add_argument("--no-vad", action="store_true", help="不用人聲偵測校正時間碼")
    pl.add_argument("--min-logprob", type=float, default=-1.0, help="漏字補抓的片段信心低於此值 → 標 review（預設 -1.0）")
    pl.add_argument("--split-gap", type=float, default=0.3, help="給 Claude 的逐句稿：停頓超過幾秒就斷句（預設 0.3）")
    pl.set_defaults(func=cmd_plan)

    def render_args(r):
        r.add_argument("input", help="原始影音檔")
        r.add_argument("plan", help=".plan.csv")
        r.add_argument("--deletes", help="Claude 回覆的刪除清單（deletes.txt）；有這個檔時，review 只剪清單上的 R 編號")
        r.add_argument("--cut-review", action="store_true", help="沒有 deletes 時，連 review（疑似贅詞）也剪掉")
        r.add_argument("--max-pause", type=float, default=0.35, help="安靜超過幾秒的停頓要壓縮（預設 0.35）")
        r.add_argument("--keep-pause", type=float, default=0.22, help="壓縮後保留幾秒（預設 0.22，越長的停頓會略多留一點）")
        r.add_argument("--min-gap-sentence", type=float, default=0.12, help="剪接處在句與句之間時，至少保留幾秒停頓（預設 0.12）")
        r.add_argument("--min-gap-phrase", type=float, default=0.03, help="剪接處在句子中間時，至少保留幾秒（預設 0.03）")
        r.add_argument("--min-cut", type=float, default=0.1, help="要剪的內容合計短於幾秒就不剪，避免多餘的剪接點（預設 0.1）")
        r.add_argument("--quiet-db", type=float, default=12, help="高出底噪幾 dB 以內算安靜（預設 12）")
        r.add_argument("--snap", type=float, default=0.04, help="剪接點往前後找最安靜位置的範圍（秒，預設 0.04）")
        r.add_argument("--xfade", type=float, default=0.02, help="剪接處交叉淡化長度（秒，預設 0.02）")
        r.add_argument("--xfade-long", type=float, default=0.06, help="剪在有聲音處時的淡化長度（秒，預設 0.06）")
        r.add_argument("--breath-margin", type=float, default=8, help="停頓中高出底噪幾 dB 算呼吸／雜音（預設 8）")
        r.add_argument("--breath-cut", type=float, default=18, help="呼吸／雜音最多壓低幾 dB（預設 18，0 = 不處理）")
        r.add_argument("--no-roomtone", action="store_true", help="停頓不足時不補合成底噪")
        r.add_argument("--denoise", action="store_true", help="順便做輕度降噪")
        r.add_argument("--loudnorm", action="store_true", help="音量標準化到 -16 LUFS（Podcast 常用）")
        r.add_argument("--format", default="mp3", help="音訊檔的輸出格式：mp3／m4a／wav／flac…（預設 mp3；影片一律輸出 mp4）")
        r.add_argument("--sample-rate", type=int, default=44100, help="輸出取樣率（預設 44100；0 = 跟原檔相同）")
        r.add_argument("--crf", type=int, default=18, help="畫質，數字越小越好（預設 18）")
        r.add_argument("--preset", default="medium")
        r.add_argument("-o", "--output")

    r = sub.add_parser("render", help="輸出剪好的檔案")
    render_args(r)
    r.add_argument("--report", help="輸出剪接片段清單（JSON，除錯用）")
    r.set_defaults(func=cmd_render)

    f = sub.add_parser("refine", help="輸出後重新辨識成品，補剪殘留語助詞，重複數輪（品質最好、較慢）")
    render_args(f)
    f.add_argument("--rounds", type=int, default=3, help="最多幾輪（預設 3，沒有新發現會提早結束）")
    f.add_argument("--model", default="large-v3")
    f.add_argument("--language", default="zh")
    f.add_argument("--device", default="auto")
    f.add_argument("--compute-type", default="default")
    f.add_argument("--prompt", default=None)
    f.set_defaults(func=cmd_refine)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
