#!/usr/bin/env python3
"""runtime.env 的值怎么写才不会被 compose 解析坏。

单独成模块的唯一理由：渲染脚本（10-render-config.sh 里的内联 python）与门禁
（test_config.py）必须用**同一份**规则 —— 两边各写一遍就会出现「门禁绿了、
渲染还是坏的」这种假绿。
"""
from __future__ import annotations

import sys


def quote(value: str) -> str:
    """按 compose 的 dotenv 规则给值加引号。

    这里踩过一个很贵的坑：compose 的 env 解析器把「不带引号但含逗号的值」
    当错误，而且**只有当文件里出现第二个 key 时才报错** —— 报错之后它把
    **整份载荷**丢掉（不是丢那一行）。表现为容器里 LDAP_BASE_DN 与
    LDAP_ADMIN_DN 一起变空串，ldap healthcheck 用空 DN bind，永远 err 49。
    所以：含逗号/空格/$/"#' 的值一律加双引号，引号内的 \\ 与 " 要转义。
    """
    if value == "" or all(ch.isalnum() or ch in "_./:@-+=" for ch in value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    if any(ch in escaped for ch in "\n\r"):
        raise SystemExit("✗ 值含换行，compose 的 env 文件不支持多行值")
    return f'"{escaped}"'
