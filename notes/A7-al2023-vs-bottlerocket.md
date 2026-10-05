# A7 — EKS-optimized AL2023-NVIDIA vs Bottlerocket: the decision table

> Tracker: A7 · Status: covered (D2) · Date: 2026-10-03
> Scope: the actual 2026 AMI choice for GPU nodes and the criteria that decide it.
> Feeds article 02 (this table is the article's spine). Build blocks verified in A2–A6.

## 1. Crisp understanding

As of 2026 the question is no longer "AL2 vs the others": **EKS stopped publishing AL2/AL2-accelerated
AMIs on 2025-11-26; k8s 1.32 was the last AL2 AMI version; there is no AL2 AMI for 1.33+.** AL2's
cgroupv1 is in maintenance mode (no MemoryQoS, weaker resource isolation). The real choice:
**AL2023-NVIDIA, Bottlerocket-NVIDIA, or hand the whole thing to Auto Mode.** Both supported AMIs
preinstall the host NVIDIA driver (580 for ≥1.34 / CUDA 13+), CUDA user-mode, and container
toolkit, and both are cgroupv2 by default. Everything else diverges:

## 2. The decision table

| Criterion | EKS-optimized **AL2023 NVIDIA** | **Bottlerocket** `aws-k8s-nvidia` | (EKS) **Auto Mode** |
| --- | --- | --- | --- |
| NVIDIA device plugin | ❌ not included — install yourself | ✅ host service, **on by default** | ✅ managed by AWS, invisible |
| DRA driver | ✅ install yourself | ✅ after disabling bundled plugin (≥1.63.0) | ❌ DRA unsupported |
| GPU Operator | ✅ possible — disable operator driver+toolkit (already in AMI) | ⚠️ discouraged — must disable driver+toolkit+plugin; maintainers recommend plain helm installs of DCGM/GFD instead | n/a |
| **Topology-aligned GPU↔EFA allocation (plugin path)** | ✅ **automatic** (only on EKS-optimized AL2023 accelerated AMIs) | ❌ not automatic — needs EFA DRA + NVIDIA DRA drivers | ⚠️ plugin-level only |
| GFD/labels | `nodeadm` sets **`nvidia.com/gpu.present=true` at boot**; GFD optional for basic scheduling | via bundled plugin; add GFD via helm if wanted | labels via Auto Mode (`instance-gpu-name` etc.) |
| MIG / MPS config | device-plugin config / GPU Operator / DRA (static GA; dynamic alpha) | settings-driven, **coupled** to the host plugin (`enabled=false` kills MIG manager + MPS daemon) | static sharing managed by AWS |
| EFA host stack | ✅ in AMI | ✅ minimal (module+rdma-core) in all variants | ✅ + NodeClass `advancedNetworking` |
| Update model | node replacement (MNG AMI version / Karpenter drift; nodeadm bootstraps) | **in-place atomic A/B** (`apiclient update`, best via **Brupop**; or SSM docs; or node replacement via console/eksctl) | managed by AWS |
| Debug workflow | standard SSH/SSM | admin container (SSH/ec2-user or `enter-admin-container`), `sheltie` for host shell, `kubectl debug --profile=sysadmin` + `chroot /host`, patched `nvidia-bug-report.sh` | EKS-managed |
| Security posture | standard AL2023 | immutable rootfs, minimal surface, FIPS variants, API-driven settings | AWS-managed |
| AMI pinning | alias/ssm pin per Karpenter guidance | same (`bottlerocket@v1.63.0` or SSM) | not user-controlled |

## 3. Guidance for this series (and the blog)

- **Default recipe = AL2023-NVIDIA**: cleanest DRA/topology story (automatic GPU↔EFA alignment on
  the plugin path), no bundled-plugin coupling to fight, GPU Operator possible when needed.
- **Choose Bottlerocket** for fleet-security/atomic-update stories — but budget for its coupling
  gotchas (plugin ⇄ MIG/MPS) and the missing auto topology alignment (use DRA drivers there).
- **Auto Mode** = article 01's fast path; the ceiling is "no DRA, no AMI choice".
- The comparison lab (same probe pod on all three, diffing `kubectl describe node` and measuring
  time-to-first-healthy-GPU-pod) is article 02's hero experiment — its own lab file gets created
  when article 02 drafting starts (`labs/02-ami-comparison/`).

## 4. Doubt questions → status

| Question | Status |
| --- | --- |
| Is AL2 still an option? | **Answered — no** (no AMIs ≥1.33; EOS 2025-11-26; cgroupv1 maintenance). |
| GPU Operator on Bottlerocket? | **Answered — discouraged**; if forced: disable driver+toolkit+plugin; drivers live in the root image and can't be pinned by the operator. |
| Does AL2023 need GFD for basic scheduling? | **Answered — no** (`nodeadm` applies `nvidia.com/gpu.present=true` at boot). |
| In-place vs replacement updates for Bottlerocket? | **Answered** (Brupop/SSM in-place; console/eksctl replacement). |

## 5. Verified facts (sources, accessed 2026-10-03)

- AL2 AMI EOL & cgroupv1 rationale: [deprecation FAQs](https://docs.aws.amazon.com/eks/latest/userguide/eks-ami-deprecation-faqs.html),
  [extended-support page](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-extended.html).
- AMI contents + GPU Operator conditions + nodeadm label:
  [ml-eks-optimized-ami](https://docs.aws.amazon.com/eks/latest/userguide/ml-eks-optimized-ami.html),
  [DRA/device-plugin table](https://docs.aws.amazon.com/eks/latest/userguide/device-management-nvidia-dra-device-plugin.html).
- GPU Operator × Bottlerocket stance: [issue #4162](https://github.com/bottlerocket-os/bottlerocket/issues/4162),
  [discussion #3967](https://github.com/bottlerocket-os/bottlerocket/discussions/3967) (incl. `sheltie` host-shell trick).
- Bottlerocket update methods: [in-place](https://bottlerocket.dev/en/os/1.65.x/update/methods/in-place/),
  [node replacement](https://bottlerocket.dev/en/os/1.25.x/update/methods/node-replacement/).

## 6. Hands-on validation

Scheduled as article 02's lab (three-strategy comparison); step 8 of LAB 01 already exercises the
Bottlerocket branch. No separate file yet — created at article-02 drafting time.

## 7. Blog angle

The article is the table plus three war stories: the plugin-disable coupling on Bottlerocket, the
"automatic topology alignment exists only on AL2023" asymmetry, and the AL2 sunset that forces
everyone through this decision anyway.
