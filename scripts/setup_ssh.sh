#!/bin/bash
# 接入层初始化：写 ~/.ssh/config（跳板 + 每台机器别名 + ControlMaster 长连接），
# 首次用密码分发公钥，之后全程免密。对抗弱网断连的关键是 ControlPersist。
# 用法: ./setup_ssh.sh          （需先填好 hosts.env）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$HERE/common.sh"
require_config

SSH_CONFIG="$HOME/.ssh/config"
BEGIN_MARK="# >>> ascend-multinode-deploy >>>"
END_MARK="# <<< ascend-multinode-deploy <<<"

# 1) 幂等：去掉旧块，重新生成后【插到文件头部】
#    ssh 配置是"首个匹配生效"——若用户已有同名 Host 条目，追加到末尾会被遮蔽，
#    因此必须前置，并在下方检测冲突时告警
touch "$SSH_CONFIG"
sed -i "/^$BEGIN_MARK$/,/^$END_MARK$/d" "$SSH_CONFIG"

BLOCK_FILE=$(mktemp)
{
  echo "$BEGIN_MARK"
  if [ -n "$JUMP_HOST" ] && [ -n "$JUMP_IP" ]; then
    cat <<EOF
Host $JUMP_HOST
  HostName $JUMP_IP
  User $JUMP_USER
  ServerAliveInterval 30
  ServerAliveCountMax 10
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  fi
  for n in "${NODES[@]}"; do
    name="${n%%:*}"; ip="${n##*:}"
    cat <<EOF

Host $name
  HostName $ip
  User $NODE_USER
EOF
    [ -n "${JUMP_HOST:-}" ] && echo "  ProxyJump $JUMP_HOST"
    cat <<'EOF'
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist yes
  ServerAliveInterval 30
  ServerAliveCountMax 10
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  done
  echo "$END_MARK"
} > "$BLOCK_FILE"

# 同名 Host 冲突检测（我们前置生效，但要提醒用户旧条目已失效）
for n in "${NODES[@]}"; do
  name="${n%%:*}"
  if grep -qE "^Host .*\b$name\b" "$SSH_CONFIG" 2>/dev/null; then
    echo "注意: ~/.ssh/config 中已存在 Host $name 的旧条目，本 skill 的配置将优先生效" >&2
  fi
done

cat "$BLOCK_FILE" "$SSH_CONFIG" > "${SSH_CONFIG}.new" && mv "${SSH_CONFIG}.new" "$SSH_CONFIG"
rm -f "$BLOCK_FILE"
echo "[1/3] ssh config 已写入并置于文件头部（节点别名: ${NODES[*]%%:*}）"

# 2) 本机密钥
if [ ! -f "$HOME/.ssh/id_ed25519.pub" ]; then
  ssh-keygen -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" -q
  echo "[2/3] 已生成新密钥 id_ed25519"
else
  echo "[2/3] 复用现有密钥 id_ed25519"
fi

# 3) 免密测试；不通且给了初始密码则用 sshpass 分发公钥（带重试，弱网友好）
PUB="$(cat "$HOME/.ssh/id_ed25519.pub")"
command -v sshpass >/dev/null || NEED_SSHPASS=1
for n in "${NODES[@]}"; do
  name="${n%%:*}"
  if sshn "$name" 'echo ok' >/dev/null 2>&1; then
    echo "  $name: 已免密"; continue
  fi
  if [ -z "${INIT_PASSWORD:-}" ]; then
    echo "  $name: 免密失败且未设 INIT_PASSWORD —— 请手动打通或填 INIT_PASSWORD 后重跑" >&2; FAILED=1; continue
  fi
  if [ "${NEED_SSHPASS:-0}" = 1 ]; then
    echo "  $name: 需要 sshpass（apt/yum install sshpass）后重跑" >&2; FAILED=1; continue
  fi
  ok=""
  for i in 1 2 3 4; do
    if timeout 30 sshpass -p "$INIT_PASSWORD" ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$name" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$PUB' ~/.ssh/authorized_keys 2>/dev/null || echo '$PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys" \
      && sshn "$name" 'echo ok' >/dev/null 2>&1; then
      ok=1; echo "  $name: 公钥已分发（尝试 $i 次）"; break
    fi
    sleep 8
  done
  [ -z "$ok" ] && { echo "  $name: 分发失败" >&2; FAILED=1; }
done

echo "[3/3] 连通性汇总:"
for n in "${NODES[@]}"; do
  name="${n%%:*}"
  if timeout 25 sshn "$name" 'echo "$(hostname)"' 2>/dev/null; then :; else echo "  $name: 不通"; FAILED=1; fi
done
exit "${FAILED:-0}"
