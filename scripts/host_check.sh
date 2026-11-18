#!/bin/bash
# 集群体检入口：把 host_check_body.sh 管道到每台节点执行，汇总 FAIL 数。
# 用法:
#   ./host_check.sh              # 全部节点
#   ./host_check.sh node1        # 指定节点（ssh 别名）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

BODY="$HERE/host_check_body.sh"
TOTAL_FAIL=0
TARGETS=()
if [ $# -ge 1 ]; then TARGETS=("$@"); else for n in "${NODES[@]}"; do TARGETS+=("${n%%:*}"); done; fi
for t in "${TARGETS[@]}"; do
  echo "===== $t ====="
  OUT=$(sshn "$t" "CONTAINER_NAME='${CONTAINER_NAME}' SFS_MOUNT='${SFS_MOUNT}' NPUS_PER_NODE='${NPUS_PER_NODE}' bash -s" <"$BODY" 2>&1) \
    || { echo "$OUT"; echo "  [FAIL] ssh 不通或执行异常"; TOTAL_FAIL=$((TOTAL_FAIL+1)); continue; }
  echo "$OUT"
  F=$(echo "$OUT" | grep -oE "FAILS=[0-9]+" | tail -1 | cut -d= -f2)
  TOTAL_FAIL=$((TOTAL_FAIL + ${F:-0}))
done
echo "----"
if [ "$TOTAL_FAIL" -eq 0 ]; then echo "全部通过"; else echo "共 $TOTAL_FAIL 项 FAIL —— 处置后再启动训练（见 docs/troubleshooting.md）"; fi
exit "$TOTAL_FAIL"
