#!/usr/bin/env python3
"""產生 SideStore／AltStore 的來源檔（source.json）。

用法：make_source.py <ipa> <版本> <build> <commit sha> <輸出路徑>
來源網址固定為 https://github.com/<repo>/releases/latest/download/source.json，
SideStore 加入一次後，每次 CI 發布新版就會顯示「Update」。
"""
import datetime
import json
import os
import subprocess
import sys

ipa, version, build, sha, out = sys.argv[1:6]
repo = os.environ.get("GITHUB_REPOSITORY", "lutyyy/voice_app")
tag = f"build-{build}"
icon = f"https://raw.githubusercontent.com/{repo}/{sha}/ios/VoiceCut/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
try:
    notes = subprocess.run(["git", "log", "-1", "--format=%s", sha], capture_output=True, text=True).stdout.strip()
except OSError:
    notes = ""

description = ("自動剪掉影音檔裡的語助詞（嗯、呃、欸…）、口吃重複、過長的停頓與停頓中的呼吸聲。"
               "語音辨識與剪輯都在 iPhone 上完成。")
source = {
    "name": "語音剪輯",
    "identifier": "com.lutyyy.voicecut.source",
    "subtitle": "自動剪輯口語影音",
    "description": description,
    "iconURL": icon,
    "website": f"https://github.com/{repo}",
    "tintColor": "#4F46E5",
    "apps": [{
        "name": "語音剪輯",
        "bundleIdentifier": "com.lutyyy.voicecut",
        "developerName": "lutyyy",
        "subtitle": "自動剪掉語助詞、口吃與停頓",
        "localizedDescription": description,
        "iconURL": icon,
        "tintColor": "#4F46E5",
        "category": "utilities",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes or f"第 {build} 版",
            "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/VoiceCut.ipa",
            "size": os.path.getsize(ipa),
            "minOSVersion": "17.0",
        }],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
print(json.dumps(source["apps"][0]["versions"][0], ensure_ascii=False, indent=2))
