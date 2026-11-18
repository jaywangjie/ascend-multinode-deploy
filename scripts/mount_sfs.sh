#!/bin/bash
# 共享存储（SFS Turbo / NFS）挂载：在每台机器上创建挂载点并挂载，幂等。
# 挂载命令以华为云控制台"挂载指令"为准；hosts.env 里填 SFS_EXPORT 即可。
# 用法: ./mount_sfs.sh [--fstab]    # --fstab 追加开机自动挂载
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

FSTAB=0
[ "${1:-}" = "--fstab" ] && FSTAB=1
[ -n "$SFS_EXPORT" ] || { echo "错误: hosts.env 未填 SFS_EXPORT（华为云控制台可复制）" >&2; exit 1; }

OPTS="vers=3,timeo=600,noresvport,nolock,tcp,lookupcache=pos"
FAILED=0
for n in "${NODES[@]}"; do
  name="${n%%:*}"
  echo "== $name =="
  sshn "$name" "sudo mkdir -p '$SFS_MOUNT' && \
    if mountpoint -q '$SFS_MOUNT'; then echo '  已挂载:' && df -h '$SFS_MOUNT' | tail -1; \
    else mount -t nfs -o $OPTS '$SFS_EXPORT' '$SFS_MOUNT' && echo '  挂载成功:' && df -h '$SFS_MOUNT' | tail -1; fi" \
    || { echo "  $name 挂载失败" >&2; FAILED=1; }
  if [ "$FSTAB" = 1 ]; then
    sshn "$name" "grep -qF '$SFS_EXPORT' /etc/fstab || echo '$SFS_EXPORT $SFS_MOUNT nfs $OPTS 0 0' >> /etc/fstab" \
      && echo "  fstab 已确保"
  fi
done
exit $FAILED
