#!/usr/bin/env python3
"""把旧版 InkProbe 会话文件夹转换为精简格式。

旧版导出中，每个 steps/NNNN/strokes.json 都包含当时画布上全部笔划的完整数据，
总大小随“步数 × 笔划数”增长。本脚本生成一份新的精简文件夹，原文件夹不做任何修改：

1. steps/NNNN/strokes.json 改为增量编码，按以下顺序判断每个片段：
   a. 片段（fragmentHash）在之前出现过：只写引用
      {"index", "fragmentHash", "pathHash", "fullDataStep", "fullDataDir"}，
      完整数据在 steps/<fullDataDir>/strokes.json 中。
   b. 片段是新的，但它的来源路径（pathHash）在之前出现过：写片段自身的全部字段
      （mask、maskedPathRanges、transform、renderBounds 等），但去掉 points 和
      interpolatedPoints，改为 "pathDataStep"、"pathDataDir" 指向路径数据所在的步骤。
      像素橡皮反复擦同一条笔划时，每一步只有 mask 和区间在变，路径数据只需存一次。
   c. 其他情况：写完整数据。
   说明：interpolatedPoints 是 PencilKit 按当时的 maskedPathRanges 逐段计算的，情况 b 中
   不再保留这一步各区间的插值点；需要时可由该步的 drawing.drawing 在原生端重新计算。
   points（控制点）只取决于路径，校验会确认它与引用处完全一致。
2. 所有 JSON 去掉缩进和换行。数值原样保留：Python 的 float 输出同样是最短往返表示，
   不会丢失精度。
3. steps 中只保留最后一步的 render@2x.png。final/ 中的位图全部保留。

final/strokes.json 仍然是完整数据（只压缩格式）。meta.json 中增加 exportFormat 字段说明以上变化。

默认会校验：情况 a 中引用所指的完整数据去掉 index 后必须与原数据完全一致；
情况 b 中去掉的 points 必须与引用处的 points 完全一致。

用法：
    python3 tools/slim_sessions.py <会话文件夹 | sessions 目录 | 导出的 zip> ... [-o 输出目录] [-j 4]

可以同时给出多个输入，所有会话默认 4 个一组并行处理（-j 修改并行数）。
不指定 -o 时，输出到第一个输入旁边的 <输入名>-slim 目录。只使用 Python 3 标准库。
"""

import argparse
import json
import os
from concurrent.futures import ProcessPoolExecutor, as_completed
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

EXPORT_FORMAT = {
    "stepStrokes": "incremental",
    "stepPathData": "firstAppearanceOnly",
    "stepImages": "lastStepOnly",
    "json": "compact",
}


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def dump_json(obj, path):
    text = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
        f.write("\n")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)


def canonical_without_index(stroke):
    """去掉 index 后的规范 JSON 文本，用于判断两个片段的数据是否完全一致。"""
    rest = {k: v for k, v in stroke.items() if k != "index"}
    return json.dumps(rest, ensure_ascii=False, separators=(",", ":"), sort_keys=True, allow_nan=False)


def is_session_dir(path):
    return path.is_dir() and (path / "input.json").is_file()


def find_sessions(path):
    """在输入路径下查找会话文件夹（包含 input.json 的目录），最多向下查找两层。"""
    if is_session_dir(path):
        return [path]
    found = []
    if path.is_dir():
        for child in sorted(path.iterdir()):
            if is_session_dir(child):
                found.append(child)
            elif child.is_dir():
                found.extend(c for c in sorted(child.iterdir()) if is_session_dir(c))
    return found


def dir_size(path):
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} GB"


def step_number(step_dir):
    step_json = step_dir / "step.json"
    if step_json.is_file():
        value = load_json(step_json).get("step")
        if isinstance(value, int):
            return value
    return int(step_dir.name)


def slim_session(src, dst, verify):
    if dst.exists():
        raise RuntimeError(f"输出目录已存在：{dst}（使用 --force 覆盖）")
    dst.mkdir(parents=True)

    # meta.json：保留原内容，追加 exportFormat。
    meta_path = src / "meta.json"
    if meta_path.is_file():
        meta = load_json(meta_path)
        if "exportFormat" in meta:
            raise RuntimeError("该会话已经是精简格式，无需处理")
        meta["exportFormat"] = dict(EXPORT_FORMAT, slimmedBy="tools/slim_sessions.py")
        dump_json(meta, dst / "meta.json")
    else:
        print("  注意：缺少 meta.json（该会话保存未完成），其余文件照常处理")

    dump_json(load_json(src / "input.json"), dst / "input.json")

    # final/：JSON 压缩格式，其余文件原样复制。
    src_final = src / "final"
    if src_final.is_dir():
        dst_final = dst / "final"
        dst_final.mkdir()
        for item in sorted(src_final.iterdir()):
            if item.name == "strokes.json":
                doc = load_json(item)
                dump_json(with_encoding(doc, "full"), dst_final / item.name)
            elif item.is_file():
                shutil.copy2(item, dst_final / item.name)

    # steps/：增量编码，只保留最后一步的位图。
    src_steps = src / "steps"
    dst_steps = dst / "steps"
    dst_steps.mkdir()
    step_dirs = [d for d in src_steps.iterdir() if d.is_dir()] if src_steps.is_dir() else []
    step_dirs.sort(key=step_number)

    fragment_written = {}   # fragmentHash -> (步骤号, 文件夹名)
    path_written = {}       # pathHash -> (步骤号, 文件夹名)
    fragment_canonical = {}  # fragmentHash -> 规范文本（仅在校验时使用）
    path_points = {}        # pathHash -> points 的规范文本（仅在校验时使用）
    counts = {"full": 0, "pathRef": 0, "fragmentRef": 0}

    for position, step_dir in enumerate(step_dirs):
        number = step_number(step_dir)
        is_last = position == len(step_dirs) - 1
        out_dir = dst_steps / step_dir.name
        out_dir.mkdir()
        location = (number, step_dir.name)

        for item in sorted(step_dir.iterdir()):
            if not item.is_file():
                continue
            if item.name == "strokes.json":
                doc = load_json(item)
                if doc.get("strokesEncoding") == "incremental":
                    raise RuntimeError(f"{step_dir.name}/strokes.json 已经是增量编码")
                strokes = []
                for stroke in doc.get("strokes", []):
                    fragment = stroke["fragmentHash"]
                    path_hash = stroke.get("pathHash")
                    if fragment in fragment_written:
                        # a. 片段已出现过
                        if verify and fragment_canonical[fragment] != canonical_without_index(stroke):
                            raise RuntimeError(
                                f"校验失败：步骤 {number} 中片段 {fragment} 与步骤 "
                                f"{fragment_written[fragment][0]} 中的完整数据不一致"
                            )
                        strokes.append({
                            "index": stroke["index"],
                            "fragmentHash": fragment,
                            "pathHash": path_hash,
                            "fullDataStep": fragment_written[fragment][0],
                            "fullDataDir": fragment_written[fragment][1],
                        })
                        counts["fragmentRef"] += 1
                        continue

                    fragment_written[fragment] = location
                    if verify:
                        fragment_canonical[fragment] = canonical_without_index(stroke)

                    if path_hash in path_written:
                        # b. 新片段，路径已出现过
                        if verify and path_points[path_hash] != canonical(stroke.get("points")):
                            raise RuntimeError(
                                f"校验失败：步骤 {number} 中路径 {path_hash} 的 points 与步骤 "
                                f"{path_written[path_hash][0]} 中的不一致"
                            )
                        slim = {k: v for k, v in stroke.items() if k not in ("points", "interpolatedPoints")}
                        slim["pathDataStep"] = path_written[path_hash][0]
                        slim["pathDataDir"] = path_written[path_hash][1]
                        strokes.append(slim)
                        counts["pathRef"] += 1
                    else:
                        # c. 完整数据
                        path_written[path_hash] = location
                        if verify:
                            path_points[path_hash] = canonical(stroke.get("points"))
                        strokes.append(stroke)
                        counts["full"] += 1
                doc["strokes"] = strokes
                dump_json(with_encoding(doc, "incremental"), out_dir / item.name)
            elif item.name.endswith(".json"):
                dump_json(load_json(item), out_dir / item.name)
            elif item.suffix.lower() == ".png":
                if is_last:
                    shutil.copy2(item, out_dir / item.name)
            else:
                shutil.copy2(item, out_dir / item.name)

    return len(step_dirs), counts


def with_encoding(doc, encoding):
    """在 schemaVersion 之后插入 strokesEncoding，保持其余键的顺序。"""
    result = {}
    for key, value in doc.items():
        result[key] = value
        if key == "schemaVersion":
            result["strokesEncoding"] = encoding
    if "strokesEncoding" not in result:
        result["strokesEncoding"] = encoding
    return result


def process_one(src, dst, force, verify):
    """在子进程中处理一个会话，返回 (会话名, 是否成功, 结果文本, 转换前字节数, 转换后字节数)。"""
    if dst.exists() and force:
        shutil.rmtree(dst)
    existed = dst.exists()
    try:
        steps, counts = slim_session(src, dst, verify=verify)
    except Exception as error:  # 单个会话失败不影响其他会话
        # 只删除本次创建的不完整输出，不删除已存在的目录。
        if not existed and dst.exists():
            shutil.rmtree(dst)
        return src.name, False, f"失败：{error}", 0, 0
    before = dir_size(src)
    after = dir_size(dst)
    text = (
        f"{steps} 步；完整数据 {counts['full']} 个，共享路径数据 {counts['pathRef']} 个，"
        f"引用已有片段 {counts['fragmentRef']} 个；{human(before)} → {human(after)}"
    )
    return src.name, True, text, before, after


def main():
    parser = argparse.ArgumentParser(description="把 InkProbe 会话转换为精简格式（增量 steps、压缩 JSON、只保留最后一步位图）。")
    parser.add_argument("inputs", nargs="+", type=Path, help="会话文件夹、sessions 目录或导出的 zip")
    parser.add_argument("-o", "--output", type=Path, help="输出目录，默认为 <第一个输入>-slim")
    parser.add_argument("--force", action="store_true", help="输出目录中已有同名会话时覆盖")
    parser.add_argument("--no-verify", action="store_true", help="跳过无损校验")
    parser.add_argument("-j", "--jobs", type=int, default=4,
                        help="同时处理的会话数，默认 4；每个进程约占用数百 MB 内存")
    args = parser.parse_args()

    first = args.inputs[0].resolve()
    base_name = first.stem if first.suffix.lower() == ".zip" else first.name
    output = (args.output or first.parent / f"{base_name}-slim").resolve()

    temp_dirs = []
    sessions = []
    try:
        for raw in args.inputs:
            path = raw.resolve()
            if path.is_file() and path.suffix.lower() == ".zip":
                temp = Path(tempfile.mkdtemp(prefix="inkprobe-slim-"))
                temp_dirs.append(temp)
                with zipfile.ZipFile(path) as zf:
                    zf.extractall(temp)
                found = find_sessions(temp)
            else:
                found = find_sessions(path)
            if not found:
                print(f"未在 {raw} 中找到会话文件夹（需要包含 input.json）", file=sys.stderr)
            sessions.extend(found)

        if not sessions:
            return 1

        # 不同输入中若有同名会话，输出会互相覆盖，因此直接报错。
        names = {}
        for src in sessions:
            if src.name in names:
                print(f"同名会话出现两次：{names[src.name]} 与 {src}", file=sys.stderr)
                return 1
            names[src.name] = src

        output.mkdir(parents=True, exist_ok=True)
        failures = 0
        total_before = 0
        total_after = 0
        jobs = max(1, min(args.jobs, len(sessions), os.cpu_count() or 1))
        print(f"共 {len(sessions)} 个会话，同时处理 {jobs} 个")
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            futures = [
                pool.submit(process_one, src, output / src.name, args.force, not args.no_verify)
                for src in sessions
            ]
            for future in as_completed(futures):
                name, ok, text, before, after = future.result()
                if ok:
                    total_before += before
                    total_after += after
                    print(f"完成 {name}：{text}")
                else:
                    failures += 1
                    print(f"{name}：{text}", file=sys.stderr)

        print(f"输出目录：{output}")
        if total_before:
            print(f"合计：{human(total_before)} → {human(total_after)}")
        if failures:
            print(f"失败 {failures} 个", file=sys.stderr)
        return 1 if failures else 0
    finally:
        for temp in temp_dirs:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
