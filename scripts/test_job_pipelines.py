#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""#91 / REQ-M0-B2：Job 定义流水线化静态自检。

判据（任一不满足即非 0 退出）：
  1. 每个 job / job-template 必须是 project-type: pipeline
  2. dsl 必须是 declarative pipeline（含 `pipeline {`）
  3. 每个 job 的 stage 数 >= 2（不许把整段逻辑留在一个 node 块里）
  4. 同一个 job 内 stage 名不得重复
  5. 每个 stage 体不得为空（去掉花括号与空白后仍有内容）

反证用法：
  - 把两个 stage 改成同名        -> 第 4 条红
  - 把某个 stage 体清空           -> 第 5 条红
  - 把 stage 全删掉               -> 第 3 条红

注意：本脚本只做静态检查。`make jobs` 真实推送与 Jenkins 构建页的 stage
列表属于运行时验收，不在本脚本范围内（见 #104）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JOBDIR = os.path.join(ROOT, 'config', 'job_definitions')

STAGE_RE = re.compile(r"stage\s*\(\s*'([^']*)'\s*\)\s*\{")


def undouble(text):
    """JJB 用 Python 风格模板，Groovy 里的 { } 在 yaml 里写成 {{ }}。"""
    return text.replace('{{', '{').replace('}}', '}')


def load_jobs():
    """返回 [(文件相对路径, job 名, project-type, dsl)]。"""
    out = []
    for dirpath, _dirnames, filenames in os.walk(JOBDIR):
        for fn in sorted(filenames):
            if not fn.endswith(('.yaml', '.yml')):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, ROOT)
            text = io.open(path, encoding='utf-8').read()
            try:
                import yaml
                docs = list(yaml.safe_load_all(text))
            except Exception:
                docs = None
            if docs is None:
                out.append((rel, None, None, None, 'YAML 解析失败'))
                continue
            for doc in docs:
                if not isinstance(doc, list):
                    continue
                for item in doc:
                    if not isinstance(item, dict):
                        continue
                    for kind in ('job', 'job-template'):
                        if kind not in item:
                            continue
                        spec = item[kind]
                        specs = spec if isinstance(spec, list) else [spec]
                        for s in specs:
                            if not isinstance(s, dict):
                                continue
                            out.append((rel, s.get('name'), s.get('project-type'),
                                        s.get('dsl'), None))
    return out


def stage_bodies(dsl):
    """返回 [(stage 名, 体内容)]，用花括号配对切分。"""
    res = []
    for m in STAGE_RE.finditer(dsl):
        name = m.group(1)
        i = m.end() - 1  # 指向 '{'
        depth = 0
        start = i + 1
        j = i
        while j < len(dsl):
            ch = dsl[j]
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if depth != 0:
            res.append((name, None))  # 花括号不配对
            continue
        res.append((name, dsl[start:j]))
    return res


def main():
    jobs = load_jobs()
    if not jobs:
        print('✗ 没找到任何 job 定义，判据本身失效')
        return 1

    fails = []
    print('%-46s %-8s %s' % ('job', 'stages', 'stage 名'))
    print('-' * 100)
    for rel, name, ptype, dsl, err in jobs:
        if err:
            fails.append('%s: %s' % (rel, err))
            print('%-46s %-8s %s' % (rel, 'ERR', err))
            continue
        label = '%s (%s)' % (name, rel)
        if ptype != 'pipeline':
            fails.append('%s: project-type=%r，必须是 pipeline' % (label, ptype))
        if not dsl:
            fails.append('%s: 缺少 dsl' % label)
            print('%-46s %-8s %s' % (name, 'ERR', '缺少 dsl'))
            continue

        body = undouble(dsl)
        if 'pipeline {' not in body:
            fails.append('%s: dsl 不是 declarative pipeline（找不到 `pipeline {`）' % label)

        # 花括号配对
        if body.count('{') != body.count('}'):
            fails.append('%s: dsl 花括号不配对（{=%d, }=%d）'
                         % (label, body.count('{'), body.count('}')))

        st = stage_bodies(body)
        names = [n for n, _ in st]
        print('%-46s %-8d %s' % (name, len(st), ', '.join(names) if names else '(无)'))

        if len(st) < 2:
            fails.append('%s: stage 数 %d < 2' % (label, len(st)))

        dup = sorted(set(n for n in names if names.count(n) > 1))
        if dup:
            fails.append('%s: stage 名重复 -> %s' % (label, ', '.join(dup)))

        for n, b in st:
            if b is None:
                fails.append('%s: stage %r 的花括号不配对' % (label, n))
                continue
            # 去掉花括号与空白后必须还有内容，防止 `stage('x') { }` 这种空壳
            residue = re.sub(r'[\s{}]', '', b)
            if not residue:
                fails.append('%s: stage %r 是空 stage（体内容去掉花括号与空白后为空）' % (label, n))

    print('-' * 100)
    print('检查 %d 个 job / job-template' % len(jobs))
    if fails:
        print('✗ 流水线化自检失败 %d 项：' % len(fails))
        for f in fails:
            print('  - ' + f)
        return 1
    print('✓ 流水线化自检通过：全部是 declarative pipeline，每个 job >= 2 个非空且不重名的 stage')
    return 0


if __name__ == '__main__':
    sys.exit(main())
