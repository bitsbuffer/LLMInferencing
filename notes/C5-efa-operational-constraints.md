# C5 — EFA operational constraints (+ ENA Express distinction)

> Tracker: C5 · Status: covered (D2) · Date: 2026-10-03
> Scope: the "gotchas box" for article 04 — the official limitations list, the security-group
> rule, attach semantics, MTU/window knobs. Facts consolidated from A5/C1/C4; this file is the
> single constraints reference.

## 1. The official EFA limitations (verified verbatim from EC2 docs)

1. **RDMA write is not supported on all instance types** (read: all Nitro v4+; write: most).
2. **EFA traffic between P4d/P4de/DL1 and *other* instance types is not supported** — the
   mixed-fleet trap: an older p4d cannot even EFA-talk to a newer p5.
3. **One EFA device per network card** (multi-card types); all other types: one EFA per instance.
4. Some Dedicated-Instance/Host combos (c7g/m7g/r7g.16xlarge) unsupported with EFA.
5. **EFA traffic cannot cross Availability Zones or VPCs** (plain IP traffic from the interface's
   ENA device is not restricted).
6. **EFA traffic is not routable** — it's fabric-local; only the ENA side gets IP routing.
7. Not supported on AWS Outposts.
8. Windows: EFA device only for CDI-SDK apps; EFA-only unsupported on Windows.

## 2. Attach & lifecycle semantics (verified)

- EFAs **cannot attach/detach while an instance runs** (launch-time or stopped-instance only);
  cannot move subnets after creation; same-AZ only. K8s consequence: **changing a node's EFA
  interface layout = replacing the node** — hence A5's "provisioning layer owns it" framing and
  Karpenter's `networkInterfaces` (change → drift → node replacement).

## 3. Security group — the self-referencing all-traffic rule (verified)

- EFA requires a security group that allows **all inbound + outbound traffic to and from itself**
  (protocol `-1`, source/destination-group = the same SG): 
  `aws ec2 authorize-security-group-ingress --group-id $SG --protocol -1 --source-group $SG`
  (+ egress mirror). SSH rules added separately for admin.
- **Security-review talking point** for the blog: why all-traffic? Because EFA traffic is *not IP
  routable* — the SG is the only policy control on the fabric path, and packets aren't
  traditional IP flows the SG engine could filter by port anyway. Scope it tightly (one SG per
  cluster/fabric domain) and say so in the threat model.

## 4. MTU & window knobs (verified)

- EFA device MTU ≈ **8 KiB** (SRD packets); DGRAM endpoints cap message size at MTU;
  `FI_EFA_MTU_SIZE` override exists; `FI_EFA_RX_WINDOW_SIZE` = max in-flight MTU-sized messages
  per endpoint for long transfers (exceed → error). ENA-side jumbo frames (9001) apply to the IP
  path, not EFA SRD. ENA Express needs *lower* MTU for its SRD headers (C1).
- Paired consumer knobs (A5's matrix): NCCL channels/buffers, NIXL backends; SRD itself has no
  host knobs (C2).

## 5. ENA Express ≠ EFA (recap, verified in C1)

SRD appears twice: EFA (libfabric/NCCL/NIXL, same-AZ, not routable) vs ENA Express (SRD for plain
TCP/UDP, **cross-AZ OK**, 5→25 Gbps single flow, UDP opt-in, falls back to standard ENA). An
article-04 table that separates the two prevents the most common reader confusion.

## 6. Doubt questions → status

| Question | Status |
| --- | --- |
| efa-only vs EFA-with-ENA practical differences on EKS? | **Answered** (A5 §2 + C1 §1; this file's list adds the Windows/mixed-fleet caveats). |
| MTU implications? | **Answered** (§4). |
| SG requirement? | **Answered** (§3). |
| EFA-IMDS (metadata over efa-only ENIs)? | [V] — service exists for IP-less EFA-only interfaces; verify the doc line at publish. |

## 7. Hands-on validation

Covered across LAB 01 step 7 (SG + plugin), LAB 03 step 4 (same-AZ pair), and A9 step 10 (cluster
PG + the predicted AZ error). The deliberate cross-AZ failure demo belongs to article 04's lab —
launch two nodes in different AZs, attempt NCCL init, capture the libfabric/NCCL error, and
screenshot it as the "constraint made real" artifact.

## 8. Blog angle

"The fine print that pages you at 3 a.m.": the limitations list as a checklist, the SG rationale
(defense of all-traffic in a security review), the mixed-fleet trap, and the ENA-Express-vs-EFA
table. Constraints make the article practical instead of theoretical.
