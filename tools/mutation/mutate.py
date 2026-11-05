#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
反向变异执行器：把「坏法」一条条真装进源码，看用例咬不咬得住。

为什么要有它：一轮取证写完，用例全绿只说明**当前源码**是绿的，不说明判据有牙。
把每一处坏法真装进去跑一遍，才能把「判据洞」和「等价变异」分开。

    python3 tools/mutation/mutate.py --list   tools/mutation/issue78.json
    python3 tools/mutation/mutate.py          tools/mutation/issue78.json
    python3 tools/mutation/mutate.py --only R1,R3 tools/mutation/issue78.json

表（JSON）每条字段：
    id / bad       编号与这一条坏法（会原样进结论表）
    file           仓库相对路径
    anchor         要在源码里**恰好命中一次**的原文；命中 0 次或多次就跳过并记账
                   （锚点取的是「这条坏法改的那一手」，跑完拿它反查改动还不在不在）
    replace        装进去的坏版本
    build          要不要重新 `swift build`（改 .strings 的那些不用：跑具每次把两张表
                   重拷进 StubResources.bundle，用例是当数据读它们的）
    tests          ["Suite:/abs/X.swift", …]；Suite 是套件名（要在 suites.json 里），冒号后
                   是要单跑的用例文件。**一个文件一个元素**，逗号留给 xctstub 用，别塞进来
                   （起跑前 `check_specs` 会钉这一条）
    expect         true = 预期该被抓到；false = 明知离线咬不住（写进表是为了记账，
                   跑出来必须是「漏」，跑成「抓到」反而要回头查判据是不是在测别的东西）

三条硬规矩（都是以前踩过才写进来的）：
1. **起跑前**先把所有会被动的文件 SHA 记一遍，逐条还原后再核对 —— 不是跑完才备份。
2. 每条跑完立刻还原（`finally`），哪怕用例进程 trap 了、哪怕它把源码留脏了。
   桩件里进程一旦 trap 会整趟报「用例 0」，那是崩了不是绿，单独记成 TRAP。
3. 结论行的分母只算**本趟真跑过**的条数，不取表长。

证据落在 `.build/mutation/<ts>/`（progress.log + 每条一份原始输出 + results.json）；
**结论必须抄进 docs/ 里的那份台账**，不能只留在 /tmp 或 .build。
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
XCT = os.path.join(REPO, "tools", "xctstub", "xct.py")
SUMMARY_RE = re.compile(r"用例 (\d+) \| 红 (\d+) \| 跳过 (\d+)")


def sha(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()[:16]


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def run_case(case, log_path, progress):
    """装一条坏法 → 重编 → 单跑相关用例 → 还原。返回 (status, detail)。"""
    path = os.path.join(REPO, case["file"])
    original = read(path)
    hits = original.count(case["anchor"])
    if hits != 1:
        return "SKIP", "锚点在 %s 里命中 %d 次（要求恰好 1 次）" % (case["file"], hits)

    detail_rows = []
    started = time.time()
    try:
        write(path, original.replace(case["anchor"], case["replace"], 1))
        if case.get("build", True):
            built = subprocess.run(["swift", "build"], cwd=REPO,
                                   stdout=open(log_path, "w"), stderr=subprocess.STDOUT)
            if built.returncode != 0:
                return "BUILD-RED", ("编译不过，用例没跑（日志 %s）" % log_path)
        total = failed = 0
        for spec in case["tests"]:
            suite, _, files = spec.partition(":")
            env = dict(os.environ, NO_BUILD="1", FILES=files)
            proc = subprocess.run([sys.executable, XCT, "run", suite],
                                  cwd=REPO, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            text = proc.stdout.decode("utf-8", "replace")
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write("\n===== %s : %s =====\n%s\n" % (suite, files, text))
            match = SUMMARY_RE.search(text)
            if not match:
                return "NO-SUMMARY", "%s 没打出记账行（多半是桩件解析不到用例）" % suite
            got_total, got_failed = int(match.group(1)), int(match.group(2))
            if got_total == 0:
                # 用例进程 trap（Swift 侧 assert/崩溃）会让整趟报 0 —— 绝不能记成绿。
                return "TRAP", "%s 报「用例 0」：进程崩了，不是全绿\n%s" % (suite, text[-1500:])
            total += got_total
            failed += got_failed
            detail_rows.append("%s %d/%d 红" % (suite, got_failed, got_total))
        if failed:
            return "KILLED", "红 %d / 用例 %d ｜ %s" % (failed, total, "、".join(detail_rows))
        return "SURVIVED", "全绿（用例 %d）｜ %s" % (total, "、".join(detail_rows))
    finally:
        write(path, original)
        left = sha(path)
        if left != sha_of_text(original):
            progress.append("!! %s 还原后 SHA 变了：%s" % (case["file"], left))
    _ = started


def sha_of_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def check_specs(cases):
    """起跑前把每条坏法的 `tests` 形状钉一遍（`--list` 也会走这一手）。

    一条坏法跑多个用例文件时，**每个文件一个元素**，形如 `Suite:/abs/x.swift`。
    把两个文件用逗号塞进同一个元素，桩件会把后半截当成仓库根下的一个路径去找，
    报 FileNotFoundError、记账行打不出来，执行器只能记成 NO-SUMMARY —— 看着像
    「判据没咬住」，其实一条用例都没跑。issue #78 那趟的 R5/B3/B5/S3 就是这么废的。
    """
    with open(os.path.join(REPO, "tools", "xctstub", "suites.json"), encoding="utf-8") as handle:
        known = {item["name"] for item in json.load(handle)["suites"]}
    bad = []
    for case in cases:
        for spec in case["tests"]:
            suite, _, files = spec.partition(":")
            if "," in spec:
                bad.append("%s：%r 把两个文件塞进了一个元素，要拆成两条" % (case["id"], spec))
            elif suite not in known:
                bad.append("%s：%r 的套件名 %r 不在 suites.json 里" % (case["id"], spec, suite))
            elif not os.path.exists(os.path.join(REPO, files) if not files.startswith("/") else files):
                bad.append("%s：%r 的用例文件不存在" % (case["id"], spec))
    if bad:
        sys.exit("tests 形状不对，一条都没跑：\n  " + "\n  ".join(bad))


def main():
    parser = argparse.ArgumentParser(description="MacStroke 的反向变异执行器")
    parser.add_argument("table")
    parser.add_argument("--only", help="逗号分隔的编号，只跑这几条")
    parser.add_argument("--list", action="store_true", help="只列表，不动源码")
    args = parser.parse_args()

    with open(args.table, encoding="utf-8") as handle:
        cases = json.load(handle)["cases"]
    if args.only:
        wanted = {item.strip() for item in args.only.split(",")}
        cases = [case for case in cases if case["id"] in wanted]

    check_specs(cases)

    if args.list:
        for case in cases:
            print("%-4s %-8s %s" % (case["id"], "该抓" if case["expect"] else "免跑", case["bad"]))
        print("表共 %d 条" % len(cases))
        return

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = os.path.join(REPO, ".build", "mutation", stamp)
    os.makedirs(out_dir, exist_ok=True)
    progress_path = os.path.join(out_dir, "progress.log")

    # 起跑前的 SHA：这里必须是**任何一条坏法都没装进去之前**取的那一份。
    touched = sorted({case["file"] for case in cases})
    baseline = {item: sha(os.path.join(REPO, item)) for item in touched}
    progress = ["起跑 %s 表 %s 共 %d 条" % (stamp, os.path.basename(args.table), len(cases)),
                "起跑前锚点自检与 SHA：" + "; ".join("%s=%s" % (item, baseline[item]) for item in touched)]
    with open(progress_path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(progress) + "\n")

    rows = []
    for case in cases:
        log_path = os.path.join(out_dir, "%s.log" % case["id"])
        status, detail = run_case(case, log_path, progress)
        rows.append({"id": case["id"], "bad": case["bad"], "expect": case["expect"],
                     "status": status, "detail": detail})
        line = "%-4s %-9s %-8s %s" % (case["id"], status,
                                      "该抓" if case["expect"] else "免跑", case["bad"])
        with open(progress_path, "a", encoding="utf-8") as handle:
            handle.write("%s\n    %s\n" % (line, detail))
        print(line, flush=True)

    # 还原核对：逐条已在 finally 里还原，这里再对一次全量基线。
    dirty = [item for item in touched if sha(os.path.join(REPO, item)) != baseline[item]]
    ran = [row for row in rows if row["status"] not in ("SKIP",)]
    expected = [row for row in ran if row["expect"]]
    holes = [row["id"] for row in expected if row["status"] == "SURVIVED"]
    others = [row["id"] for row in ran if row["status"] in ("BUILD-RED", "TRAP", "NO-SUMMARY")]

    write(os.path.join(out_dir, "results.json"), json.dumps(
        {"stamp": stamp, "table": os.path.basename(args.table), "baseline": baseline,
         "rows": rows, "dirty": dirty}, ensure_ascii=False, indent=2))

    print()
    print("本趟跑了 %d 条（表共 %d 条），其中预期该抓到的 %d 条里漏 %d 条：%s"
          % (len(ran), len(cases), len(expected), len(holes), "、".join(holes) or "无"))
    print("编译红/TRAP/无记账：%s" % ("、".join(others) or "无"))
    print("跳过（锚点不唯一/未命中）：%s"
          % ("、".join(row["id"] for row in rows if row["status"] == "SKIP") or "无"))
    print("还原核对：%s" % ("全部文件 SHA 回到起跑前" if not dirty else "脏文件 " + "、".join(dirty)))
    with open(progress_path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(progress) + "\n")
    print("证据：%s" % out_dir)
    if dirty:
        sys.exit(2)


if __name__ == "__main__":
    main()
