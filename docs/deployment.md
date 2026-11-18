# 昇腾 950DT/A5 多机训练部署手册（通用版）

适用：N 台 950DT/A5 机器 + Docker + 共享存储（SFS Turbo）+ MindSpeed-MM（FSDP）多机训练。
所有机器相关值（IP、镜像、路径）统一放在仓库根目录 `hosts.env`，脚本全部从它读取。

```
阶段0 接入 → 阶段1 存储 → 阶段2 权重/数据 → 阶段3 容器 → 阶段4 体检对比
→ 阶段5 冒烟 → 阶段6 多机配置与启动 → 阶段7 监控与收尾
```

## 阶段 0：接入层（一次性）

1. `cp hosts.env.example hosts.env`，填好机器清单（`node0` 必须是主节点）、镜像、挂载点。
2. `./scripts/setup_ssh.sh` —— 写 `~/.ssh/config`（跳板 ProxyJump + ControlMaster 长连接，
   对抗频繁断连），并用初始密码分发公钥（`INIT_PASSWORD`，用完即弃）。
3. 验证：逐台 `ssh nodeX hostname` 全部返回。

## 阶段 1：共享存储挂载（每台机器）

1. 华为云控制台 → SFS Turbo → 复制"挂载指令"，取其中的 NFS 导出地址填进
   `hosts.env` 的 `SFS_EXPORT`（形如 `xxxx.sfsturbo.internal:/`）。
2. `./scripts/mount_sfs.sh`（幂等；加 `--fstab` 写开机自动挂载）。

模型、数据集、DCP 权重、训练日志全部放共享存储——多机天然一致，免同步。

## 阶段 2：模型权重与数据集

**权重下载**（任一台）：

```bash
pip install modelscope
mkdir -p $SFS_MOUNT/models/<模型名>
nohup modelscope download --model <org>/<模型名> \
  --local_dir $SFS_MOUNT/models/<模型名>/ > down.log 2>&1 &
```

**HF → DCP 权重转换**（容器内执行，阶段 3 完成后再做）：

```bash
docker exec -it <容器> bash
cd $MM_DIR     # MindSpeed-MM 根目录
export HF_MODEL=$SFS_MOUNT/models/<模型名>/          # HF 权重
export DCP_OUTPUT=$SFS_MOUNT/models/<模型名>-mm-dcp/  # 转换输出
bash examples/<模型系列>/convert_hf2dcp.sh
```

注意：转换脚本若默认 `to_bf16=false` 会输出 fp32、体积翻倍，确认脚本里带
`--to_bf16 true`（历史坑）。

**数据集**：上传/解压到 `$SFS_MOUNT/<数据目录>/xxx.jsonl`。

## 阶段 3：镜像与容器（每台机器）

1. 私有镜像先登录（凭据手动执行，不入库）：
   `docker login <registry>` → `docker pull <IMAGE>`
2. `./scripts/run_container.sh --dry-run` 先审一遍生成的 docker run，确认后去掉
   `--dry-run` 正式创建（默认全部节点，`--host nodeX` 可单台）。

模板要点（950DT 多机实测版）：

- 设备：`davinci0..7` + `davinci_manager` + `hisi_hdc` + **`devmm_svm`（最易漏）**，
  云 RDMA 机型再加 `ummu`/`uburma`
- RDMA 用户态库：urma/libibverbs/libnl/hrn5 等按宿主机存在情况自动挂载
- **HCCL 组网三件套：`/etc/hccl_rootinfo.json`、`/etc/cloud/topo/950`、`/etc/hixlep`**
  —— 多机通信平面的依据，缺一不可
- 驱动/工具：`/usr/local/Ascend/driver`、`/usr/local/dcmi`、`npu-smi`
- `-e SOC_VERSION=ascend950`、`--privileged --network host --shm-size 1024g`

3. 容器内快速验证：`docker exec <容器> npu-smi info`（8 卡且无 `dcmi -8005`）。

## 阶段 4：体检与跨机一致性

```bash
./scripts/host_check.sh        # NPU/驱动/设备/容器/存储/时钟/残留进程
./scripts/cluster_diff.sh      # 驱动版本、hccl_rootinfo 关键字段、容器配置、CANN 版本
```

多机训练的隐性要求：各机**驱动/固件版本一致**、**hccl_rootinfo.json 指向同一通信平面**
（`net_instance_id`、`topo_file_path` 必须相同）、容器生效配置一致。任何 FAIL 先修复。

## 阶段 5：跨机通信冒烟（强烈建议，先 2 机后全量）

在两台机器的容器里各起一个 `smoke_allreduce.py`（int64 allreduce）：

```bash
# node0 容器内
source /usr/local/Ascend/cann/set_env.sh
MASTER_ADDR=<node0_ip> MASTER_PORT=29500 HCCL_CONNECT_TIMEOUT=120 \
torchrun --nproc_per_node 8 --nnodes 2 --node_rank 0 \
  --master_addr <node0_ip> --master_port 29500 <skill>/scripts/smoke_allreduce.py
# node1 容器内：同命令，--node_rank 1
```

全部 rank 打印 `SMOKE_ALLREDUCE_OK` 再进行下一步；卡在初始化 → 组网问题（回阶段 4）。

## 阶段 6：多机配置与启动

MindSpeed-MM 的 finetune 脚本读取以下变量（框架内建约定）：

```bash
MASTER_ADDR=<主节点IP>        # 各机相同
NNODES=<节点数>               # 各机相同
NODE_RANK=${VC_TASK_INDEX:-0} # 各机不同：主节点必须是 0，从节点 1,2,3…
```

两种落地方式（效果等价）：

- **A. 逐台改脚本**：vim 每台的 `examples/<系列>/finetune_*.sh`，按上表改
  MASTER_ADDR/NNODES/NODE_RANK（主节点编号必须为 0）。
- **B. 环境变量注入（推荐）**：脚本不动，`./scripts/launch_multinode.sh start`
  自动按 `NODES` 顺序注入 `VC_WORKER_HOSTS/VC_WORKER_NUM/VC_TASK_INDEX` 并启动。

启动前确认**各机的启动脚本与训练 yaml 完全一致**（放共享存储则天然一致）。
长序列参考调优（258k 实测）：

```yaml
parallel:
  fsdp_plan:
    num_to_forward_prefetch: 2
    num_to_backward_prefetch: 2
    ulysses_parallel_size: 8
model:
  skip_gdn_recompute: false
  skip_flash_attn_recompute: false
features:
  enable_activation_offload: false   # 长序列 + HBM 有富余时建议关闭（见 troubleshooting 案例4）
```

启动与观察：

```bash
./scripts/launch_multinode.sh start     # 主节点先起；或各机手动同时 bash run_xxx.sh
./scripts/launch_multinode.sh status    # 进程数 + 最新日志
./scripts/launch_multinode.sh log 50    # 各机日志尾部
```

日志出现 `iteration x/N | ... loss: ...` 且 `world size = N×8` 即启动成功。
loss 曲线可视化可用 [plot-loss-curve](https://github.com/jaywangjie/plot-loss-curve) skill。

## 阶段 7：监控与收尾

每台宿主机挂上监控（写共享存储，任一节点可看全部机器）：

```bash
./scripts/npu_mem_monitor.sh 10 $SFS_MOUNT/monitor_$(hostname -s).log   # 前台试跑
# 确认输出正常后，断线不死方式：
setsid nohup bash <skill>/scripts/npu_mem_monitor.sh 10 \
  $SFS_MOUNT/monitor_$(hostname -s).log >/dev/null 2>&1 &
```

训练结束：`./scripts/launch_multinode.sh stop`（trainer 可能挂在 HCCL 清理不退出，
需 pkill）；短跑注意框架按里程碑步数自动存 DCP（每个可达 102G），及时清理多余
iter 目录并恢复 `latest_checkpointed_iteration.txt`。

## 收敛判据（4.05 万条数据 / 300 step / 258k 序列实测参考）

- 训练 loss 稳定下降并趋稳（MBS=1, GAS=16, GBS=64, bf16）
- 950DT tokens/sec/chip ~1665、~55 TFLOPS、~63 s/step（与 H100 同口径对比）
- 各卡 HBM 占用均衡（±2GB 内），主机可用内存曲线平稳不持续下滑
