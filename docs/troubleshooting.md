# 故障速查表（全部来自 950DT 2/4 机训练的真实案例）

> 判读总原则：**超时后满屏的 aclnn/aicpu/DataLoader 报错都是尸体检伤口，不是死因。**
> 元凶 = 第一个 `exitcode != 0` 的 rank 所在机器。`rank R → NODES[R/8]`。
> 用 `./scripts/find_first_dead_rank.sh "起" "止"` 自动收集。

## 案例 1：容器内 `npu-smi` 报 `dcmi module initialize failed. ret is -8005`

- **根因**：容器 runtime 是 runc（`docker inspect <容器> --format '{{.HostConfig.Runtime}}'`），
  NPU 设备根本没注入容器。
- **处置**（二选一）：
  1. 宿主机安装 Ascend-Docker-Runtime：官网 `.run` 包（`--install`）或从已装机器
     `/usr/local/Ascend/Ascend-Docker-Runtime` 整目录 scp（同架构同驱动版本可直接拷）；
     `/etc/docker/daemon.json` 注册（**注意与已有内容合并，勿整文件覆盖**）+
     `systemctl daemon-reload && systemctl restart docker`；
     起容器加 `--runtime=ascend -e ASCEND_VISIBLE_DEVICES=0-7`。
  2. 手动设备映射路线（本 skill 的 run_container.sh 默认）：10 个 `--device` 全量映射。
- **易漏点**：`/dev/devmm_svm`（NPU 内存管理设备，没有它 torch_npu 无法分配显存）；
  `ls /dev/davinci*` 通配不到 `hisi_hdc`/`devmm_svm`，要单独确认。

## 案例 2：双机建环时 `OpParamMaker.cpp:453 std::bad_alloc`

- **表象**：数据预处理阶段的 `dist.barrier()`（第一次跨机 allreduce）炸 bad_alloc。
- **三个独立根因**（按概率排查）：
  1. **残留进程占 HBM**：上次失败训练没清干净 → 两机 `pgrep -af trainer.py`，
     `pkill -9 -f trainer.py`。
  2. **初始化顺序**：trainer 先上模型+优化器（每卡 ~88G），barrier 时 HCCL 通信
     buffer 无显存可分 → 把 `get_dataloader()` 挪到 `get_model()/get_optimizer()`
     之前，让第一次跨机建环发生在空卡上（实测根治）。
  3. **两机不在同一通信平面**：`/etc/hccl_rootinfo.json` 的 `net_instance_id`
     一边命名式一边 UUID、`topo_file_path` 指向不同拓扑文件 → 跨机平面无法互认，
     以 bad_alloc 形式炸出。该文件是平台生成的，**不要手改**，找平台/厂商统一
     （`./scripts/cluster_diff.sh` 一键核对）。
- **排除法**：单机 8 卡正常 + 双机一上就崩 → 优先怀疑 3；先跑
  `cluster_diff.sh` 再看 1。

## 案例 3：跑一段时间后 `Communication_Error_Timeout(EI0002): waiting peer rank N`

- **表象**：日志静默 30~60 分钟后报超时，随后满屏 `aclnnMatmul/RmsNorm` 报错、
  DataLoader 被 kill、全体退出。
- **判读**：`waiting peer rank N` → 掉队者是 `NODES[N/8]` 那台机器，不是报错的
  这台。时间账：崩溃时刻 − 静默开始时刻 ≈ `HCCL_EXEC_TIMEOUT`（默认 3600s）即确证。
- **定位**：`find_first_dead_rank.sh` 收集四台证据：
  - 该机训练日志最早的 `exitcode 1` 前的异常（EL0019/EL0018/RuntimeError）
  - 宿主机 plog（`/root/ascend` 或 `~/ascend/log/plog/`）里
    `Heartbeat Lost` + `Cluster Exception Location: <机器>/rank 0~7`（整机掉线铁证）
  - `dmesg -T` 时间窗内 hisdk5/链路错误
- **常见根因转案例 4/5**；网络面嫌疑时查 `dmesg -T | grep -iE "link|roce"`、
  `last reboot`。低成本对照实验：踢掉嫌疑机跑 N−1 机，稳定则锁定该机。

## 案例 4：整机掉线，根因 EL0018 主机内存耗尽

- **表象**：plog 里 `halMemAlloc`/钉锁内存申请 1GB 失败（EL0018）→ 进程死 →
  心跳丢；监控曲线上主机可用内存持续下滑直到崩。
- **根因**：`enable_activation_offload: true` 把激活搬到主机内存，长序列下钉锁
  内存持续累积，1.5T 内存也扛不住。
- **处置**：若 HBM 占用有富余（如 62%），**关闭 activation offload** 让激活留在卡上
  —— 实测既放得下又直接消灭该死因。20 步 A/B 验证：显存不 OOM + 主机内存曲线
  变平即根治。

## 案例 5：单节点多 rank 同时 `EL0019` 显存 OOM

- **表象**：`Resource_Error_Insufficient_Device_Memory(EL0019): Failed to allocate
  ~5.1GB`，挂在 FSDP backward 的 `wait_for_unshard()`（参数 all_gather 拷出），
  同机 4 个 rank 报同样大小失败 → rank 退出 → 转 案例3 剧本团灭。
- **处置**：降 MBS / 开 recompute / 缩 SEQ_LEN；参考 yaml（258k + MBS=1 实测稳）：
  `skip_gdn_recompute: false`、`skip_flash_attn_recompute: false`、
  `enable_activation_offload: false`、`num_to_*_prefetch: 2`。

## 案例 6：正好在第 N 步集体静默（N 为 checkpoint 里程碑步数）

- **嫌疑**：N 机同时写超大 checkpoint（DCP fp32 主权重每个可达 ~100G）到共享存储，
  IO 停滞/死锁。时间点与里程碑步数（如 64/100/200…）吻合度是关键证据。
- **处置**：查 `$SFS_MOUNT/.../train_saved/iter_*` 是否残缺；save_interval 避开短跑
  里程碑；短跑结束恢复 `latest_checkpointed_iteration.txt` 并删多余 iter。

## 案例 7：训练结束进程不退出

- trainer 跑完后挂在 HCCL 清理阶段 → `./scripts/launch_multinode.sh stop`
  （本质 `pkill -9 -f 'trainer.py|torchrun'`）。

## 案例 8：两机配置对比方法（排障前置技能）

- 容器生效配置：`docker inspect` 归一化（剔除 Id/Created/日志路径/HOSTNAME 环境变量
  等必然不同的字段）后 md5 对比 —— `cluster_diff.sh` 已内置。
- `/etc/hixlep` 是运行时临时目录，空的/有瞬态文件都正常，别被它带偏；
  真正要一致的是 `/etc/hccl_rootinfo.json` 与 `/etc/cloud/topo/950`。

## 案例 9：跨机通信初始化卡住（hcclCommInit 不返回/超时）

- **表象**：torchrun/allreduce 冒烟卡在 init_process_group 或 hcclCommInit，最后超时。
- **常见根因**：
  1. **多网卡选错**：机器有管理网/存储网/RDMA 网多块网卡，HCCL 选了不通的网卡 →
     `hosts.env` 填 `HCCL_IFNAME=<RDMA网卡名>`（launch 自动注入
     `HCCL_SOCKET_IFNAME`）；单机冒烟时也可临时
     `export HCCL_SOCKET_IFNAME=xxx` 验证。
  2. 通信平面不一致（转案例 2 的根因 3，先跑 cluster_diff.sh）。
  3. 端口未放通：MASTER_PORT（默认 6000）跨机需可达，换端口或放通安全组。
- **定位顺序**：先单机 8 卡 allreduce（排除设备问题）→ 两机 allreduce（卡 init =
  组网问题）→ cluster_diff.sh 对平面。

## 其他已知坑（单机时代遗留，多机同样适用）

- `examples/*/install_depends.sh` 可能是别的模型线脚本：切框架 commit、连环降级
  torch —— 环境固定的容器里**禁跑**。
- hf2dcp 转换默认可能输出 fp32（体积翻倍），确认带 `--to_bf16 true`。
- 时钟：HCCL 对时钟偏差敏感，`host_check.sh` 的 chrony 项 PASS 再起训练。
- 断连频繁的操作环境：`setup_ssh.sh` 的 ControlMaster 长连接 + 无人值守驱动模式
  （本地写好脚本 → scp 上去 → nohup 执行 → 回拉日志）。
