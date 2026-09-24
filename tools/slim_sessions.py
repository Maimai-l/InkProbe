#!/usr/bin/env python3
"""把旧版 InkProbe 会话文件夹转换为精简格式。

旧版导出中，每个 steps/NNNN/strokes.json 都包含当时画布上全部笔划的完整数据，
总大小随“步数 × 笔划数”增长。本脚本生成一份新的精简文件夹，原文件夹不做任何修改：

1. steps/NNNN/strokes.json 改为增量编码：某个片段（fragmentHash）第一次出现时写完整数据，
   之后只写引用 {"index", "fragmentHash", "pathHash", "fullDataStep", "fullDataDir"}，
   完整数据在 steps/<fullDataDir>/strokes.json 中（fullDataStep 是对应的步骤号）。
2. 所有 JSON 去掉缩进和换行。数值原样保留：Python 的 float 输出同样是最短往返表示，
   不会丢失精度。
3. steps 中只保留最后一步的 render@2x.png。final/ 中的位图全部保留。

final/strokes.json 仍然是完整数据（只压缩格式）。meta.json 中增加 exportFormat 字段说明以上变化。

默认会校验转换是否无损：每个引用所指的完整数据，去掉 index 后必须与原始数据完全一致。

用法：
    python3 tools/slim_sessions.py <会话文件夹 | sessions 目录 | 导出的 zip> ... [-o 输出目录]

不指定 -o 时，输出到第一个输入旁边的 <输入名>-slim 目录。只使用 Python 3 标准库。
"""

import argparse
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

EXPORT_FORMAT = {
    "stepStrokes": "incremental",
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

    written = {}    # fragmentHash -> (首次写入完整数据的步骤号, 文件夹名)
    canonical = {}  # fragmentHash -> 规范文本（仅在校验时使用）
    full_count = 0
    ref_count = 0

    for position, step_dir in enumerate(step_dirs):
        number = step_number(step_dir)
        is_last = position == len(step_dirs) - 1
        out_dir = dst_steps / step_dir.name
        out_dir.mkdir()

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
                    if fragment in written:
                        if verify and canonical[fragment] != canonical_without_index(stroke):
                            raise RuntimeError(
                                f"校验失败：步骤 {number} 中片段 {fragment} 与步骤 "
                                f"{written[fragment][0]} 中的完整数据不一致"
                            )
                        strokes.append({
                            "index": stroke["index"],
                            "fragmentHash": fragment,
                            "pathHash": stroke.get("pathHash"),
                            "fullDataStep": written[fragment][0],
                            "fullDataDir": written[fragment][1],
                        })
                        ref_count += 1
                    else:
                        written[fragment] = (number, step_dir.name)
                        if verify:
                            canonical[fragment] = canonical_without_index(stroke)
                        strokes.append(stroke)
                        full_count += 1
                doc["strokes"] = strokes
                dump_json(with_encoding(doc, "incremental"), out_dir / item.name)
            elif item.name.endswith(".json"):
                dump_json(load_json(item), out_dir / item.name)
            elif item.suffix.lower() == ".png":
                if is_last:
                    shutil.copy2(item, out_dir / item.name)
            else:
                shutil.copy2(item, out_dir / item.name)

    return len(step_dirs), full_count, ref_count


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


def main():
    parser = argparse.ArgumentParser(description="把 InkProbe 会话转换为精简格式（增量 steps、压缩 JSON、只保留最后一步位图）。")
    parser.add_argument("inputs", nargs="+", type=Path, help="会话文件夹、sessions 目录或导出的 zip")
    parser.add_argument("-o", "--output", type=Path, help="输出目录，默认为 <第一个输入>-slim")
    parser.add_argument("--force", action="store_true", help="输出目录中已有同名会话时覆盖")
    parser.add_argument("--no-verify", action="store_true", help="跳过无损校验")
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

        output.mkdir(parents=True, exist_ok=True)
        failures = 0
        total_before = 0
        total_after = 0
        for src in sessions:
            dst = output / src.name
            print(f"处理 {src.name}")
            if dst.exists() and args.force:
                shutil.rmtree(dst)
            existed = dst.exists()
            try:
                steps, full, refs = slim_session(src, dst, verify=not args.no_verify)
            except Exception as error:  # 单个会话失败不影响其他会话
                failures += 1
                print(f"  失败：{error}", file=sys.stderr)
                # 只删除本次创建的不完整输出，不删除已存在的目录。
                if not existed and dst.exists():
                    shutil.rmtree(dst)
                continue
            before = dir_size(src)
            after = dir_size(dst)
            total_before += before
            total_after += after
            print(f"  {steps} 步，完整片段 {full} 个，引用 {refs} 个；{human(before)} → {human(after)}")

        print(f"输出目录：{output}")
        if total_before:
            print(f"合计：{human(total_before)} → {human(total_after)}")
        return 1 if failures else 0
    finally:
        for temp in temp_dirs:
            shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
