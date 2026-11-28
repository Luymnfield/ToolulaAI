# Leonix 启动 ComfyUI 用的包装 (用法和 ComfyUI/main.py 一样, 工作目录是 ComfyUI 的安装目录)。
#
# Apple GPU (MPS) 上 PyTorch 的 conv3d 很慢: 实测只有约 2.3 TFLOPS, 同样的计算拆成几次 conv2d 有 10~12 TFLOPS。
# 视频 VAE (Wan 2.2 等) 主要由 conv3d 组成, 所以这里在启动前把 conv3d 换成 "沿时间维拆成 conv2d 再相加",
# 数学上完全等价。M3 Max 上 Wan 2.2 5 秒视频的解码从约 412 秒降到约 108 秒。
# 只改这个进程里的函数, 不动 ComfyUI 的安装。设置环境变量 TOOLULA_NO_CONV3D_PATCH=1 可关闭。
import os
import runpy
import sys

import torch
import torch.nn.functional as F

_orig_conv3d = F.conv3d


def _triple(v):
    return tuple(v) if isinstance(v, (tuple, list)) else (v, v, v)


def conv3d(x, w, b=None, stride=1, padding=0, dilation=1, groups=1):
    if x.device.type != "mps" or isinstance(padding, str) or x.dim() != 5 or w.dim() != 5:
        return _orig_conv3d(x, w, b, stride, padding, dilation, groups)
    st, pd, dl = _triple(stride), _triple(padding), _triple(dilation)
    if pd[0]:
        x = F.pad(x, (0, 0, 0, 0, pd[0], pd[0]))
    B, C, T, H, W = x.shape
    kt = w.shape[2]
    To = (T - dl[0] * (kt - 1) - 1) // st[0] + 1
    if To <= 0:
        return _orig_conv3d(x, w, b, (st[0], st[1], st[2]), (0, pd[1], pd[2]), dl, groups)
    # 注意: MPS 的 conv2d 遇到不连续的输入或权重会算出错误结果, 所以两者都先整理成连续内存
    xs = x.transpose(1, 2).contiguous()
    out = None
    for k in range(kt):
        s0 = k * dl[0]
        xi = xs[:, s0: s0 + st[0] * (To - 1) + 1: st[0]].reshape(B * To, C, H, W)
        y = F.conv2d(xi, w[:, :, k].contiguous(), None, st[1:], pd[1:], dl[1:], groups)
        out = y if out is None else out + y
    if b is not None:
        out = out + b.view(1, -1, 1, 1)
    return out.view(B, To, *out.shape[1:]).transpose(1, 2)


if not os.environ.get("TOOLULA_NO_CONV3D_PATCH") and torch.backends.mps.is_available():
    F.conv3d = conv3d
    torch.conv3d = conv3d
    print("[Leonix] MPS conv3d -> conv2d patch enabled", flush=True)

comfy_dir = os.path.join(os.getcwd(), "ComfyUI")
sys.path.insert(0, comfy_dir)
sys.argv = [os.path.join(comfy_dir, "main.py")] + sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
