#!/bin/bash
# 崩溃取证：集群训练挂掉后，在全部节点上并行收集证据，找"第一个异常退出的 rank"。
# 原则（真实案例反复验证）：超时后各机的 aclnn/aicpu 报错都是尸体检伤口；元凶是
# 最早 exitcode!=0 的那个 rank 所在机器。rank R 所在节点 = NODES[R / NPUS_PER_NODE]。
# 用法:
#   ./find_first_dead_rank.sh "2026-11-01 23:00" "2026-11-01 01:00"   # 起止时间窗
#   输出目录默认 ./forensics_<时间>/
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

[ $# -eq 2 ] || { echo "用法: $0 \"开始时间\" \"结束时间\"（如 \"2026-11-01 23:00\" \"2026-11-01 23:59\"）" >&2; exit 1; }
T0="$1"; T1="$2"
OUT="forensics_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

echo "== 取证窗口: $T0 ~ $T1，输出: $OUT =="

for n in "${NODES[@]}"; do
  name="${n%%:*}"
  echo "-- 采集 $name"
  sshn "$name" "
    echo '#### 容器内最新训练日志中的关键错误 ####'
    LATEST=\$(docker exec $CONTAINER_NAME bash -c 'ls -t $MM_DIR/logs/*.log 2>/dev/null | head -1')
    echo \"日志: \$LATEST\"
    [ -n \"\$LATEST\" ] && docker exec $CONTAINER_NAME grep -anE 'exitcode|OutOfMemoryError|EL0018|EL0019|Communication_Error|RuntimeError|Root Cause' \"\$LATEST\" | head -10
    echo '#### 第一个 exitcode（torchrun 视角的根因 rank）####'
    [ -n \"\$LATEST\" ] && docker exec $CONTAINER_NAME grep -anm3 'exitcode' \"\$LATEST\"
    echo '#### plog 心跳/异常记录 ####'
    find /root/ascend /home/*/ascend -name 'plog*' -newermt \"$T0\" ! -newermt \"$T1\" 2>/dev/null | head -5 | while read -r p; do
      grep -aE 'Heartbeat Lost|Cluster Exception Location|Possible Reason|Discoverer' \"\$p\" | head -8
    done
    echo '#### dmesg 时间窗内错误 ####'
    dmesg -T 2>/dev/null | awk -v t0=\"$T0\" -v t1=\"$T1\" '\$0>=t0 && \$0<=t1' | grep -iE 'error|oom|link|roce' | head -8
  " >"$OUT/$name.txt" 2>&1 || echo "  $name 采集失败（ssh 不通?）" >>"$OUT/$name.txt"
done

echo
echo "== rank → 节点映射（rank R → NODES[R/$NPUS_PER_NODE]）=="
i=0
for n in "${NODES[@]}"; do
  name="${n%%:*}"; ip="${n##*:}"
  echo "  rank $((i*NPUS_PER_NODE))~$(( (i+1)*NPUS_PER_NODE-1 )) → $name ($ip) [NODE_RANK=$i]"
  i=$((i+1))
done
echo
echo "各节点证据已存 $OUT/。判读顺序:"
echo "  1) 比较各文件'第一个 exitcode'的时间戳 —— 最早者即根因节点"
echo "  2) 该节点日志里 exitcode 前的最后异常（EL0019=显存OOM / EL0018=主机内存 / RuntimeError=代码）"
echo "  3) plog 'Heartbeat Lost + Cluster Exception Location' 锁定整机掉线与发现者"
echo "  4) 时间账: 崩溃时刻 - 静默开始时刻 ≈ HCCL_EXEC_TIMEOUT(默认3600s) 则确证'等待掉队者超时'"
echo "详见 docs/troubleshooting.md"
