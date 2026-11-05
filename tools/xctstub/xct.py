#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xctstub —— 本机没有 XCTest（CommandLineTools 2026-10-22 起不带）时的跑具。

它做三件事：
1. 解析 Tests/ 下的用例文件，找出 `class X: XCTestCase` 与 `func testY()`，
   生成一个显式点名的 main（Swift 没有反射枚举方法的能力）。
2. 用 `swift build` 已经产出的模块（.build/<triple>/debug/Modules/*.swiftmodule，
   全部带 -enable-testing，所以 `@testable import` 照样能用）编译
   桩件 + 生成的 main + **未改动的仓库用例文件**，链上依赖模块的 .o。
3. 跑起来，按用例逐条记账，打印「用例 N · 红 M · 跳过 S」，有红就退出码 1。

用法：
    python3 tools/xctstub/xct.py list
    python3 tools/xctstub/xct.py run GestureEngineTests
    python3 tools/xctstub/xct.py run ScreenshotTests --only testEscStepsDown
    python3 tools/xctstub/xct.py regress            # suites.json 里 ordered 的全跑
    python3 tools/xctstub/xct.py selfcheck          # 桩件自证：故意写反的必须红

环境变量：
    FILES=/abs/a.swift,/abs/b.swift   覆盖用例文件清单（临时单跑某一份用例用）
    NO_BUILD=1                        跳过 swift build（变异执行器自己控制重编时机）

桩件的语义对齐与陷阱写在 XCTestStub.swift 顶部。
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STUB_DIR = os.path.join(REPO, "tools", "xctstub")
WORK_DIR = os.path.join(REPO, ".build", "xctstub")
MANIFEST = os.path.join(STUB_DIR, "suites.json")

CLASS_RE = re.compile(r"^\s*(?:public\s+|open\s+|final\s+|internal\s+)*class\s+(\w+)\s*:\s*XCTestCase\b")
TEST_RE = re.compile(r"^\s*(?:public\s+|open\s+|final\s+)*func\s+(test\w*)\s*\(([^)]*)\)\s*(async\b)?(throws\b)?")


def read_manifest():
    with open(MANIFEST, encoding="utf-8") as handle:
        return json.load(handle)


def description():
    path = os.path.join(REPO, ".build", "debug", "description.json")
    if not os.path.exists(path):
        sys.exit("没有 %s —— 先跑一次 swift build" % path)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def build_paths(desc):
    """从 description.json 反推 .build/<triple>/debug 这一层。"""
    sample = next(iter(desc["swiftCommands"].values()))
    modules = sample["importPath"]
    debug_dir = os.path.dirname(modules)
    return debug_dir, modules


def swift_flags(desc):
    """复用 SwiftPM 自己那组编译开关，去掉只对「建模块」有意义的。"""
    sample = next(iter(desc["swiftCommands"].values()))
    value_flags = {"-index-store-path", "-emit-objc-header-path", "-package-name", "-module-name"}
    drop_flags = {"-emit-objc-header", "-parseable-output", "-enable-batch-mode", "-parse-as-library"}
    args = list(sample["otherArguments"])
    out, i = [], 0
    while i < len(args):
        arg = args[i]
        if arg in value_flags:
            i += 2
            continue
        if arg in drop_flags:
            i += 1
            continue
        if arg.startswith("-j"):
            out.append("-j%d" % (os.cpu_count() or 4))
            i += 1
            continue
        out.append(arg)
        i += 1
    return out


def closure(desc, target):
    deps = desc["targetDependencyMap"]

    def walk(name, seen):
        if name in seen:
            return
        seen.add(name)
        for dep in deps.get(name, []):
            walk(dep, seen)

    seen = set()
    walk(target, seen)
    seen.discard(target)
    return sorted(seen)


def objects_by_module(desc):
    """moduleName → 该模块的 .o 清单，直接取 SwiftPM 自己的记录。

    别去 glob `<Module>.build/**/*.o`：像 SQLite 这种带子目录源码的包，同一份
    `Value.swift` 会在 `SQLite.build/Core/Value.swift.o` 和 `SQLite.build/Value.swift.o`
    各留一个，glob 出来就是 1956 个 duplicate symbol。
    """
    index = {}
    for command in desc["swiftCommands"].values():
        module = command.get("moduleName")
        if not module:
            continue
        index.setdefault(module, []).extend(command.get("objects", []))
    for module in index:
        index[module] = sorted(set(index[module]))
    return index


def objects_for(index, modules):
    out = []
    for module in modules:
        if module not in index:
            sys.exit("description.json 里没有模块 %s 的编译记录（先 swift build）" % module)
        out.extend(index[module])
    return out


def parse_tests(files):
    """[(suite, [(test, throws), ...]), ...] —— 按文件出现顺序。

    `throws` 决定生成的 main 里要不要给这一条加 `try`：不加会「call can throw」，
    加了又不会抛则满屏 warning，两者都盖掉真正的红。
    """
    suites = []
    index = {}
    for path in files:
        current = None
        with open(path, encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                match = CLASS_RE.match(line)
                if match:
                    name = match.group(1)
                    if name not in index:
                        index[name] = []
                        suites.append(name)
                    current = name
                    continue
                match = TEST_RE.match(line)
                if match and current:
                    if match.group(3):
                        sys.exit("%s:%d 的用例 %s 是 async —— 桩件跑不了 async，改成"
                                 "同步 + expectation 或者整条跳过" % (path, number, match.group(1)))
                    index[current].append((match.group(1), bool(match.group(4))))
    return [(name, index[name]) for name in suites if index[name]]


STUB_SRC = os.path.join(STUB_DIR, "XCTestStub.swift")
SHIMS_DIR = os.path.join(WORK_DIR, "shims")


def build_shim(desc, force=False):
    """把桩件编译成 **名字叫 XCTest 的模块**。

    用例文件第一行都是 `import XCTest`，仓库里的一个字都不能改，所以让那个 import
    落到这份桩件上：`-emit-module-path Shims/XCTest.swiftmodule` + 一个 XCTest.o，
    编译套件时把 Shims 排在 Modules 前面。
    """
    module_path = os.path.join(SHIMS_DIR, "XCTest.swiftmodule")
    object_path = os.path.join(SHIMS_DIR, "XCTest.o")
    fresh = (os.path.exists(module_path) and os.path.exists(object_path)
             and os.path.getmtime(module_path) > os.path.getmtime(STUB_SRC))
    if fresh and not force:
        return module_path, object_path
    # `-emit-module` 会先找同名的 XCTest.swiftmodule（Modules/ 下那份缓存就是），
    # 不先删掉的话它直接把旧的搬过来、根本不重编。
    os.makedirs(SHIMS_DIR, exist_ok=True)
    for stale in (module_path, object_path):
        if os.path.exists(stale):
            os.remove(stale)
    _, modules_dir = build_paths(desc)
    cmd = ["swiftc", "-module-name", "XCTest",
           "-emit-module", "-emit-module-path", module_path,
           "-c", "-o", object_path,
           "-I", modules_dir,
           # 复用回来的开关里 -parse-as-library 被摘掉了（生成的 main 要靠隐式入口），
           # 但桩件这一份必须带着，否则 swiftc 把它当主文件、往里塞一个 _main。
           "-parse-as-library"] + swift_flags(desc) + [STUB_SRC]
    log = os.path.join(SHIMS_DIR, "build.log")
    with open(log, "w", encoding="utf-8") as handle:
        result = subprocess.run(cmd, cwd=REPO, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        sys.exit("桩件模块 XCTest 编译失败：\n" + open(log, encoding="utf-8").read()[-3000:])
    return module_path, object_path


def generated_main(files):
    suites = parse_tests(files)
    lines = [
        "// 由 tools/xctstub/xct.py 生成，别手改。",
        "import Foundation",
        "import XCTest",
        "",
    ]
    for suite, tests in suites:
        for name, throws in tests:
            call = ("try t.%s()" if throws else "t.%s()") % name
            lines.append('_stubAdd("%s", %s.self, "%s") { (t: %s) throws in %s }'
                         % (suite, suite, name, suite, call))
    lines.append("")
    lines.append("exit(_stubRun())")
    lines.append("")
    return suites, "\n".join(lines)


def prepare_resources(binary_path, bundle_name):
    """L() 找的是「可执行文件旁边 *.bundle/xx.lproj/Localizable.strings」。"""
    directory = os.path.dirname(binary_path)
    bundle = os.path.join(directory, bundle_name + ".bundle")
    for language in ("en", "zh-Hans"):
        source = os.path.join(REPO, "Sources", "MacStrokeApp", "Resources", language + ".lproj",
                              "Localizable.strings")
        target = os.path.join(bundle, language + ".lproj")
        os.makedirs(target, exist_ok=True)
        if os.path.exists(source):
            shutil.copyfile(source, os.path.join(target, "Localizable.strings"))
    return bundle


def run_suite(name, spec, only=None, no_build=False, quiet=False):
    desc = description()
    debug_dir, modules_dir = build_paths(desc)
    if not no_build:
        subprocess.run(["swift", "build"], cwd=REPO, check=True,
                       stdout=subprocess.DEVNULL if quiet else subprocess.PIPE)

    files = spec.get("files")
    if os.environ.get("FILES"):
        files = [item for item in os.environ["FILES"].split(",") if item]
    if not files:
        target_dir = os.path.join(REPO, "Tests", name)
        files = sorted(glob.glob(os.path.join(target_dir, "*.swift")))
        if not files:
            sys.exit("套件 %s 找不到用例文件（Tests/%s）" % (name, name))
    files = [f if os.path.isabs(f) else os.path.join(REPO, f) for f in files]

    work = os.path.join(WORK_DIR, name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    suites, main_text = generated_main(files)
    main_path = os.path.join(work, "main.swift")
    with open(main_path, "w", encoding="utf-8") as handle:
        handle.write(main_text)

    binary = os.path.join(work, "runner")
    shim_module, shim_object = build_shim(desc)
    cmd = ["swiftc", "-o", binary,
           "-I", os.path.dirname(shim_module),
           "-I", modules_dir]
    cmd += swift_flags(desc)
    cmd += [main_path] + files
    objects = [shim_object] + objects_for(objects_by_module(desc),
                                          closure(desc, spec.get("target", name)))
    cmd += objects
    if spec.get("link"):
        cmd += spec["link"]

    env = dict(os.environ)
    if only:
        env["ONLY"] = only
    log_path = os.path.join(work, "build.log")
    with open(log_path, "w", encoding="utf-8") as log:
        compiled = subprocess.run(cmd, cwd=REPO, stdout=log, stderr=subprocess.STDOUT, env=env)
    if compiled.returncode != 0:
        print("编译失败：%s（日志 %s）" % (name, log_path))
        tail = open(log_path, encoding="utf-8", errors="replace").read().splitlines()
        for line in tail[-25:]:
            print("  " + line)
        return {"suite": name, "compiled": False, "total": 0, "failed": 0, "skipped": 0}

    prepare_resources(binary, "XctStubResources")
    started = os.popen("date +%s").read().strip()
    result = subprocess.run([binary], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = result.stdout.decode("utf-8", "replace")
    run_log = os.path.join(work, "run.log")
    with open(run_log, "w", encoding="utf-8") as handle:
        handle.write(output)
    summary = parse_summary(output)
    summary["suite"] = name
    summary["compiled"] = True
    summary["seconds"] = int(os.popen("date +%s").read().strip()) - int(started)
    if not quiet:
        print("── %s：%s" % (name, " | ".join(
            ["用例 %d" % summary["total"], "红 %d" % summary["failed"], "跳过 %d" % summary["skipped"]]
            + (["耗时 %ds" % summary["seconds"]] if summary["seconds"] else []))))
        for line in summary["failures"]:
            print("   ✗ " + line)
    return summary


def parse_summary(output):
    total = failed = skipped = 0
    failures = []
    for line in output.splitlines():
        match = re.match(r"^SUMMARY total=(\d+) failed=(\d+) skipped=(\d+)", line)
        if match:
            total, failed, skipped = int(match.group(1)), int(match.group(2)), int(match.group(3))
        elif line.startswith("FAIL "):
            failures.append(line[5:])
        elif line.startswith("SKIP "):
            pass
    return {"total": total, "failed": failed, "skipped": skipped, "failures": failures}


def cmd_list(_args):
    manifest = read_manifest()
    for spec in manifest["suites"]:
        note = ("  # " + spec["note"]) if spec.get("note") else ""
        print("%-40s %s%s" % (spec["name"], spec.get("target", ""), note))


def cmd_run(args):
    manifest = read_manifest()
    specs = {spec["name"]: spec for spec in manifest["suites"]}
    if args.suite not in specs:
        sys.exit("suites.json 里没有 %s（先 xct.py list 看看有哪些）" % args.suite)
    summary = run_suite(args.suite, specs[args.suite], only=args.only,
                        no_build=args.no_build, quiet=args.quiet)
    sys.exit(1 if not summary["compiled"] or summary["failed"] else 0)


def cmd_regress(args):
    manifest = read_manifest()
    selected = args.suites or [spec["name"] for spec in manifest["suites"] if spec.get("in_regress", True)]
    specs = {spec["name"]: spec for spec in manifest["suites"]}
    rows, grand_total, grand_failed, grand_skipped = [], 0, 0, 0
    for name in selected:
        if name not in specs:
            sys.exit("suites.json 里没有 %s" % name)
        summary = run_suite(name, specs[name], no_build=args.no_build, quiet=args.quiet)
        rows.append(summary)
        grand_total += summary["total"]
        grand_failed += summary["failed"]
        grand_skipped += summary["skipped"]
    print()
    print("合计：用例 %d · 红 %d · 跳过 %d（%d 套）" % (grand_total, grand_failed, grand_skipped, len(rows)))
    for row in rows:
        flag = "OK " if row["compiled"] and not row["failed"] else "XX "
        print("  %s%-40s %5d 用例%8s" % (flag, row["suite"], row["total"],
                                         "" if row["compiled"] else " 编译失败"))
    sys.exit(1 if grand_failed or any(not row["compiled"] for row in rows) else 0)


def cmd_selfcheck(_args):
    """桩件自证：故意写反的必须全红、写对的必须全绿，否则「全绿」这三个字没意义。"""
    work = os.path.join(WORK_DIR, "_selfcheck")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    # 顶层登记语句只能在 main.swift 里，所以把 check.swift 复制成 main.swift。
    main_path = os.path.join(work, "main.swift")
    shutil.copyfile(os.path.join(STUB_DIR, "check.swift"), main_path)
    desc = description()
    _, modules_dir = build_paths(desc)
    shim_module, shim_object = build_shim(desc)
    binary = os.path.join(work, "check")
    cmd = ["swiftc", "-o", binary,
           "-I", os.path.dirname(shim_module),
           "-I", modules_dir] + swift_flags(desc) + [main_path, shim_object]
    result = subprocess.run(cmd, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        print(result.stdout.decode("utf-8", "replace"))
        sys.exit("桩件自证编译失败")
    out = subprocess.run([binary], stdout=subprocess.PIPE).stdout.decode("utf-8", "replace")
    print(out)
    summary = parse_summary(out)
    expect_red = int(re.search(r"EXPECT_FAILED (\d+)", out).group(1))
    expect_green = int(re.search(r"EXPECT_PASSED (\d+)", out).group(1))
    expect_skip = int(re.search(r"EXPECT_SKIPPED (\d+)", out).group(1))
    green = summary["total"] - summary["failed"] - summary["skipped"]
    if (summary["failed"], green, summary["skipped"]) != (expect_red, expect_green, expect_skip):
        sys.exit("桩件自证不对：期望 红%d/绿%d/跳%d，实际 红%d/绿%d/跳%d"
                 % (expect_red, expect_green, expect_skip,
                    summary["failed"], green, summary["skipped"]))
    print("桩件自证通过：故意写反的 %d 条全红、写对的 %d 条全绿、跳过的 %d 条记成跳过"
          % (expect_red, expect_green, expect_skip))


def main():
    parser = argparse.ArgumentParser(description="MacStroke 的 XCTest 桩件跑具")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list").set_defaults(func=cmd_list)
    run = sub.add_parser("run")
    run.add_argument("suite")
    run.add_argument("--only")
    run.add_argument("--no-build", action="store_true")
    run.add_argument("--quiet", action="store_true")
    run.set_defaults(func=cmd_run)
    regress = sub.add_parser("regress")
    regress.add_argument("suites", nargs="*")
    regress.add_argument("--no-build", action="store_true")
    regress.add_argument("--quiet", action="store_true")
    regress.set_defaults(func=cmd_regress)
    sub.add_parser("selfcheck").set_defaults(func=cmd_selfcheck)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
