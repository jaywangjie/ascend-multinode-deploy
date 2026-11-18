#!/bin/bash
# 跨机一致性对比：驱动版本、HCCL 组网描述(hccl_rootinfo.json 关键字段)、云拓扑文件、
# 容器生效配置（docker inspect 归一化）、容器内 CANN 版本。多机训练要求这些全部一致。
# 历史教训：两机 net_instance_id 不同（命名式 vs UUID、指向不同拓扑文件）→ 跨机建环
# 直接 std::bad_alloc（见 docs/troubleshooting.md 案例2）。
# 用法: ./cluster_diff.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 归一化容器 inspect：剔除每机必然不同的字段后取 md5
NORM_PY='
import json,sys
try:
    d=json.load(sys.stdin)[0]
except Exception:
    sys.exit(1)
for k in ["Id","Created","LogPath","HostnamePath","HostsPath","ResolvConfPath",
          "GraphDriver","NetworkSettings","Name","Driver","Image"]:
    d.pop(k,None)
cfg=d.get("Config",{})
cfg["Env"]=sorted(e for e in (cfg.get("Env") or []) if not e.startswith("HOSTNAME="))
d["Config"]=cfg
d["HostConfig"].pop("ContainerIDFile",None)
print(json.dumps(d,sort_keys=True))
'

collect() { # collect <别名>
  local h="$1"
  sshn "$h" "
    echo DRV=\$(cat /usr/local/Ascend/driver/version.info 2>/dev/null | head -1)
    echo ROOTINFO_MD5=\$(md5sum /etc/hccl_rootinfo.json 2>/dev/null | cut -d\" \" -f1)
    echo NET_INSTANCE_ID=\$(python3 -c \"import json;print(json.load(open('/etc/hccl_rootinfo.json')).get('net_instance_id',''))\" 2>/dev/null)
    echo TOPO_FILE_PATH=\$(python3 -c \"import json;print(json.load(open('/etc/hccl_rootinfo.json')).get('topo_file_path',''))\" 2>/dev/null)
    echo TOPO950_MD5=\$(find /etc/cloud/topo/950 -type f -exec cat {} \; 2>/dev/null | md5sum | cut -d\" \" -f1)
    docker inspect ${CONTAINER_NAME} 2>/dev/null | python3 -c '${NORM_PY}' | md5sum | cut -d' ' -f1 | sed 's/^/CONTAINER_NORM=/'
    echo CANN=\$(docker exec ${CONTAINER_NAME} cat /usr/local/Ascend/cann/version.info 2>/dev/null | head -1)
  " 2>/dev/null
}

for n in "${NODES[@]}"; do
  name="${n%%:*}"
  collect "$name" >"$WORK/$name.txt" || echo "警告: $name 采集失败（ssh 不通?）" >&2
done

echo "字段对比（多机训练要求各列一致）:"
FIRST="${NODES[0]%%:*}"
for field in DRV ROOTINFO_MD5 NET_INSTANCE_ID TOPO_FILE_PATH TOPO950_MD5 CONTAINER_NORM CANN; do
  LINE="$field"
  for n in "${NODES[@]}"; do
    name="${n%%:*}"
    v=$(grep -E "^$field=" "$WORK/$name.txt" | head -1 | cut -d= -f2- | cut -c1-24)
    LINE="$LINE | $name=${v:--}"
  done
  echo "$LINE"
done

echo "----"
echo "重点核对: NET_INSTANCE_ID / TOPO_FILE_PATH 必须完全相同（同一通信平面）"
BAD=0
for field in DRV ROOTINFO_MD5 NET_INSTANCE_ID CONTAINER_NORM; do
  N=$(for n in "${NODES[@]}"; do grep -E "^$field=" "$WORK/${n%%:*}.txt" | head -1; done | sort -u | wc -l)
  if [ "$N" -gt 1 ]; then echo "不一致: $field"; BAD=1; fi
done
[ "$BAD" -eq 0 ] && echo "关键项全部一致" || echo "存在不一致项 —— 修复后再启动（hccl_rootinfo.json 是平台生成的，勿手改，找平台/厂商统一）"
exit $BAD
