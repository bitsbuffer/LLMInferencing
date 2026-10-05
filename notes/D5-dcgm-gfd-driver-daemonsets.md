# D5 — DCGM exporter, GFD, driver-upgrade DaemonSets (deployment view)

> Tracker: D5 · Status: covered (D2) · Date: 2026-10-03 · **Cluster D complete (5/5).**
> Scope: the deployment-level picture — who installs the exporter/GFD/driver-upgrade machinery in
> each model, and the driver-DaemonSet's internal anatomy. Consolidates B6 (metrics), A4 (GFD
> labels), D4 (management models); closes Cluster D. Feeds article 05/15.

## 1. Who deploys what (per model)

| Component | EKS-AMI path | GPU Operator | Auto Mode |
| --- | --- | --- | --- |
| **DCGM exporter** | self-install: Helm (`gpu-helm-charts/dcgm-exporter`, DaemonSet + pod-mapping + ServiceMonitor) or **CloudWatch add-on** (AWS-managed exporter, GPU+EFA metrics, B6) | **installed by default** (`dcgmExporter.enabled`; config via operator-owned ConfigMap — don't edit the DaemonSet; `internalTrafficPolicy: Cluster|Local`) | CloudWatch add-on or self-install (drivers present, so it works) |
| **GFD (labels)** | device-plugin chart `gfd.enabled=true` (auto-pulls **NFD**; `nfd.enabled=false` to skip) — **GFD lives in the k8s-device-plugin repo since v0.15.0** (standalone repo archived) | operator deploys GFD | labels from Auto Mode (`instance-gpu-name` etc.); GFD n/a |
| **Driver upgrade** | node replacement (new AMI → Karpenter drift / MNG rolling) | **driver DaemonSet + upgrade controller** (D4 state machine; `daemonsets.updateStrategy: OnDelete` for manual control) | AWS |

## 2. The driver DaemonSet, from the inside (verified from operator assets)

Privileged pods (`privileged: true`, hostPID, hostIPC — required to touch devices, restart
containerd, enumerate clients). Containers per node:

- `nvidia-driver-ctr` — `nvidia-driver init`: builds/loads kernel modules; startup probe script
  (60s delay, 120 retries); mounts `/run/nvidia` (bidirectional — where the driver root lives,
  cf. DRA's `nvidiaDriverRoot=/run/nvidia`), host `/sys`, mellanox `usr/src`, firmware path;
  preStop removes the `.driver-ctr-ready` marker.
- `nvidia-peermem-ctr` — **reloads `nvidia_peermem` whenever MOFED reinstall dynamically unloads
  it** (the exact dependency C4's UCX/NIXL story hinges on); probes for peermem.
- `nvidia-fs-ctr` (GDS; waits for driver, `lsmod nvidia_fs`) and `nvidia-gdrcopy-ctr` (`gdrdrv`)
  — only with their flags enabled.
- Legacy env knobs on the daemonset (`k8s-driver-manager` path): `ENABLE_GPU_POD_EVICTION`,
  `ENABLE_AUTO_DRAIN`, `DRAIN_USE_FORCE`, `DRAIN_POD_SELECTOR_LABEL`.

**Classic failures (verified troubleshooting):** `nouveau` loaded ⇒ driver container can't load
`nvidia` (blacklist + initramfs + reboot); all operand pods stuck in `Init` until driver+toolkit
pods are healthy; driver containers need internet for runtime deb/rpm package downloads; CRI-O +
v25.10 transient `Init:RunContainerError`s.

## 3. GFD specifics (recap + verified packaging)

Labels (`nvidia.com/gpu.product`, `gpu.memory`, `cuda.driver.*`, MIG overrides — A4) are produced
by the *label-manager side of the device plugin chart*: `gfd.enabled=true` (needs NFD's
NodeFeature CRD path; auto-deploys NFD). Standalone GFD = same chart with
`devicePlugin.enabled=false`. Under time-slicing the product label gains `-SHARED` (B5).

## 4. Doubt questions → status

| Question | Status |
| --- | --- |
| DCGM exporter placement (incl. Auto Mode)? | **Answered** (B6 + §1): self-Helm/CloudWatch on any path; operator-owned ConfigMap when operator-managed. |
| Where does GFD live now? | **Answered**: inside k8s-device-plugin (v0.15+); standalone chart mode exists. |
| What runs inside a driver DaemonSet pod? | **Answered** (§2): driver + peermem + optional GDS/gdrcopy sidecars, all privileged, with module probes. |

## 5. Verified facts (sources, accessed 2026-10-03)

- GFD merge & chart flags: [k8s-device-plugin README](https://github.com/NVIDIA/k8s-device-plugin?tab=readme-ov-file),
  [GFD README](https://github.com/NVIDIA/k8s-device-plugin/blob/main/docs/gpu-feature-discovery/README.md),
  [archived GFD repo](https://gitlab.com/nvidia/kubernetes/gpu-feature-discovery).
- Driver DaemonSet anatomy: [operator state-driver YAML](https://github.com/NVIDIA/gpu-operator/blob/main/assets/state-driver/0500_daemonset.yaml).
- Troubleshooting (nouveau, Init-stuck, CRI-O): [operator troubleshooting (26.3)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/26.3/troubleshooting.html).
- DCGM exporter modes + operator config: [install-dcgm-exporter](https://docs.nvidia.com/datacenter/dcgm/latest/installation/install-dcgm-exporter.html),
  [operator getting-started (dcgmExporter.enabled, nfd.enabled)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/25.3.2/getting-started.html).
- Privileges rationale: [operator overview (25.9.2)](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/25.9.2/index.html).

## 6. Hands-on validation

LAB 05: after the operator install diff (D4), capture `kubectl get pods -n gpu-operator` (predict:
driver-daemonset with peermem sidecar, dcgm-exporter, gfd/gpu-feature-discovery, toolkit,
validator) and, on the AMI path, confirm which of those are *absent* by default. D3 evidence when
run; B6's dashboard covers the continuous half.

## 7. Blog angle

Short deployment-view article (or article-05 section): "who deploys what, and what's inside the
driver pod" — the sidecar anatomy and the nouveau trap are the practical gems.
