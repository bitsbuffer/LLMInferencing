# LAB 03 — GPU anatomy & the bandwidth hierarchy (feeds article 03; fills B2's measured column)

> Covers tracker topics B1–B6 (topology read-out, hierarchy measurement, instance anatomy,
> DCGM). Created: 2026-10-03. Status: **not run**. Needs: 1× p5.48xlarge (or p5e/p5en) + 1×
> second node for cross-node rows; g6e.2xlarge as the PCIe-only contrast. Cost note: p5 ~$98/h —
> timebox to ≤2 h per session; use Capacity Blocks (A9) if reserving.

## Predictions (fill before running)

- P1: intra-node allreduce busbw (8×H100, NCLS expected): ___ GB/s
- P2: TP=2 allreduce busbw on g6e (PCIe) vs p5 (NVSwitch): ___ vs ___
- P3: cross-node (2×p5) allreduce busbw over EFA vs TCP/ENA: ___ vs ___
- P4: single-flow TCP throughput between two p5 nodes (ENA): ___ Gbps (spec cap: 100)
- P5: fio sequential read, one p5 NVMe disk vs all 8: ___ vs ___ GB/s
- P6: gdrcopy host→GPU bandwidth: ___ GB/s

## Protocol (rows → commands)

1. **Topology capture**: `nvidia-smi topo -m`, `nvidia-smi nvlink -s`, `lspci` EFA devices;
   save per-instance `bench/topo-<type>.txt` (LAB 01 step 12 output feeds here). Then the B3
   triad: `nvidia-smi nvlink -e` (predict 0 error counters), the fabric section of
   `nvidia-smi -q` (predict `Completed` + `Success`, 18 active links), and the tail of
   `/var/log/fabricmanager.log` (note any SXid/Xid) → append to `bench/topo-<type>.txt`.
2. **Intra-node NCCL** (p5): `all_reduce_perf -b 8M -e 1G -f 2 -g 8` with `NCCL_DEBUG=INFO`
   (expect NVLS lines); record busbw at 512M/1G; repeat with `NCCL_ALGO=Ring` for the NVLS-vs-Ring
   delta; record the *algorithm* NCCL chose per size.
3. **PCIe contrast** (g6e ×2 GPUs): same command with `-g 2`; also `p2pBandwidthLatencyTest`
   (cuda-samples) for the P2P matrix.
4. **Cross-node EFA**: 2×p5 pods (1 EFA device each for simplicity first, then 4/8/16 EFA
   devices), `NCCL_DEBUG=INFO` (expect `NET/OFI` provider `efa`), allreduce 512M–4G; repeat with
   EFA devices excluded (TCP fallback) for the P3 contrast. Cluster PG required (A9). Also the
   C4 checks: `lsmod | grep -E 'peermem|efa'` + `/sys/module/efa_nv_peermem/version` (predict
   which GDR registration path the node has) and note whether the aws-ofi-nccl GDA kernel
   backend engages in the NCCL logs (v1.21+, NCCL ≥2.31.2).
5. **ENA**: `iperf3` between nodes (TCP, single stream + 8 streams); **latency row (feeds C1):**
   run libfabric `fi_pingpong` over EFA (provider=efa) and over TCP in both message-size regimes
   (≤512 B and ≥8 kB) — expect to reproduce the SRD small-message latency gap vs the bulk-bandwidth
   parity story.
6. **NVMe**: `fio --name=seqread --rw=read --bs=1M --direct=1 --numjobs=1..8` on instance store;
   EBS gp3 equivalent for the EBS row.
7. **GDRCopy**: `gdrcopy_filter` / `sanity` + `bw_test` from the gdrcopy container.
8. **DCGM**: enable `DCGM_PROFILING` fields; capture HBM BW% + NVLink RX/TX during runs 2–4
   (feeds B6 and K2 dashboards).
9. **GPU sharing (feeds B5)**: on one H100 enable static MIG `1g.10gb`×7; serve Qwen3.5-0.8B on
   one slice with `CUDA_VISIBLE_DEVICES=MIG-<uuid>` (predict: works, NVML reports ~10 GB not 80);
   attempt TP=2 across two slices (predict: NCCL/P2P failure — same-GPU P2P only); then configure
   device-plugin time-slicing (replicas 4) and observe DCGM's missing container-metric mapping.
   Record all three outcomes in `bench/sharing-notes.md`.

## Deliverables

- `bench/hierarchy.csv`: layer, instance, spec, measured, tool, date, topo-hash
- Annotated `topo-*.txt` (B3's artifact) + a labeled matrix image for article 03
- One reconciled "estimate vs measured" paragraph per row (the D4 bar)

## Definition of done

- [ ] All predictions P1–P6 filled + reconciled
- [ ] `hierarchy.csv` complete for at least p5 + g6e
- [ ] NVLS-vs-Ring and EFA-vs-TCP deltas explained in one paragraph each
- [ ] Tracker B2 → D3/D4 when CSV lands
