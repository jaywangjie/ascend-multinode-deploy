#!/bin/bash
# 公共函数库：加载集群配置、SSH 封装。由其他脚本 source，不直接执行。
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$ROOT_DIR/hosts.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/hosts.env"
fi

require_config() {
  [ -n "${NODES:-}" ] || {
    echo "错误: 未找到集群配置。执行: cp hosts.env.example hosts.env 并填写后重试" >&2
    exit 1
  }
}

node_count() { echo "${#NODES[@]}"; }
node_name()  { echo "${NODES[$1]%%:*}"; }
node_ip()    { echo "${NODES[$1]##*:}"; }

node_ips_csv() {  # 逗号分隔的全部节点 IP —— torchrun VC_WORKER_HOSTS 用
  local ips=()
  for n in "${NODES[@]}"; do ips+=("${n##*:}"); done
  local IFS=,; echo "${ips[*]}"
}

# sshn <别名> <命令...>   —— 依赖 setup_ssh.sh 生成的 ~/.ssh/config 别名
sshn() {
  local h="$1"; shift
  ssh -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15 "$h" "$@"
}
