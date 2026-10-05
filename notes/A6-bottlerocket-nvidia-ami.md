# A6 — Bottlerocket NVIDIA AMI contents + the built-in device plugin

> Tracker: A6 · Status: covered (D2) · Date: 2026-10-03
> Scope: what's inside the EKS-optimized Bottlerocket `aws-k8s-nvidia` variants, how to select the
> AMI (SSM/Karpenter), the bundled NVIDIA device plugin and its disable knob (needed for DRA), and
> how to debug an immutable GPU host. Feeds article 02. Comparison vs AL2023 → A7 (next).

## 1. Crisp understanding

Bottlerocket is an **immutable, minimal container host OS**: two parallel containerd instances —
one for the orchestrator's pods, one for **host containers** (control, admin, bootstrap) that
manage the OS itself. Configuration is an API model (`apiclient settings.*`), not dotfiles. For GPU
nodes you use the **`aws-k8s-{k8s-version}-nvidia`** variants (x86_64; `arm64` variant covers g5g).
The value proposition for inference fleets: tiny attack surface, atomic updates/rollbacks, and
**predictable GPU software** baked at build time instead of drifting DaemonSets.

## 2. Verified contents of EKS-optimized Bottlerocket NVIDIA AMIs

| Component | Notes |
| --- | --- |
| NVIDIA Kubernetes **device plugin** | **Installed and enabled by default** (the headline difference vs AL2023-NVIDIA, where you install it yourself) |
| NVIDIA driver | **580 for k8s ≥1.34** (required for CUDA 13+) |
| CUDA user-mode driver, NVIDIA container toolkit | host-level; containers get CUDA via toolkit mounts |
| NVIDIA fabric manager, persistenced | NVLink/fabric bring-up for NVSwitch nodes |
| NVIDIA IMEX driver, NVLink subnet manager | multi-node NVLink (GB200-class) plumbing |
| NVIDIA MIG manager | MIG config management (see §4 coupling) |
| EFA minimal (kernel module + rdma-core) | in **all** Bottlerocket variants (full EFA stack still needs the plugin/DRA driver — A5/A3) |
| gdrcopy | added in v1.63.0 for `aws-ecs-4-nvidia` [V for k8s variants] |

Build facts: kernel 6.12 tracks k8s 1.33+ (v1.63 kits also carry 6.18 [V]); Bottlerocket **v1.63.0**
introduced the plugin-disable setting and normalized NVIDIA library paths to `/usr/lib/`.

## 3. AMI discovery & pinning (verified)

**SSM parameter pattern** (needs `ssm:GetParameter`):
```
/aws/service/bottlerocket/aws-k8s-1.36-nvidia/x86_64/latest/image_id   # latest
/aws/service/bottlerocket/aws-k8s-1.36-nvidia/x86_64/1.63.0/image_id   # pinned OS version
```
(`{version}{-nvidia|-fips}` + arch; `arm64` for g5g.) Resolve via
`aws ssm get-parameter --name ... --query "Parameter.Value" --output text`.

**Karpenter:** `amiSelectorTerms` accepts `alias: bottlerocket@latest` or pinned
`alias: bottlerocket@v1.63.0`, or an explicit `ssmParameter:` term pointing at the `-nvidia`
parameter. Karpenter guidance: **pin in production** (`@latest` invites untested AMI drift;
fixed-version aliases re-resolve per K8s control-plane minor on cluster upgrade — nodes drift to a
rebuild matching the new minor). Exact auto-selection of the `-nvidia` variant from a plain
`bottlerocket@latest` alias for GPU node pools: **[V at lab time]** — the explicit SSM term is the
deterministic fallback.

## 4. The built-in device plugin — and how to turn it off

Bottlerocket's device plugin is a **host service**, not a DaemonSet you manage. Verified settings
model (`settings.kubelet-device-plugins.nvidia.*`):

| Setting | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | master switch (added in v1.63.0) |
| `pass-device-specs` | `true` | pass device specs to containerd |
| `device-list-strategy` | **`cdi-cri`** | CDI-based GPU injection (not the classic env-var list) |
| `device-id-strategy` | `index` | — |
| `device-sharing-strategy` | `none` | `mps` switches on the Bottlerocket-managed MPS control daemon |
| `device-partitioning-strategy` | `none` | `mig` + `mig.profile` (e.g. `a100.40gb: "7"`) drives the MIG manager |

**Disable (needed for the NVIDIA DRA driver, or to run GPU Operator/plugin yourself):**
`apiclient set settings.kubelet-device-plugins.nvidia.enabled=false` (or set in **userdata at
boot**). Verified side effects: MIG-manager config renders empty and the MPS control daemon stops
— MIG/MPS/host-plugin are **coupled**; with the plugin disabled, allocatable GPUs go to 0 and MIG
is disabled after a reboot. Don't run MIG partitioning alongside a disabled plugin.
Bonus: `device-list-strategy: cdi-cri` means Bottlerocket hosts use **CDI** for GPU injection —
worth contrast in article 02 vs classic `NVIDIA_VISIBLE_DEVICES` env injection.

## 5. Debugging an immutable GPU host (verified)

- **Admin container** (SSH as `ec2-user`, or `enter-admin-container` from the control container;
  disabled by default — enable via userdata). Contains a **Bottlerocket-patched
  `nvidia-bug-report.sh`** that auto-detects Bottlerocket, installs tools, and emits
  `nvidia-bug-report.log.gz`.
- **`kubectl debug node/<name> -it --image=ubuntu --profile=sysadmin`** (kubectl ≥1.30), then
  `chroot /host apiclient exec admin bash` (admin enabled) or `chroot /host` for the OS itself.
- Settings introspection: `apiclient get settings.kubelet-device-plugins.nvidia`.

## 6. Doubt questions → status

| Question | Status |
| --- | --- |
| Exact SSM path for NVIDIA variants? | **Answered** (`...-nvidia` flavor; once undocumented, now public — issue #4046 resolved). |
| Karpenter alias for NVIDIA variant? | Partially — alias families verified; `-nvidia` auto-resolution **[V at lab]**; SSM term is the safe pin. |
| Does the disable knob break MIG/MPS? | **Answered** — they're coupled to the plugin (PR #914 test matrix). |
| Bottlerocket vs AL2023-NVIDIA tradeoffs? | **Deferred → A7** (next deep-dive). |

## 7. Verified facts (sources, accessed 2026-10-03)

- AMI contents & versions: [EKS accelerated AMIs](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html).
- SSM discovery: [retrieve-ami-id-bottlerocket](https://docs.aws.amazon.com/eks/latest/userguide/retrieve-ami-id-bottlerocket.html),
  [bottlerocket#4046](https://github.com/bottlerocket-os/bottlerocket/issues/4046).
- v1.63.0 highlights: [release](https://github.com/bottlerocket-os/bottlerocket/releases/tag/v1.63.0);
  disable-knob design & coupled MIG/MPS behavior: [core-kit PR #914](https://github.com/bottlerocket-os/bottlerocket-core-kit/pull/914).
- Admin container & GPU diagnostics: [FAQ](https://bottlerocket.dev/en/faq/),
  [admin-container repo](https://github.com/bottlerocket-os/bottlerocket-admin-container/).
- Karpenter alias semantics & pinning: [NodeClasses](https://karpenter.sh/docs/concepts/nodeclasses/),
  [managing AMIs](https://karpenter.sh/preview/tasks/managing-amis/).
- DRA prerequisite (disable bundled plugin, ≥1.63.0): EKS DRA doc (see A3 notes).

## 8. Hands-on validation (scheduled)

LAB 01 **step 8** (Path B): Bottlerocket GPU NodePool via pinned SSM term; verify
`nvidia.com/gpu` allocatable *without* installing any plugin; then
`apiclient set settings.kubelet-device-plugins.nvidia.enabled=false` via kubectl-debug session and
watch allocatable go to 0; re-enable. Predict first: allocatable count, whether the device plugin
appears as a pod (it won't).

## 9. Blog angle

"The immutable GPU host": contents table (what ships vs what you add), the CDI injection default,
and the two coupled toggles (plugin ⇄ MIG manager/MPS) that bite anyone moving to DRA. Sets up A7's
decision table.
