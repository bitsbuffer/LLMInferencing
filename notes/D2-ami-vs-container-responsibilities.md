# D2 — AMI vs container responsibilities (the two-layer GPU contract)

> Tracker: D2 · Status: covered (D2) · Date: 2026-10-03
> Scope: what the host (AMI) owns vs what the container ships, how driver libs get injected, and
> the compatibility rules that decide whether your pod starts. Feeds article 05; explains most
> GPU-pod failures (L3).

## 1. The two-layer contract (verified layering)

**Host / AMI layer owns:**
- Kernel modules: `nvidia`, `nvidia_uvm`, `efa`, `efa_nv_peermem` (or `nvidia_peermem`),
  `gdrcopy`(+ nv-fabric/fabric manager on NVSwitch; Bottlerocket adds these as host services).
- Driver user-space: `libcuda.so.1`, `libnvidia-ml.so` (NVML), plus fabric-manager/persistenced/
  MIG-manager services (Bottlerocket bundles all; AL2023 bundles driver+CUDA user-mode+toolkit
  but no device plugin — A6/A7).
- The NVIDIA **container toolkit**: `libnvidia-container` (`nvidia-container-cli`), the
  `nvidia-container-runtime` (thin runc wrapper since 2019; injects a prestart hook and, since
  v1.12, devices/mounts into the OCI spec), and `nvidia-ctk` for CDI spec generation.

**Container layer ships:** the CUDA toolkit runtime + your stack (PyTorch, NCCL, aws-ofi-nccl,
FlashAttention/FlashInfer/DeepGEMM kernels, topology XMLs) — but **no kernel driver** and
(normally) **no `libcuda.so.1` of its own**.

**The injection mechanics:** CDI specs (toolkit ≥1.12; `nvidia-ctk cdi generate`; JIT-CDI
generates in-memory specs; `nvidia-cdi-refresh` keeps them current) or the classic hook path
mount the *host's* driver libraries into the container, filtered by
`NVIDIA_DRIVER_CAPABILITIES` (`compute` = CUDA/OpenCL, `utility` = nvidia-smi/NVML; **replaces**
the default `utility,compute` rather than adds — list everything you need) and selected by
`NVIDIA_VISIBLE_DEVICES` (indices/UUIDs/`all`/`none`/`void`). Bottlerocket defaults the plugin to
**CDI injection** (`device-list-strategy: cdi-cri`, A6).

## 2. The compatibility rules (verified)

| Rule | What it buys | Limits |
| --- | --- | --- |
| **Backward** | older CUDA apps run on newer drivers (always) | — |
| **Minor-version** (CUDA 11+) | app built with CUDA 13.x runs on any newer driver *within the 13.x family* (e.g. driver 580/CUDA 13.0) | some features (PTX **JIT** is supported here) |
| **Forward compat** | newer-toolkit app on *older* driver **across major families**, via `cuda-compat-<maj>-<min>` (e.g. `cuda-compat-13-4` = driver-615 libs in `/usr/local/cuda/compat/`; works on driver 535+) | **no PTX JIT**; older packages unsupported on newer drivers (check the table; `X` = no package provided) |

EKS-relevant baseline: EKS 1.34+ AMIs ship **driver 580 → CUDA 13+** (A6), so CUDA-13 images run
natively (minor-version compat); CUDA-12 images also run (backward). The `cuda-compat` package is
the escape hatch for the rare "new toolkit, old AMI" corner.

## 3. The failure catalog (verified)

| Symptom | Root cause | Fix |
| --- | --- | --- |
| `Failed to initialize NVML: Driver/library version mismatch` | user-space driver libs ≠ loaded kernel module (post-upgrade node) | reboot, or `modprobe -r nvidia nvidia_uvm` + reload; **relaunch running containers** (they keep the mounted old libs) |
| `libcuda.so.1: cannot open shared object` | capability not injected (`NVIDIA_DRIVER_CAPABILITIES` overwritten without `compute`) | set capabilities (replace semantics!) |
| GPU visible but compute fails / wrong GPU count | `NVIDIA_VISIBLE_DEVICES` semantics (`void`/unset = nothing; `none` = caps only) or CDI-vs-hook conflict (delete stale `oci-nvidia-hook.json` when using CDI) | align device selection; JIT-CDI on `mode=auto` |
| CUDA app won't start on old driver, toolkit too new | forward-compat needed | ship `cuda-compat-*` in image (mind PTX JIT) |

## 4. K8s operational consequences (blog-ready)

- **Driver upgrades are node events**, not container events: rolling AMI replacement
  (MNG/Karpenter drift) or Bottlerocket atomic OS updates (A7) — running pods must be rescheduled
  (and they lose weights/KV → A10's sleep-mode & warm-pool story). The GPU Operator alternative
  manages driver *containers* with upgrades as DaemonSet rollouts (C4/D5).
- Debug flow: `nvidia-smi` (host vs in-container), `nvidia-ctk cdi list`, toolkit logs —
  feeds article 05's "driver↔container contract" checklist.

## 5. Doubt questions (doubt map A3) → status

| Question | Status |
| --- | --- |
| What lives in the AMI vs the container? | **Answered** (§1) — incl. the injection mechanism (CDI/hook, capabilities). |
| Driver/CUDA mismatch failures? | **Answered** (§3 catalog). |
| When is `cuda-compat` needed? | **Answered** (§2 rules + table). |

## 6. Verified facts (sources, accessed 2026-10-03)

- Toolkit architecture & CDI (JIT-CDI, refresh service, hook conflicts): [CDI support](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html),
  [architecture overview](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/arch-overview.html).
- Env semantics (`NVIDIA_VISIBLE_DEVICES`, `NVIDIA_DRIVER_CAPABILITIES` replace-not-add):
  [Docker specialized configs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html).
- Compatibility rules + `cuda-compat-13-x` table (535→615 drivers; PTX-JIT caveat):
  [CUDA compatibility docs](https://docs.nvidia.com/deploy/cuda-compatibility/latest/),
  [forward compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/latest/forward-compatibility.html).
- NVML mismatch: [NVIDIA KB](https://enterprise-support.nvidia.com/s/article/how-can-i-fix-failed-to-initialize-nvml-driver-library-version-mismatch),
  [nvidia-docker#365](https://github.com/NVIDIA/nvidia-docker/issues/365).

## 7. Hands-on validation (scheduled)

LAB 05 (article 05): the "contract checklist" lab — host `nvidia-smi` vs in-container `nvidia-smi`,
`nvidia-ctk cdi list`, capability env variations (predict-then-verify: `utility` only → CUDA
fails), and a driver-mismatch reproduction in a disposable VM. D3 evidence when run.

## 8. Blog angle

"The two-layer contract": the layering diagram, the capabilities replace-not-add trap, the
compatibility table, and the failure catalog — the article readers will bookmark.
