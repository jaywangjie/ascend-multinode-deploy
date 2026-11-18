#!/bin/bash
# 训练容器创建（950DT/A5 多机标准模板）：设备注入 + RDMA 栈挂载 + HCCL 组网三件套。
# 在每台节点上执行；只挂载宿主机上真实存在的设备/库，缺失核心件直接报错。
# 用法:
#   ./run_container.sh [--dry-run] [--host node1] [--force]
#     --dry-run  只打印 docker run 命令不执行
#     --host     只在指定节点创建（默认全部节点）
#     --force    先删同名旧容器
# 说明: 该模板走"手动设备映射"路线（--privileged + 逐个 --device），不依赖
#       ascend-docker-runtime 插件；若宿主机已注册 ascend runtime 也可改用
#       --runtime=ascend -e ASCEND_VISIBLE_DEVICES=0-7 并删去 --device 行，二选一。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

DRY=0; FORCE=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --host)    ONLY="$2"; shift ;;
    *) echo "未知参数 $1" >&2; exit 1 ;;
  esac
  shift
done

# 生成在目标机上执行的脚本（按实际存在的设备/库裁剪 docker run）
gen_remote() {
  cat <<'REMOTE'
gen_devices() {
  echo "--device /dev/davinci_manager --device /dev/hisi_hdc --device=/dev/devmm_svm"
  i=0
  while [ -e "/dev/davinci$i" ]; do echo "--device /dev/davinci$i:/dev/davinci$i"; i=$((i+1)); done
  if [ "$i" -eq 0 ]; then echo "ERROR: 无 /dev/davinci* 设备" >&2; exit 1; fi
  for d in /dev/ummu /dev/uburma; do [ -e "$d" ] && echo "--device $d:$d"; done
}
gen_vol() {
  # PLATFORM=a5-cloud: 云上 950DT —— 含 urma RDMA 栈与 HCCL 云组网三件套
  # PLATFORM=bare:     物理机/非云（950/910B 通用）—— 只挂通用 RDMA 库，跳过云组网
  RDMA_LIBS="/usr/lib64/libnl-3.so.200 /usr/lib64/libnl-3.so.200.26.0 \
             /usr/lib64/libnl-genl-3.so.200 /usr/lib64/libnl-genl-3.so.200.26.0 \
             /usr/lib64/libibverbs.so.1.14.50.0 /usr/lib64/libibverbs.so.1 \
             /usr/lib64/libibverbs /etc/libibverbs.d"
  if [ "$PLATFORM" = "a5-cloud" ]; then
    RDMA_LIBS="$RDMA_LIBS /usr/lib64/urma /usr/lib64/liburma.so.0.0.3 /usr/lib64/liburma.so.0 \
               /usr/lib64/liburma_common.so.0.0.1 /usr/lib64/liburma_common.so.0 \
               /usr/lib64/libummu.so.1.0.1 /usr/lib64/libummu.so.1 /usr/lib64/libummu.so \
               /usr/lib64/libhrn5-rdmav34.so /usr/lib64/libibv_extend.so.4.2.0 \
               /usr/bin/urma_admin /var/log/hinic"
  fi
  for f in $RDMA_LIBS; do [ -e "$f" ] && echo "-v $f:$f"; done
  # 核心：驱动/工具/共享存储
  echo "-v /usr/local/dcmi:/usr/local/dcmi"
  echo "-v /usr/local/Ascend/driver:/usr/local/Ascend/driver"
  echo "-v /usr/local/sbin/npu-smi:/usr/local/bin/npu-smi"
  if [ "$PLATFORM" = "a5-cloud" ]; then
    # HCCL 云组网三件套（多机通信平面依据；物理机无此文件）
    echo "-v /etc/hccl_rootinfo.json:/etc/hccl_rootinfo.json"
    echo "-v /etc/cloud/topo/950:/etc/cloud/topo/950"
    echo "-v /etc/hixlep:/etc/hixlep"
  fi
  echo "-v /usr/share/zoneinfo/Asia/Shanghai:/etc/localtime"
  echo "-v $SFS_MOUNT:$SFS_MOUNT"
}
CMD="docker run -itd --privileged=true -u root --network host --shm-size 1024g \
  -e SOC_VERSION=$SOC_VERSION --name $CONTAINER_NAME $IMAGE /bin/bash \
  $(gen_devices) $(gen_vol) $EXTRA_MOUNTS $EXTRA_DEVICES"

if [ "$DRY" = 1 ]; then
  echo "$CMD"
  exit 0
fi
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  if [ "$FORCE" = 1 ]; then docker rm -f "$CONTAINER_NAME"; else echo "容器已存在，跳过（--force 重建）"; exit 0; fi
fi
eval "$CMD"
sleep 2
echo "--- 验证 ---"
if docker exec "$CONTAINER_NAME" npu-smi info 2>&1 | grep -m1 -qE "950|910|NPU"; then
  echo "容器内 NPU 可见 OK"
else
  echo "验证失败: npu-smi 无输出/报 dcmi -8005（见 docs/troubleshooting.md 案例1）"
fi
REMOTE
}

FAILED=0
for n in "${NODES[@]}"; do
  name="${n%%:*}"
  [ -n "$ONLY" ] && [ "$name" != "$ONLY" ] && continue
  echo "== $name $([ "$DRY" = 1 ] && echo '(dry-run)') =="
  sshn "$name" "CONTAINER_NAME='$CONTAINER_NAME' FORCE='$FORCE' DRY='$DRY' PLATFORM='$PLATFORM' SFS_MOUNT='$SFS_MOUNT' SOC_VERSION='$SOC_VERSION' IMAGE='$IMAGE' EXTRA_MOUNTS='$EXTRA_MOUNTS' EXTRA_DEVICES='$EXTRA_DEVICES' bash -s" <<<"$(gen_remote)" \
    || { echo "$name 创建失败" >&2; FAILED=1; }
done
exit $FAILED
