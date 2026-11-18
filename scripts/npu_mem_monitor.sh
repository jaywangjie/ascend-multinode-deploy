#!/bin/bash
# 昇腾 NPU 显存(HBM) + 主机内存(RAM) 实时监控（多机训练必备：两次集群级崩溃的
# 根因都靠主机内存/HBM 曲线定位）。写到共享存储可在任一节点查看全部机器。
# 用法: ./npu_mem_monitor.sh [间隔秒,默认10] [日志文件]
# 推荐启动方式（断线不死，脱离终端）:
#   setsid nohup bash /mnt/sfs_turbo/npu_mem_monitor.sh 10 /mnt/sfs_turbo/monitor_$(hostname -s).log >/dev/null 2>&1 &
set -uo pipefail
INTERVAL="${1:-10}"
LOG="${2:-npu_mem_monitor_$(date +%Y%m%d_%H%M%S).log}"
HOST_WARN_GB="${HOST_WARN_GB:-100}"   # 主机可用内存低于此值(GB)告警

# 自动探测单卡 HBM 总量(MB)：npu-smi 输出里的 "已用/总量" 取最大分母；失败回退 98304(950DT)
HBM_TOTAL=$(npu-smi info 2>/dev/null | grep -oE "[0-9]+ */ *[0-9]+" | awk -F'/' '{gsub(/ /,"",$2); if($2>m) m=$2} END{print (m>0?m:98304)}')

log() { echo -e "$*" | tee -a "$LOG"; }
log "================ NPU 资源监控启动 ($(hostname -s)) ================"
log "间隔: ${INTERVAL}s | 日志: $LOG | 单卡HBM: ${HBM_TOTAL}MB | 告警: 主机可用<${HOST_WARN_GB}GB"
log "时间 | 卡数 | HBM已用(MB,各卡) | HBM% | 主机已用/总量(GB) | 可用(GB)"

while true; do
  TS=$(date '+%F %T')
  mapfile -t HBMS < <(npu-smi info 2>/dev/null | grep -oE "[0-9]+ */ *${HBM_TOTAL}" | awk -F'/' '{gsub(/ /,"",$1); print $1}')
  N=${#HBMS[@]}
  if [ "$N" -eq 0 ]; then
    log "[$TS] ERROR: npu-smi 无输出（驱动/权限异常?）"
    sleep "$INTERVAL"; continue
  fi
  HBM_SUM=0; LINE=""
  for v in "${HBMS[@]}"; do HBM_SUM=$((HBM_SUM+v)); LINE+="${v} "; done
  HBM_PCT=$(( HBM_SUM * 100 / (N * HBM_TOTAL) ))
  read -r MTOT MU MA _ < <(free -m | awk '/^Mem:/{print $2, $3, $7}')
  MTOT_G=$((MTOT/1024)); MU_G=$((MU/1024)); MA_G=$((MA/1024))
  WARN=""
  [ "$MA_G" -lt "$HOST_WARN_GB" ] && WARN=" <<< 主机内存告警!"
  [ "$HBM_PCT" -gt 95 ] && WARN="${WARN} <<< HBM>95%!"
  log "[$TS] | ${N}卡 | ${LINE% } | ${HBM_PCT}% | ${MU_G}/${MTOT_G}GB | 可用${MA_G}GB${WARN}"
  sleep "$INTERVAL"
done
