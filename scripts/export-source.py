#!/usr/bin/env python3
"""Export only the reviewed public source from the product workspace to release/sonicpeek-public.

Allowlist: the Swift package, sources, tests, resources, build / release / art scripts, the public
README files and screenshots. Internal handoffs, tickets, evidence, the video pipeline and build
products never leave the workspace. Git operations belong only in the public checkout.
"""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parent.parent
target = root / "release" / "sonicpeek-public"
if not (root / "Public" / "README.md").is_file():
    raise SystemExit("Run this export from the product workspace, not the public checkout.")
if target.is_symlink():
    raise SystemExit("Refusing a symlink export target.")
if target.exists() and any(target.iterdir()) and not (target / ".sonicpeek-public-export").is_file():
    raise SystemExit("Refusing an unrecognized non-empty export directory.")
target.mkdir(parents=True, exist_ok=True)
(target / ".sonicpeek-public-export").write_text("SonicPeek public export\n")
ignore = shutil.ignore_patterns(".DS_Store", "__pycache__", "*.pyc", "*.blend1")
for name in ("Sources", "Tests", "Resources"):
    shutil.copytree(root / name, target / name, dirs_exist_ok=True, ignore=ignore)
for name in ("Package.swift", "LICENSE"):
    shutil.copy2(root / name, target / name)
(target / "scripts").mkdir(exist_ok=True)
for name in ("build.sh", "package-release.sh", "export-source.py"):
    shutil.copy2(root / "scripts" / name, target / "scripts" / name)
for name in ("blender", "icon"):
    shutil.copytree(root / "scripts" / name, target / "scripts" / name, dirs_exist_ok=True, ignore=ignore)
for name in ("README.md", "README.zh-Hant.md"):
    shutil.copy2(root / "Public" / name, target / name)
shutil.copytree(root / "Public" / "screenshots", target / "docs" / "screenshots", dirs_exist_ok=True, ignore=ignore)
# GitHub Pages (main /docs): the tutorial page, a 720p web cut of the video (~5 MB) and its poster.
shutil.copytree(root / "Public" / "site", target / "docs", dirs_exist_ok=True, ignore=ignore)
for stale in ("light-stereo-waveform.webp", "light-714-channels.webp"):
    (target / "docs" / "screenshots" / stale).unlink(missing_ok=True)
(target / ".gitignore").write_text(".build/\n.swiftpm/\nbuild/\nDerivedData/\n.DS_Store\nxcuserdata/\nPackage.resolved\n"
                                   ".sonicpeek-public-export\n__pycache__/\n*.log\n")
print(f"Exported to {target}; existing Git metadata and unrelated files were preserved.")
