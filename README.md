# CNPG Graduated Network Degradation Study

Fault-injection scripts, measurement observer, and analysis code
supporting:

> Jerrari, I., Assayad, I. "Beyond Binary Failures: An Empirical Study
> of Graduated Network Degradation and Its Impact on Availability and
> Durability in CloudNativePG." Submitted, 2026.

[![DOI](https://zenodo.org/badge/DOI/PLACEHOLDER.svg)](https://doi.org/PLACEHOLDER)
<!-- Replace the badge above with the real Zenodo DOI once archived -->

## What this is

A controlled experimental study of CloudNativePG (CNPG) under seven
fault scenarios (symmetric/asymmetric partitions, graduated link
degradation, node crashes; partial single-replica and full
all-replica variants), run on a `kind` Kubernetes cluster. This
repository contains everything needed to reproduce the fault
injection, the measurement pipeline, and the statistical analysis.

## Repository structure

```
.
├── README.md
├── LICENSE                       <- MIT (code) / see NOTICE for data license
├── CITATION.cff
├── environment/
│   ├── kind-cluster.yaml         <- kind cluster topology
│   ├── cnpg-values.yaml          <- CNPG operator configuration (quorum setup)
│   └── versions.txt              <- exact CNPG / PostgreSQL / kind / k8s versions
├── fault-injection/
│   ├── lib_iptables_tc.sh        <- shared iptables/tc netem helpers
│   ├── inject_nodecrash.sh
│   ├── inject_p1_partial.sh
│   ├── inject_p1_full.sh
│   ├── inject_p2_partial.sh
│   ├── inject_p2_full.sh
│   ├── inject_p3_partial.sh
│   └── inject_p3_full.sh
├── observer/
│   ├── observer.py               <- replication-state poller / write-outcome logger
│   └── metrics.py                <- RTO, write_downtime_s, total_fail_duration_s, RPO (LSN-based)
├── data/
│   ├── raw/                      <- per-run CSVs (add your real data here, see below)
│   └── logs/                     <- iptables/PostgreSQL logs for flagged anomaly runs
└── analysis/
    ├── stats_tests.py            <- Shapiro-Wilk, BCa bootstrap, Cohen's d
    ├── make_figures.py           <- regenerates Fig. 1 and Fig. 2 from data/raw/*.csv
    └── requirements.txt
```

## Status of this repository

- [x] Directory structure and code skeletons in place
- [ ] **`data/raw/*.csv` still need to be populated with the real
      per-run measurements from the campaign** (n=40 to 57 per
      scenario). Until then, `analysis/make_figures.py` will not have
      real data to plot.
- [ ] `environment/versions.txt` needs the exact software versions used
- [ ] The two excluded P3-full anomaly runs and their logs need to be
      added to `data/logs/` (see Section on Threats to Validity in the
      paper)

## Quick start

```bash
pip install -r analysis/requirements.txt
python analysis/stats_tests.py data/raw/
python analysis/make_figures.py data/raw/
```

## CSV schema (one row per run)

All files under `data/raw/` should share this schema so the analysis
scripts run without per-scenario glue code:

```
run_id, scenario, replica_target, start_ts, fault_injected_ts,
first_failed_write_ts, first_stable_write_ts, recovery_ts, rto_s,
write_downtime_s, total_fail_duration_s, lsn_before, lsn_after,
rows_lost, notes, excluded, exclusion_reason
```

## License

Code in this repository is released under the MIT License (see
`LICENSE`). The dataset (once added under `data/raw/`) is intended to
be released under CC-BY-4.0 -- update `NOTICE` accordingly when you
add it.

## Citation

See `CITATION.cff`. Please cite the paper above if you use this code
or data.
