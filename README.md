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
repository contains the deployment/campaign scripts, the raw per-run
measurement data (n=40 per scenario, n=57 for P3-full), and the
analysis code used to produce every statistic reported in the paper.

A related but separate campaign comparing CNPG against Patroni under a
matched fault taxonomy exists as its own study and repository; it is
not included here (see the paper's Threats to Validity section).

## Repository structure

```
.
├── README.md
├── LICENSE                     <- MIT (code) / see NOTICE for data license
├── NOTICE                      <- data license (CC-BY-4.0)
├── CITATION.cff
├── environment/
│   └── versions.txt            <- software versions used (see TODOs inside)
├── scripts/                    <- PowerShell deployment / campaign / analysis scripts
│   ├── deploy_cnpg.ps1          <- kind cluster + CNPG operator deployment (quorum config)
│   ├── run_campaign.ps1         <- orchestrates repeated fault-injection runs
│   ├── probe_worker.ps1         <- unidirectional write-probe worker
│   ├── analyze_run.ps1          <- per-run metric extraction (RTO, write_downtime_s, RPO)
│   ├── analyze_pilot.ps1        <- n=1 pilot analysis
│   ├── merge_summary.ps1        <- merges per-batch manifests into results_final/summary.csv
│   ├── analyze_stats.py         <- original campaign statistics (superseded in part by analysis/stats_corrected.py)
│   ├── pilot_p2_partition_validation.ps1 / .sh
│                                 <- unidirectional UDP probe validation (Section 3.4 of the paper)
├── data/
│   ├── raw/
│   │   ├── summary.csv          <- one row per run, all 7 scenarios (n=297 rows total)
│   │   └── <scenario>/          <- kill, p1, p1-full, p2, p2-full, p3, p3-full
│   │       ├── manifest.csv     <- per-run metadata (timestamps, RPO threshold, log filenames)
│   │       ├── *.writer.csv     <- one row per write attempt (t_start, t_end, status)
│   │       └── *.role.csv       <- replication-role / LSN poll log
│   └── logs/                    <- raw logs for the two excluded P3-full anomaly runs
│       ├── anomaly_runs_manifest.csv
│       └── cnpg_p3-full_rep005_..., cnpg_p3-full_rep013_...
└── analysis/
    ├── requirements.txt
    ├── analyze_p3_tiers.py      <- disaggregates P3/P3-full write attempts by degradation tier
    └── stats_corrected.py       <- reproduces every statistic in the revised paper (Section 4):
                                    rule-of-three RPO bound, P1-full/P2-full censored comparison,
                                    tier-level Wilson CIs, P3-full exclusion sensitivity analysis
```

## Status of this repository

- [x] Real per-run measurement data for all seven scenarios (n=40 per
      scenario; n=57 for P3-full, of which 2 are flagged anomalies
      documented in `data/logs/`)
- [x] Analysis scripts reproduce every number reported in the revised
      manuscript (Section 4) -- see Quick start below
- [ ] `environment/versions.txt` still needs the exact software
      versions used (kind, Kubernetes, PostgreSQL patch version) --
      author action required, see TODOs in that file
- [ ] Zenodo DOI to be minted upon acceptance

## Quick start

```bash
pip install -r analysis/requirements.txt

# Reproduces RTO/RPO/unavailability stats, the P1-full vs P2-full
# censored comparison, the P3-full tier-level failure rates (Table 2
# of the paper), and the P3-full exclusion sensitivity analysis.
python analysis/stats_corrected.py data/raw/
```

## Data schema

### `data/raw/summary.csv` (one row per run, all scenarios)

```
run_id, system, scenario, rep, failover_detected, rto_s,
write_downtime_s, total_fail_duration_s, rpo_rows_lost, notes
```

`notes` is non-empty only for the two flagged P3-full anomaly runs
(`BASCULE_INATTENDUE_SUR_SCENARIO_FULL` for the unexpected primary
failover, `ROW_COUNT_ECHEC` for the row-count verification failure --
see paper Section 4.4).

### `data/raw/<scenario>/manifest.csv` (one row per run, per scenario)

```
run_id, system, scenario, rep, t_baseline_start_unix, t_inject_unix,
t_heal_unix, t_run_end_unix, role_log, writer_log,
count_before, max_id_before, rows_surviving,  <- kill and p3-full only
notes
```

`count_before` / `max_id_before` / `rows_surviving` implement the
row-identifier-threshold RPO verification described in the paper
(Section 3.6, Correction 3). Note the documented coverage gap
(Correction 6): the threshold is captured 10-11s before fault
injection, not immediately before, so writes acknowledged in that
window are not covered by the survival check.

### `*.writer.csv` (one row per write attempt)

```
t_start, t_end, status   # status is "ok" or "fail"
```

### `*.role.csv` (replication-state poll log)

One row per poll of `pg_is_in_recovery()` and current/replayed LSN per
instance; used to compute RTO and to detect failover events.

## License

Code in this repository is released under the MIT License (see
`LICENSE`). The dataset under `data/raw/` and `data/logs/` is released
under CC-BY-4.0 -- see `NOTICE`.

## Citation

See `CITATION.cff`. Please cite the paper above if you use this code
or data.
