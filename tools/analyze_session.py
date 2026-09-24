#!/usr/bin/env python3
"""分析 InkProbe 会话中 strokes.json 的体积来源，以及片段指纹为何在步骤之间变化。

用法：
    python3 tools/analyze_session.py <会话文件夹（原始格式或精简格式均可）>

输出：
1. 各字段在全部 strokes.json 中所占的字节数；
2. 片段总数、不同 fragmentHash 的数量；
3. 相邻两步中同一 pathHash、片段数相同的片段，哪些字段发生了变化；
4. 体积最大的 5 个片段的明细。
只使用 Python 3 标准库。
"""

import json
import sys
from collections import Counter
from pathlib import Path


def load(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def size(value):
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def mb(n):
    return f"{n / 1024 / 1024:.1f} MB"


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 1
    session = Path(sys.argv[1])
    steps_dir = session / "steps"
    step_dirs = sorted([d for d in steps_dir.iterdir() if d.is_dir()], key=lambda d: d.name) if steps_dir.is_dir() else []
    files = [(d.name, d / "strokes.json") for d in step_dirs if (d / "strokes.json").is_file()]
    if (session / "final" / "strokes.json").is_file():
        files.append(("final", session / "final" / "strokes.json"))
    if not files:
        print("没有找到 strokes.json")
        return 1

    field_bytes = Counter()
    total_fragments = 0
    hashes = set()
    biggest = []
    changed_fields = Counter()
    compared = 0
    identical = 0
    previous_by_path = None

    for name, path in files:
        doc = load(path)
        strokes = [s for s in doc.get("strokes", []) if "points" in s]
        by_path = {}
        for s in strokes:
            total_fragments += 1
            hashes.add(s.get("fragmentHash"))
            for key, value in s.items():
                field_bytes[key] += size(value)
            biggest.append((size(s), name, s))
            by_path.setdefault(s.get("pathHash"), []).append(s)
        biggest.sort(key=lambda item: -item[0])
        del biggest[5:]

        if name != "final" and previous_by_path is not None:
            for path_hash, now in by_path.items():
                before = previous_by_path.get(path_hash)
                if not before or len(before) != len(now):
                    continue
                for a, b in zip(before, now):
                    compared += 1
                    diffs = [k for k in set(a) | set(b) if k != "index" and a.get(k) != b.get(k)]
                    if not diffs:
                        identical += 1
                    for k in diffs:
                        changed_fields[k] += 1
        if name != "final":
            previous_by_path = by_path

    print(f"strokes.json 文件数：{len(files)}（含 final）")
    print(f"片段总数：{total_fragments}，不同 fragmentHash：{len(hashes)}")
    print()
    print("各字段总字节数：")
    total = sum(field_bytes.values())
    for key, n in field_bytes.most_common():
        print(f"  {key:22s} {mb(n):>10s}  {n / total * 100:5.1f}%")
    print()
    print(f"相邻两步中可对应的片段（同 pathHash、片段数相同）：{compared}，完全相同：{identical}")
    if changed_fields:
        print("发生变化的字段（片段数）：")
        for key, n in changed_fields.most_common():
            print(f"  {key:22s} {n}")
    print()
    print("体积最大的 5 个片段：")
    for n, name, s in biggest:
        mask = s.get("mask")
        print(
            f"  {mb(n):>9s}  步骤 {name}  pathCount={s.get('pathCount')}  "
            f"points={len(s.get('points', []))}  interpolated={len(s.get('interpolatedPoints', []))}  "
            f"mask={len(mask) if mask else 0} 字符  ranges={len(s.get('maskedPathRanges', []))}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
