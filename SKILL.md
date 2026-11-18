---
name: ascend-multinode-deploy
description: Deploy and operate multi-node Ascend NPU (950DT/A5) training clusters — SSH/jump-host access, SFS Turbo storage mount, MindSpeed-MM containers with NPU+RDMA+HCCL device mounts, cross-node consistency checks, multi-node torchrun launch, memory monitoring, and crash forensics. Use when asked about 昇腾多机/双机/4机部署、集群搭建、多机训练启动、跨机 HCCL 报错排查、训练崩溃分析、NPU 容器创建、SFS 挂载、hf2dcp 权重转换, or deploying MindSpeed-MM training on multiple 950DT/A5 machines.
---

# Ascend 多机训练集群部署与运维

适用 N 台昇腾 NPU 机器 + Docker + 共享存储，默认面向 950DT/A5 云上环境。
所有环境值集中在 `hosts.env`（从 `hosts.env.example` 复制），脚本从它读取。

**跨环境适配开关**（都在 hosts.env）：

- `PLATFORM=a5-cloud|bare` —— a5-cloud 挂 HCCL 云组网三件套 + urma RDMA 栈
  （默认）；bare 用于物理机/非云（950/910B），只挂通用 RDMA 库、跳过云组网，
  `SOC_VERSION` 相应改。
- `LAUNCH_MODE=vc|plain` —— vc 注入 MindSpeed-MM 的 VC_WORKER_* 变量（默认）；
  plain 直接注入 MASTER_ADDR/NNODES/NODE_RANK，适配任意 torchrun 系框架
  （Megatron/DeepSpeed 等）。
- `HCCL_IFNAME` —— 多网卡机器指定 HCCL 通信网卡。
- `LOG_DIR` —— 非 MindSpeed-MM 框架的自定义日志目录。

完整流程见 `docs/deployment.md`；崩了先读 `docs/troubleshooting.md`。

## 快速路由

| 用户意图 | 动作 |
|---|---|
| 从零部署一套多机集群 | 按 `docs/deployment.md` 阶段 0→7 顺序执行 |
| 机器连不上/要打通免密 | `scripts/setup_ssh.sh`（跳板+ControlMaster+公钥分发） |
| 挂共享存储 | `scripts/mount_sfs.sh`（hosts.env 填 SFS_EXPORT） |
| 建训练容器 | `scripts/run_container.sh --dry-run` 审 → 去掉 dry-run |
| 启动前检查 | `scripts/host_check.sh` → `scripts/cluster_diff.sh`，FAIL 全清零 |
| 验证跨机通信 | 两台容器里 torchrun 跑 `scripts/smoke_allreduce.py` |
| 启动/停止/看日志 | `scripts/launch_multinode.sh {start|status|log|stop}` |
| 训练挂了 | `scripts/find_first_dead_rank.sh "起" "止"` + troubleshooting.md |
| 监控显存/内存 | 宿主机 setsid nohup 跑 `scripts/npu_mem_monitor.sh` |

## 关键约束（部署时的硬规则）

1. **node0 必须是主节点**：`NODE_RANK=0`；`MASTER_ADDR`/`NNODES` 各机相同。
2. **容器必须挂 HCCL 组网三件套**：`/etc/hccl_rootinfo.json`、`/etc/cloud/topo/950`、
   `/etc/hixlep`；设备映射最易漏 `/dev/devmm_svm`。
3. **各机必须一致**：驱动版本、`hccl_rootinfo.json` 的 `net_instance_id`/`topo_file_path`
   （同一通信平面）、容器生效配置、启动脚本与训练 yaml（放共享存储天然一致）。
4. 启动顺序：主节点先起（torchrun rendezvous 会等齐，"各机同时"亦可，主先更稳）。
5. 权重转换（hf2dcp）必须在容器内执行，且确认 `--to_bf16 true`。

## 崩溃排障的总原则（反复验证）

超时后满屏 aclnn/aicpu 报错都是**尸体检伤口**；元凶是**第一个 exitcode≠0 的
rank 所在机器**（rank R → NODES[R/NPUS_PER_NODE]）。判读顺序：

1. 比各机日志第一个 `exitcode` 时间戳，最早者即根因节点；
2. 该机 exitcode 前的最后异常：EL0019=显存 OOM、EL0018=主机内存（activation
   offload）、RuntimeError=代码/算子；
3. plog `Heartbeat Lost` 锁定整机掉线；崩溃时刻−静默时刻≈HCCL_EXEC_TIMEOUT(3600s)
   即"等掉队者超时"实锤；
4. 修完用 N−1 机对照实验验证锁定是否正确。

真实案例库（dcmi -8005 / bad_alloc / EI0002 / EL0018 / EL0019 / checkpoint 写挂 /
进程不退）见 `docs/troubleshooting.md`，按症状索引。

## 配套

- loss 曲线绘制：[plot-loss-curve](https://github.com/jaywangjie/plot-loss-curve)
- 凭据永不入库：`hosts.env` 已 gitignore；docker login、密码一律手动/内存传递。
