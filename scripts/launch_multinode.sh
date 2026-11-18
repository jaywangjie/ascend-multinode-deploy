#!/bin/bash
# 多机训练编排：start / status / stop / log
#   start   逐台在容器内以 VC_* 环境变量启动训练脚本（MindSpeed-MM 惯例：
#           脚本内 NNODES=${VC_WORKER_NUM:-1} NODE_RANK=${VC_TASK_INDEX:-0}
#           MASTER_ADDR 取 VC_WORKER_HOSTS 首个 IP）。主节点先起，其余跟进。
#   status  各节点训练进程 + 最新日志尾部
#   stop    各节点清理 trainer/torchrun（trainer 结束后挂在 HCCL 清理不退是已知问题）
#   log     拉取各节点最新训练日志尾部
# 环境变量: DRY_RUN=1 只打印命令不执行
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

N=$(node_count)
IPS=$(node_ips_csv)
CMD="${1:-}"; [ $# -gt 0 ] && shift

do_ssh_exec() { # do_ssh_exec <别名> <容器内命令>
  local name="$1" inner="$2"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "[dry-run] $name: docker exec -d $CONTAINER_NAME bash -lc $inner"
    return 0
  fi
  sshn "$name" "docker exec -d $CONTAINER_NAME bash -lc '$inner'"
}

case "$CMD" in
start)
  [ -n "${EXTRA_ENV:-}" ] && EXTRA_EXPORT="export $EXTRA_ENV && " || EXTRA_EXPORT=""
  i=0
  for n in "${NODES[@]}"; do
    name="${n%%:*}"
    inner="cd $MM_DIR && ${EXTRA_EXPORT}export VC_WORKER_HOSTS=\"$IPS\" VC_WORKER_NUM=$N VC_TASK_INDEX=$i MASTER_PORT=$MASTER_PORT && bash $RUN_SCRIPT >> /tmp/launch_${name}.log 2>&1"
    echo "启动 $name (NODE_RANK=$i)..."
    do_ssh_exec "$name" "$inner" || echo "  $name 启动命令下发失败" >&2
    [ "$i" = 0 ] && echo "  主节点已先起，等 15s 再起从节点" && sleep 15
    i=$((i+1))
  done
  echo "全部节点已下发。验证: ./launch_multinode.sh status"
  echo "若 3 分钟内日志无 'iteration' 行，看 docs/troubleshooting.md 案例2/3"
  ;;
status)
  for n in "${NODES[@]}"; do
    name="${n%%:*}"
    echo "== $name =="
    sshn "$name" "docker exec $CONTAINER_NAME bash -c 'pgrep -fc trainer.py; ls -t $MM_DIR/logs/*.log 2>/dev/null | head -1'" 2>/dev/null \
      || echo "  不可达/容器未运行"
  done
  ;;
log)
  TAIL="${1:-20}"
  for n in "${NODES[@]}"; do
    name="${n%%:*}"
    echo "== $name =="
    sshn "$name" "docker exec $CONTAINER_NAME bash -c 'ls -t $MM_DIR/logs/*.log 2>/dev/null | head -1 | xargs -r tail -$TAIL'" 2>/dev/null
  done
  ;;
stop)
  for n in "${NODES[@]}"; do
    name="${n%%:*}"
    echo "停止 $name..."
    do_ssh_exec "$name" "pkill -9 -f 'trainer.py|torchrun' 2>/dev/null; true"
  done
  ;;
*)
  echo "用法: $0 {start|status|log [N]|stop}"
  echo "  DRY_RUN=1 $0 start   # 只看将执行的命令"
  exit 1
  ;;
esac
