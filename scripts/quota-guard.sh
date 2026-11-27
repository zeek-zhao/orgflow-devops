#!/usr/bin/env bash
# quota-guard.sh —— 构建容器「四项资源铁律」守卫（M2.5 P0，m2.5.1 生命周期加固）
#
# 每次启动/使用构建容器前，采集四项实际值并断言（缺一项即 BLOCKED，绝不 fallback 成 PASS）：
#   1) docker info 的 NCPU == nproc                        （精确相等，不是"接近"）
#   2) docker info 的 MemTotal == /proc/meminfo MemTotal(kB)×1024（≤1% 偏差，偏差值必打印）
#   3) docker inspect 目标容器 NanoCpus=0                   （精确 0）
#   4) docker inspect 目标容器 Memory=0                     （精确 0）
#   5) docker inspect 目标容器 CpuQuota=0                   （精确 0）
#   6) 四项记录落盘：latest-<container>.json（门禁消费）+ latest.json（人类查看副本）+ <UTC>-<container>.json
#
# 新鲜度（≤10 分钟）属消费端职责：build-from-gerrit / verify-quota-guard 读证据时判 age；
# 本脚本只写 ts，不自判新鲜度（m2.5.1 P1-2：删除半成品 --max-age-min）。
#
# P2-1 两段式（up.sh 调用）：
#   --preflight          启动容器【前】只采集宿主三项（nproc/MemTotal/docker info），校验 docker 未被
#                        限权（判据 1/2）；不 inspect 容器、不写最终证据；落 host-preflight.json 供比对。
#   --compare-preflight  启动容器【后】完整采集四项，并与前置 host-preflight.json 比对宿主三项；
#                        启动前后宿主值不一致即 BLOCKED（reason 写明）。
#
# 纪律：不读 .env 里任何配额变量；只记录实际值并断言。任何一项缺失/命令失败/容器不存在/
#       数值不匹配 → verdict=BLOCKED；不得写 PASS、不得写 "full-quota PASS"、
#       不得继续 buildctl build、不得回写 Verified。
#
# 用法:
#   bash scripts/quota-guard.sh --container of-builder --out artifacts/quota
#   bash scripts/quota-guard.sh --container of-builder --out artifacts/quota --preflight
#   bash scripts/quota-guard.sh --container of-builder --out artifacts/quota --compare-preflight artifacts/quota/host-preflight.json
# 退出码: 0=PASS  2=BLOCKED(缺项/不匹配)  3=环境不可用(docker 不可达/容器不存在/参数错)
set -uo pipefail

# docker 在本沙箱位于 /usr/local/bin，确保 PATH 可解析（调用方 PATH 可能不完整）
command -v docker >/dev/null 2>&1 || export PATH="/usr/local/bin:/usr/bin:$PATH"

CONTAINER=""; OUT=""; PREFLIGHT=0; CMP_PRE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container)          CONTAINER="${2:-}"; shift 2 ;;
    --out)                OUT="${2:-}"; shift 2 ;;
    --preflight)          PREFLIGHT=1; shift ;;
    --compare-preflight)  CMP_PRE="${2:-}"; shift 2 ;;
    -h|--help)            sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "[quota] ✗ 未知参数: $1" >&2; exit 3 ;;
  esac
done
if [[ -z "$CONTAINER" || -z "$OUT" ]]; then
  echo "[quota] ✗ 必须提供 --container 与 --out" >&2
  exit 3
fi
if [[ $PREFLIGHT -eq 1 && -n "$CMP_PRE" ]]; then
  echo "[quota] ✗ --preflight 与 --compare-preflight 不可同时使用" >&2
  exit 3
fi

TS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
reason=""; env_fail=0

# ---------- 采集宿主三项原始输出（命令失败记 reason，绝不 fallback）----------
nproc_raw=""; nrc=0
nproc_raw="$(nproc 2>&1)" || nrc=$?
mem_line=""; mrc=0
mem_line="$(grep -E '^MemTotal:' /proc/meminfo 2>&1)" || mrc=$?
dinfo=""; drc=0
dinfo="$(docker info --format 'NCPU={{.NCPU}} MemTotal={{.MemTotal}}' 2>&1)" || drc=$?

# ---------- 采集容器 inspect（仅完整模式；preflight 不 inspect）----------
iline=""; irc=0
if [[ $PREFLIGHT -eq 0 ]]; then
  iline="$(docker inspect "$CONTAINER" --format 'NanoCpus={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} CpuQuota={{.HostConfig.CpuQuota}}' 2>&1)" || irc=$?
fi

[[ $nrc -eq 0 ]] || reason="${reason}nproc命令失败;"
[[ $mrc -eq 0 ]] || reason="${reason}MemTotal读取失败;"
[[ $drc -eq 0 ]] || reason="${reason}docker不可达;"
[[ $PREFLIGHT -eq 0 && $irc -ne 0 ]] && reason="${reason}容器不存在或inspect失败;"

# ---------- 解析数值 ----------
mem_kb="$(printf '%s' "$mem_line" | grep -oE '[0-9]+' | head -1 || true)"
dcpu="$(printf '%s' "$dinfo" | sed -n 's/.*NCPU=\([0-9][0-9]*\).*/\1/p')"
dmem="$(printf '%s' "$dinfo" | sed -n 's/.*MemTotal=\([0-9][0-9]*\).*/\1/p')"
nano=""; mlim=""; quota=""
if [[ $PREFLIGHT -eq 0 ]]; then
  nano="$(printf '%s' "$iline" | sed -n 's/.*NanoCpus=\([0-9][0-9]*\).*/\1/p')"
  mlim="$(printf '%s' "$iline" | sed -n 's/.*Memory=\([0-9][0-9]*\).*/\1/p')"
  quota="$(printf '%s' "$iline" | sed -n 's/.*CpuQuota=\([0-9][0-9]*\).*/\1/p')"
fi

need_host=0
[[ -z "$nproc_raw" || -z "$mem_kb" || -z "$dcpu" || -z "$dmem" ]] && need_host=1
if [[ $PREFLIGHT -eq 0 && ( -z "$nano" || -z "$mlim" || -z "$quota" ) ]]; then need_host=1; fi
if [[ $need_host -eq 1 ]]; then
  env_fail=1
  reason="${reason}数值解析缺失(原始: nproc=${nproc_raw:-MISSING} mem=${mem_kb:-MISSING} dinfo=${dinfo:-MISSING} inspect=${iline:-MISSING});"
fi

# ---------- 固定格式逐行打印到 stdout（便于 CI 日志 grep）----------
echo "[quota] nproc=${nproc_raw:-MISSING}"
echo "[quota] MemTotal=${mem_kb:-MISSING} kB"
echo "[quota] docker info NCPU=${dcpu:-MISSING} MemTotal=${dmem:-MISSING}"
if [[ $PREFLIGHT -eq 0 ]]; then
  echo "[quota] inspect NanoCpus=${nano:-MISSING} Memory=${mlim:-MISSING} CpuQuota=${quota:-MISSING}"
fi

# ---------- 判据 ----------
ncpu_match="false"; mem_delta_pct="-1"; mem_ok="false"
nano_zero="false"; memory_zero="false"; cpu_quota_zero="false"
pre_cmp_ok="true"
if [[ $env_fail -eq 0 ]]; then
  [[ "$dcpu" == "$nproc_raw" ]] && ncpu_match="true" || reason="${reason}NCPU≠nproc(${dcpu}≠${nproc_raw});"
  host_bytes=$(( mem_kb * 1024 ))
  mem_delta_pct="$(awk -v a="$dmem" -v b="$host_bytes" 'BEGIN{ if(b==0){print 100;exit} d=a-b; if(d<0)d=-d; printf "%.4f", d/b*100 }')"
  if awk -v p="$mem_delta_pct" 'BEGIN{exit !(p<=1.0)}'; then mem_ok="true"; else reason="${reason}MemTotal偏差>1%(实际${mem_delta_pct}%);"; fi
  if [[ $PREFLIGHT -eq 0 ]]; then
    [[ "$nano"  == "0" ]] && nano_zero="true"  || reason="${reason}NanoCpus≠0(${nano});"
    [[ "$mlim"  == "0" ]] && memory_zero="true" || reason="${reason}Memory≠0(${mlim});"
    [[ "$quota" == "0" ]] && cpu_quota_zero="true" || reason="${reason}CpuQuota≠0(${quota});"
  fi
fi

# ---------- 与启动前宿主快照比对（P2-1）----------
if [[ -n "$CMP_PRE" && $env_fail -eq 0 ]]; then
  if [[ ! -f "$CMP_PRE" ]]; then
    env_fail=1; reason="${reason}preflight快照缺失(${CMP_PRE});"
  else
    # 容忍冒号后空格（JSON 可能由 python json.dumps 生成，带空格）
    p_nproc="$(sed -n 's/.*"nproc"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CMP_PRE" | head -1)"
    p_memkb="$(sed -n 's/.*"mem_total_kb"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CMP_PRE" | head -1)"
    p_dcpu="$(sed -n 's/.*"ncpu"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CMP_PRE" | head -1)"
    p_dmem="$(sed -n 's/.*"mem_total_bytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CMP_PRE" | head -1)"
    if [[ -z "$p_nproc" || -z "$p_memkb" || -z "$p_dcpu" || -z "$p_dmem" ]]; then
      env_fail=1; reason="${reason}preflight快照字段缺失;"
    else
      [[ "$p_nproc" == "$nproc_raw" ]] || { pre_cmp_ok="false"; reason="${reason}启动前后nproc变化(${p_nproc}→${nproc_raw});"; }
      [[ "$p_memkb" == "$mem_kb" ]] || { pre_cmp_ok="false"; reason="${reason}启动前后MemTotal变化(${p_memkb}→${mem_kb});"; }
      [[ "$p_dcpu" == "$dcpu" ]] || { pre_cmp_ok="false"; reason="${reason}启动前后dockerNCPU变化(${p_dcpu}→${dcpu});"; }
      [[ "$p_dmem" == "$dmem" ]] || { pre_cmp_ok="false"; reason="${reason}启动前后dockerMemTotal变化(${p_dmem}→${dmem});"; }
    fi
  fi
fi

# ---------- 总判 ----------
if [[ $env_fail -ne 0 ]]; then
  verdict="BLOCKED"; ec=3
elif [[ "$ncpu_match" == "true" && "$mem_ok" == "true" && "$pre_cmp_ok" == "true" ]] \
     && { [[ $PREFLIGHT -eq 1 ]] || [[ "$nano_zero" == "true" && "$memory_zero" == "true" && "$cpu_quota_zero" == "true" ]]; }; then
  verdict="PASS"; ec=0
else
  verdict="BLOCKED"; ec=2
fi

echo "[quota] verdict=$verdict reason=${reason:-none}"

# ---------- 落盘证据（含 ts 供消费端判新鲜度）----------
mkdir -p "$OUT"
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g' | tr '\n' ' '; }
REASON_ESC="$(json_esc "$reason")"
tb() { [[ "$1" == "true" ]] && echo true || echo false; }

if [[ $PREFLIGHT -eq 1 ]]; then
  # 宿主预检快照：只含宿主三项，供启动后比对；不写 latest（它不是完整证据）
  pre_json="{"
  pre_json+="\"ts\":\"$TS\",\"host\":{\"nproc\":${nproc_raw:-0},\"mem_total_kb\":${mem_kb:-0}},"
  pre_json+="\"docker\":{\"ncpu\":${dcpu:-0},\"mem_total_bytes\":${dmem:-0}},"
  pre_json+="\"verdict\":\"$verdict\",\"reason\":\"$REASON_ESC\"}"
  echo "$pre_json" > "$OUT/host-preflight.json"
  echo "[quota] 宿主预检快照已落盘: $OUT/host-preflight.json（verdict=$verdict）"
  exit "$ec"
fi

json="{"
json+="\"ts\":\"$TS\",\"container\":\"$CONTAINER\","
json+="\"host\":{\"nproc\":${nproc_raw:-0},\"mem_total_kb\":${mem_kb:-0}},"
json+="\"docker\":{\"ncpu\":${dcpu:-0},\"mem_total_bytes\":${dmem:-0}},"
json+="\"inspect\":{\"nano_cpus\":${nano:-0},\"memory\":${mlim:-0},\"cpu_quota\":${quota:-0}},"
json+="\"checks\":{\"ncpu_match\":$(tb "$ncpu_match")"
json+=",\"mem_delta_pct\":$mem_delta_pct,\"mem_ok\":$(tb "$mem_ok")"
json+=",\"nano_cpus_zero\":$(tb "$nano_zero")"
json+=",\"memory_zero\":$(tb "$memory_zero")"
json+=",\"cpu_quota_zero\":$(tb "$cpu_quota_zero")"
json+=",\"preflight_match\":$(tb "$pre_cmp_ok")}"
json+=",\"verdict\":\"$verdict\",\"reason\":\"$REASON_ESC\""
# m2.5.3 P2-2：总体 result 字段（PASS/FAIL/WARN），与 verdict 同一口径，供机器消费者读取。
case "$verdict" in
  PASS)    result="PASS" ;;
  BLOCKED) result="FAIL" ;;
  *)       result="WARN" ;;
esac
json+=",\"result\":\"$result\"}"
# 门禁固定读 latest-<container>.json；latest.json 仅为人类查看副本，不参与门禁。
echo "$json" > "$OUT/latest-${CONTAINER}.json"
echo "$json" > "$OUT/latest.json"
echo "$json" > "$OUT/${TS}-${CONTAINER}.json"
echo "[quota] 证据已落盘: $OUT/latest-${CONTAINER}.json + latest.json + ${TS}-${CONTAINER}.json"

exit "$ec"
