# B6 — DCGM health & metrics exposure

> Tracker: B6 · Status: covered (D2) · Date: 2026-10-03 · **Cluster B complete (6/6).**
> Scope: DCGM's metric families and how they surface in K8s (dcgm-exporter vs the CloudWatch
> add-on), mapped to the decisions they justify. Feeds article 03 (lab capture), 14 (dashboards),
> 15 (failure catalog). Answers the DCGM-under-Auto-Mode question deferred from A1/A2.

## 1. Crisp understanding

**DCGM** = NVIDIA's data-center GPU telemetry/health layer (driver-level counters, health checks,
diagnostics). **dcgm-exporter** = the Prometheus bridge: DaemonSet, one pod per GPU node, uses the
**KubeletPodResources API** to attach GPU metrics to pods/containers, with a `ServiceMonitor` for
Prometheus Operator. Curated `DCGM_EXP_*` metrics sit on top of raw `DCGM_FI_*` fields. The
Amazon alternative: the **`amazon-cloudwatch-observability` EKS add-on deploys and manages the
DCGM exporter lifecycle itself** and ships NVIDIA GPU **and EFA metrics** to CloudWatch by default
(add-on ≥ v1.3.0-eksbuild.1, agent ≥ 1.300034.0; opt out via `accelerated_compute_metrics: false`),
with Container Insights dashboards drilling cluster→node→pod→container→GPU-device.

## 2. The metric families (verified, mapped to series topics)

| Family | Key fields | Explains |
| --- | --- | --- |
| Utilization / memory | `DCGM_FI_DEV_GPU_UTIL`, `FB_USED`, `POWER_USAGE`, `GPU_TEMP` | B2/B5 roofline sanity (B5 caveat: no container mapping under time-slicing) |
| **Profiling (DCP)** | `DCGM_FI_PROF_DRAM_ACTIVE` (cycles the HBM interface is active), `PROF_SM_ACTIVE`, `PROF_PIPE_TENSOR_ACTIVE` | the *real* decode roofline measurement — B2's HBM row |
| NVLink health (per-gen naming!) | pre-Hopper: `NVLINK_CRC_FLIT/DATA_ERROR`, `REPLAY`, `RECOVERY_ERROR`; Hopper: `NVLINK_CRC_ERROR/RECOVERY/REPLAY_TOTAL`; **Blackwell+: `NVLINK_RECOVERY_SUCCESSFUL/FAILED/EVENT_TOTAL`** | B3's link-trust layer, continuously |
| NVLink traffic | `DCGM_FI_DEV_NVLINK_BANDWIDTH_TOTAL` / `_L0` (MB/s) | B2 NVLink measured column; TP-activity evidence |
| Errors / health | `DCGM_FI_DEV_XID_ERRORS` (last XID), `DCGM_EXP_XID_ERRORS_COUNT` (windowed, by `xid`), `DCGM_EXP_XID_ERRORS_TOTAL`, `DCGM_EXP_GPU_HEALTH_STATUS` (per-watch, severity/category labels), `DCGM_EXP_P2P_STATUS` (per GPU pair, `link_status`) | L3 failure catalog triggers; B1/B5 P2P state |
| Memory reliability | `UNCORRECTABLE/CORRECTABLE_REMAPPED_ROWS`, `ROW_REMAP_FAILURE`, `ECC_SBE/DBE_VOL/AGG_TOTAL` | pre-OOM hardware warnings (row remap failures = replace) |
| Clocks | `DCGM_EXP_CLOCK_EVENTS_COUNT/TOTAL` (by `clock_event`) | thermal/power throttling detection |

## 3. EKS wiring (verified)

- **Self-managed (Prometheus path)**: `helm repo add gpu-helm-charts
  https://nvidia.github.io/dcgm-exporter/helm-charts`; chart ships the DaemonSet + default
  counters + ServiceMonitor (disable if no Prometheus-Operator CRDs). Works on Auto Mode nodes
  (drivers are AWS-managed; the exporter only needs the driver + pod-resources API).
- **CloudWatch path (Auto Mode-friendly)**: `aws eks create-addon --addon-name
  amazon-cloudwatch-observability` — managed DCGM exporter + GPU **and EFA** metrics, curated
  dashboards/alarms, opt-out knob. Decision = Prometheus-native vs CloudWatch-native (this
  answers the A1/A2 deferred question; D5 will reference it).
- Custom counters: edit the counters CSV/config (same caveat class as B5's config-map edit —
  restart needed [V]); nodeSelector/tolerations to GPU nodes.

## 4. Doubt questions → status

| Question | Status |
| --- | --- |
| DCGM exporter placement under Auto Mode? | **Answered** — two supported paths: self-installed dcgm-exporter (Prometheus) or the CloudWatch add-on (managed DCGM + EFA metrics by default). |
| The 8 numbers an LLM dashboard needs? | `PROF_DRAM_ACTIVE` (decode roofline), `NVLINK_BANDWIDTH_TOTAL`, `NVLINK_*_ERROR/RECOVERY` (gen-correct family), `XID_ERRORS` + `EXP_XID_ERRORS_TOTAL`, `EXP_GPU_HEALTH_STATUS`, `EXP_P2P_STATUS`, `FB_USED`, `GPU_TEMP` |
| Are container-mapped metrics reliable? | Under time-slicing no (B5); standard device plugin yes (KubeletPodResources mapping). |
| Pre-Hopper vs Hopper vs Blackwell counter names? | Verified per-gen naming (§2) — dashboards must pick the right family per fleet mix. |

## 5. Verified facts (sources, accessed 2026-10-03)

- Default counters CSV (all families): [dcgm-exporter etc/default-counters.csv](https://github.com/NVIDIA/dcgm-exporter/blob/main/etc/default-counters.csv).
- `DCGM_EXP_*` semantics + labels: [DCGM exporter metrics reference](https://docs.nvidia.com/datacenter/dcgm/latest/reference/dcgm-exporter-metrics.html).
- Helm install + ServiceMonitor + KubeletPodResources mapping:
  [install-dcgm-exporter](https://docs.nvidia.com/datacenter/dcgm/latest/installation/install-dcgm-exporter.html),
  [dcgm-exporter docs](https://nvidia.github.io/dcgm-exporter/).
- CloudWatch add-on auto-collection + opt-out + versions:
  [CloudWatch EKS add-on docs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html),
  [GPU observability blog](https://aws.amazon.com/blogs/mt/gain-operational-insights-for-nvidia-gpu-workloads-using-amazon-cloudwatch-container-insights/).

## 6. Hands-on validation

Covered by **LAB 03 step 8** (profiling fields during the benchmark matrix) + LAB 01/02 dashboards.
B6 reaches D3 when the LAB 03 runs produce real counter traces; the CloudWatch-addon path can be a
10-minute add-on install on the same cluster for the comparison screenshot.

## 7. Blog angle

"Watch the right eight numbers": the dashboard recipe table above, the per-generation NVLink
counter trap, and the Prometheus-vs-CloudWatch fork as the platform decision. Closes Cluster B —
everything from here is fabric and serving software.
