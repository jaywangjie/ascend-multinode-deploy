# ascend-multinode-deploy

一个 [Claude Code](https://claude.com/claude-code) skill：**昇腾 950DT/A5 多机训练集群**的部署、启动、监控与崩溃取证。

沉淀自 2/4 机 MindSpeed-MM 分布式训练的真实实践——包括踩过的全套坑（容器 NPU 不可见、HCCL 跨机平面不一致、显存/主机内存 OOM 引发的集群团灭、checkpoint 写挂……见 `docs/troubleshooting.md`）。

## 结构

```
├── SKILL.md                     # Claude 触发与操作路由
├── hosts.env.example            # 集群清单模板（IP/镜像/路径，复制为 hosts.env 填写）
├── scripts/
│   ├── setup_ssh.sh             # 跳板 ProxyJump + ControlMaster + 公钥分发
│   ├── mount_sfs.sh             # SFS Turbo NFS 挂载（幂等，--fstab 持久化）
│   ├── host_check.sh(+_body.sh) # 全节点体检：NPU/驱动/设备/容器/存储/时钟/残留进程
│   ├── cluster_diff.sh          # 跨机一致性：驱动/hccl_rootinfo 关键字段/容器配置/CANN
│   ├── run_container.sh         # 标准容器模板：设备+RDMA 库+HCCL 三件套，按存在性自动裁剪
│   ├── smoke_allreduce.py       # 跨机 HCCL 冒烟（int64 allreduce）
│   ├── launch_multinode.sh      # start/status/log/stop 编排（VC_* 环境变量注入）
│   ├── npu_mem_monitor.sh       # HBM+主机内存实时监控（setsid nohup 断线不死）
│   └── find_first_dead_rank.sh  # 崩溃取证：找第一个异常退出的 rank + plog/dmesg 时间窗
└── docs/
    ├── deployment.md            # 阶段化部署手册（存储→权重→容器→体检→冒烟→启动→监控）
    └── troubleshooting.md       # 8 个真实故障案例的 症状→定位→根因→处置
```

## 安装（Claude Code）

```bash
git clone git@github.com:jaywangjie/ascend-multinode-deploy.git ~/.claude/skills/ascend-multinode-deploy
cd ~/.claude/skills/ascend-multinode-deploy && cp hosts.env.example hosts.env  # 填写你的集群
```

之后在 Claude Code 里说"部署 4 机昇腾训练集群 / 排查多机训练崩溃"即可触发。

## 快速开始（脱离 Claude 手动用）

```bash
cp hosts.env.example hosts.env && vim hosts.env   # 填机器/镜像/路径
./scripts/setup_ssh.sh                            # 打通免密
./scripts/mount_sfs.sh                            # 共享存储
./scripts/run_container.sh --dry-run              # 审容器命令 → 正式创建
./scripts/host_check.sh && ./scripts/cluster_diff.sh
# 冒烟 → 启动 → 监控
./scripts/launch_multinode.sh start
```

## License

MIT
