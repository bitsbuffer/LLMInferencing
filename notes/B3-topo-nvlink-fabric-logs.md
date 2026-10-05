# B3 — Reading `topo -m`, `nvlink`, and fabric-manager logs like an operator

> Tracker: B3 · Status: covered (D2) · Date: 2026-10-03
> Scope: the three diagnostic surfaces of an NVSwitch GPU node — shape (topology matrix),
> state (links), trust (fabric) — plus the failure playbook. Feeds article 03; feeds D5/K2
> (what DCGM should be watching).

## 1. Crisp understanding

When a multi-GPU serving node misbehaves (NCCL timeouts, mysterious TP slowdowns), the answer is
almost always in one of three places:
1. **Shape** — `nvidia-smi topo -m`: is the topology what you paid for? (all NV## on an HGX board,
   NICs `PIX`-adjacent to their GPUs, expected CPU-affinity split)
2. **State** — `nvidia-smi nvlink`: are links *active* at the right bandwidth, error counters clean?
3. **Trust** — fabric manager: did the NVLink fabric initialize (`Completed/Success`)? Do the logs
   show SXid/Xid events?

## 2. The commands (verified)

**Shape:**
- `nvidia-smi topo -m` — GPU×GPU matrix with the legend (`NV#` = bonded # NVLinks; `PIX`/`PXB`/
  `PHB`/`NODE`/`SYS`), a **CPU Affinity** column (NUMA cores per GPU — drives the A4 NUMA story),
  and with `-mp` the NIC columns (the GPU↔NIC `PIX` affinities that DRA's EFA pairing encodes).
- Known quirks: can take >1 min on big boards; multi-root-complex CPUs (Skylake+) can report `SYS`
  between devices on the *same* socket — read the legend, don't guess.

**State:**
- `nvidia-smi nvlink --status -i <gpu>` — per-link active state + bandwidth (MNNVL check pattern:
  "18 links active to nine switch trays, each at 50 GB/s" on GB200-class).
- `nvidia-smi nvlink -e -i <gpu>` — per-link **error counters** (NVML exposes per-counter reads and
  resets; utilization RX/TX counters need explicit control setup).
- `-p` — peer link mapping (which link connects to which peer).

**Trust:**
- `nvidia-smi -q | grep 'Fabric' -A 4` — **Fabric state** (`Completed` / `In Progress` / `Not
  Started` / `Not supported`) and **probe status** (`NVML_SUCCESS` = success). Healthy expected
  output: `Completed` + `Success`.
- Newer fabric-health summary fields (650-class+): `Healthy / Unhealthy / Limited Capacity`,
  `Bandwidth degraded`, `Route Recovery in progress`, `Route Unhealthy`, `Access Timeout
  Recovery`, `Incorrect Configuration`, `Partition Assigned` — treat any non-green as a P1.
- **Fabric manager logs**: default `/var/log/fabricmanager.log` (configurable `LOG_FILE_NAME`;
  clear-text; run at INFO level for field debugging). NVSwitch routers keep state/dump files
  alongside (`nvlsm-*.lst`, `*.fdbs`, `nvlsm-routers.dump`, perflog.json) under `/var/log/` and
  `/var/run/nvidia-fabricmanager`.
- **Error namespace**: **`SXid`** = NVSwitch-originated events; **`Xid`** = GPU driver events
  (Xid 74 = NVLink error class). `dmesg` carries Xid 74 details.

## 3. Failure playbook (verified)

| Symptom | Triage path |
| --- | --- |
| NCCL init hangs / TP mysteriously slow | topo -m: is the NV# fabric full-width? If pairs show NV fewer than expected or fall to `PHB`/`NODE`, links are down/degraded → go to State |
| `nvidia-smi -q` fabric state ≠ `Completed` | FM crashed or never started: check `fabricmanager.log`; Ampere-era rule: without FM, peer GPUs must be reset together (Hopper+ removed the FM *reset* dependency, but FM still owns fabric bring-up) |
| nvlink error counters climbing | Intermittent + temp-correlated → cooling; persistent uncorrectable → hardware: identify GPU/link (`nvidia-smi -q`), reseat/replace bridge (HGX bridge is separately replaceable), RMA; *workaround*: `CUDA_VISIBLE_DEVICES` excludes the affected GPU |
| Xid 74 in dmesg | NVLink-class error — correlate with fabricmanager.log SXids and DCGM link-error fields (B6) |

K8s angle: on EKS these surfaces are reached differently per AMI strategy — Bottlerocket via
`kubectl debug --profile=sysadmin` + `chroot /host` (+ admin container for `nvidia-bug-report.sh`),
AL2023 via SSH/SSM; and the *continuous* version of all three surfaces is DCGM fields exported by
dcgm-exporter (D5/B6) — matrix is static, links & fabric are the watch-items.

## 4. Doubt questions (self-defined) → status

| Question | Status |
| --- | --- |
| Expected fabric state on p5? | `Completed` + `Success`, 18 links/GPU active — **[V in LAB 03 step 1]**. |
| Does Hopper+ still need FM? | FM is not required *for reset* anymore but still runs fabric management on NVSwitch nodes — phrase carefully in the blog. |
| Can I see this from inside a pod? | Matrix/links yes (if devices mounted); FM logs are host-side → node debug or DCGM. |
| What does DCGM watch here? | NVLink error counters + fabric/link health fields — enumerated in D5/B6 deep-dive. |

## 5. Verified facts (sources, accessed 2026-10-03)

- Command semantics & FM log/state paths, SXid/Xid namespace:
  [Fabric Manager user guide](https://docs.nvidia.com/datacenter/tesla/fabric-manager-user-guide/),
  [nvidia-smi docs](https://docs.nvidia.com/deploy/nvidia-smi/) (incl. the reset × FM table).
- Fabric-state/probe fields + MNNVL verification pattern (18 links @ 50 GB/s):
  [nvidia-smi docs (fabric section)](https://docs.nvidia.com/deploy/nvidia-smi/),
  [MNNVL verifying guide](https://docs.nvidia.com/multi-node-nvlink-systems/mnnvl-user-guide/verifying.html).
- NVLink error triage + Xid 74: [deadends.dev NVLink error](https://deadends.dev/cuda/nvlink-error/).
- NVML link APIs (state/errors/utilization/reset): [NVML reference](https://docs.nvidia.com/deploy/nvml-api/group__NvLink.html).
- topo quirks + legend: [NVIDIA forums](https://forums.developer.nvidia.com/t/strange-output-by-nvidia-smi-topo/68452/1).

## 6. Hands-on validation (scheduled)

LAB 03 **step 1 extended**: after `topo -m`, run `nvlink -s` + `nvlink -e` (predict: 18 active
links, 0 errors), capture the fabric section (`Completed`/`Success` predicted), and copy
`fabricmanager.log` tail into `bench/`. Then cross-check DCGM's link-error fields — full matrix
in LAB 03.

## 7. Blog angle

"Three lights and a log file": matrix = shape, links = state, fabric = trust. The SXid-vs-Xid
table and the reset-semantics footnote (Ampere vs Hopper) are the reader-screenshot material.
