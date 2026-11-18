#!/usr/bin/env python3
"""跨机 HCCL 通信冒烟测试：int64 allreduce（真实会话中用它定位过 INT64 规约问题）。

在任意两台（或全部）节点上以 torchrun 各起一份：

  # node0（主）：
  docker exec -it <容器> bash -c '
    source /usr/local/Ascend/cann/set_env.sh && cd /path/to/skill/scripts
    MASTER_ADDR=<node0_ip> MASTER_PORT=29500 HCCL_CONNECT_TIMEOUT=120 \
    torchrun --nproc_per_node <卡数> --nnodes 2 --node_rank 0 \
             --master_addr <node0_ip> --master_port 29500 smoke_allreduce.py'
  # node1：同命令，--node_rank 1

全部 rank 打印 SMOKE_ALLREDUCE_OK 即跨机通信平面正常。
卡在 init_process_group / hcclCommInit → 组网或拓扑问题（先跑 cluster_diff.sh）。
"""
import os

import torch
import torch.distributed as dist

try:
    import torch_npu  # noqa: F401  必须先 import 以注册 npu 后端
except ImportError as e:
    raise SystemExit(f"torch_npu 不可用（容器未注入 NPU? 见 troubleshooting 案例1）: {e}")

dist.init_process_group(backend="hccl")
r, ws = dist.get_rank(), dist.get_world_size()

x = torch.ones(4096, dtype=torch.int64, device="npu")
dist.all_reduce(x)
expect = 4096 * ws
if x[0].item() == expect:
    print(f"SMOKE_ALLREDUCE_OK rank={r}/{ws} int64_sum={x[0].item()}")
else:
    print(f"SMOKE_ALLREDUCE_BAD rank={r} got={x[0].item()} expect={expect}")
    dist.destroy_process_group()
    raise SystemExit(1)

dist.barrier()
dist.destroy_process_group()
