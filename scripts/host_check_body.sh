#!/bin/bash
# 体检主体：在目标节点上执行（由 host_check.sh 通过 ssh 管道传入）。
# 依赖环境变量: CONTAINER_NAME SFS_MOUNT NPUS_PER_NODE
FAILS=0
say() { printf "  [%s] %-24s %s\n" "$1" "$2" "$3"; }
fail() { say FAIL "$1" "$2"; FAILS=$((FAILS+1)); }

echo "-- NPU --"
NSMI="$(npu-smi info 2>/dev/null)"
if [ -n "$NSMI" ]; then
  N=$(echo "$NSMI" | grep -oE "^[|] *[0-9]+ " | wc -l)
  BADH=$(echo "$NSMI" | grep -cE "Fault|Ceased" || true)
  if [ "$N" -eq "$NPUS_PER_NODE" ] && [ "$BADH" -eq 0 ]; then
    say PASS "NPU 数量/健康" "$N 卡, 异常 $BADH"
  else
    fail "NPU 数量/健康" "期望 $NPUS_PER_NODE 卡实际 $N 卡, 异常 $BADH"
  fi
else
  fail "npu-smi" "无输出（驱动/权限异常）"
fi
DRV=$(cat /usr/local/Ascend/driver/version.info 2>/dev/null | head -1)
say INFO "驱动版本" "${DRV:-未找到 version.info}"

MISS=""
for d in /dev/davinci_manager /dev/hisi_hdc /dev/devmm_svm; do [ -e "$d" ] || MISS="$MISS $d"; done
[ -z "$MISS" ] && say PASS "核心设备节点" "manager/hisi_hdc/devmm_svm 齐全" \
  || fail "核心设备节点" "缺失:$MISS"

echo "-- Docker/容器 --"
if docker info 2>/dev/null | grep -A3 "Runtimes:" | grep -q ascend; then
  say PASS "ascend runtime" "已注册"
else
  say WARN "ascend runtime" "未注册 —— 容器须走手动 --device 映射路线"
fi
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  say PASS "容器存在" "$(docker ps -a --filter "name=^$CONTAINER_NAME$" --format '{{.Status}}' | head -1)"
  CN=$(docker exec "$CONTAINER_NAME" npu-smi info 2>&1 | head -3)
  if echo "$CN" | grep -qiE "dcmi.*failed|-8005"; then
    fail "容器内 NPU 可见" "dcmi -8005 —— 容器未注入 NPU（runtime/设备映射问题，见 docs/troubleshooting.md 案例1）"
  else
    say PASS "容器内 NPU 可见" "npu-smi 正常"
  fi
else
  say WARN "容器存在" "无 $CONTAINER_NAME —— 先跑 run_container.sh"
fi

echo "-- 存储/系统 --"
if mountpoint -q "$SFS_MOUNT"; then
  say PASS "共享存储" "$(df -h "$SFS_MOUNT" | tail -1 | awk '{print $3"/"$2" used"}')"
else
  fail "共享存储" "$SFS_MOUNT 未挂载 —— 跑 mount_sfs.sh"
fi
if command -v chronyc >/dev/null && chronyc tracking 2>/dev/null | grep -q "Leap status     : Normal"; then
  say PASS "时钟同步" "chrony 正常"
elif command -v timedatectl >/dev/null && [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
  say PASS "时钟同步" "systemd-timesyncd 正常"
else
  say WARN "时钟同步" "chrony/timesyncd 均未确认 —— HCCL 对时钟偏差敏感"
fi
if pgrep -f "trainer.py|torchrun" >/dev/null; then
  say WARN "残留训练进程" "$(pgrep -af 'trainer.py|torchrun' | head -1)"
else
  say PASS "无残留训练进程" "ok"
fi
DMERR=$(dmesg -T 2>/dev/null | grep -ciE "hisdk5.*error|link.*(down|error)" || true)
if [ "${DMERR:-0}" -gt 20 ]; then
  say WARN "dmesg 近期异常" "$DMERR 条驱动/链路错误 —— 空载跑 dmesg -Tw 观测 5 分钟"
else
  say PASS "dmesg 近期异常" "${DMERR:-0} 条"
fi
echo "FAILS=$FAILS"
