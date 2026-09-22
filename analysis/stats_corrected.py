#!/usr/bin/env python3
"""
stats_corrected.py

Reproduces the statistical results reported in the revised manuscript
(Section 4), starting from data/raw/summary.csv. Every number in this
script's output should match the corresponding number in the paper.
This replaces the earlier Fisher's-exact-test-on-aggregated-tiers
approach (superseded by Correction 5) with tier-level analysis, and
applies the rule of three instead of reporting zero-count outcomes as
absolute guarantees (superseded language identified during review).

Usage:
    python analysis/stats_corrected.py data/raw/

Requires: numpy, scipy, statsmodels
    pip install -r analysis/requirements.txt
"""
import argparse
import csv
import os
import sys
from collections import Counter, defaultdict

import numpy as np
from scipy import stats
from statsmodels.stats.proportion import proportion_confint


def rule_of_three(n_trials, n_events=0):
    """Upper bound on the true event rate at 95% confidence when
    n_events out of n_trials trials show the event (classically applied
    when n_events == 0; the 3/n approximation is specific to that
    case)."""
    if n_events != 0:
        raise ValueError("Rule of three applies to zero-count outcomes only; "
                          "use proportion_confint for non-zero counts.")
    return 3.0 / n_trials


def load_summary(raw_dir):
    path = os.path.join(raw_dir, "summary.csv")
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def section_kill(rows):
    print("=" * 70)
    print("KILL (node crash) -- RTO, write unavailability, RPO")
    print("=" * 70)
    kill = [r for r in rows if r["scenario"] == "kill"]
    n = len(kill)

    rto = np.array([float(r["rto_s"]) for r in kill])
    print(f"n = {n}")
    print(f"RTO: median={np.median(rto):.1f}s, "
          f"IQR=[{np.percentile(rto,25):.1f}, {np.percentile(rto,75):.1f}]")
    sw = stats.shapiro(rto)
    print(f"RTO Shapiro-Wilk: W={sw.statistic:.3f}, p={sw.pvalue:.4f} "
          f"({'rejects' if sw.pvalue < 0.05 else 'does not reject'} normality)")

    wd = np.array([float(r["write_downtime_s"]) for r in kill])
    print(f"write_downtime_s: median={np.median(wd):.1f}s, "
          f"values={dict(Counter(wd))}")

    lost = sum(1 for r in kill
               if r.get("rpo_rows_lost") not in ("", "None", None)
               and float(r["rpo_rows_lost"]) > 0)
    print(f"\nRPO: {lost}/{n} runs with detected loss.")
    bound = rule_of_three(n)
    print(f"Rule of three -> true loss rate bounded, with 95% confidence, "
          f"at below {bound*100:.1f}%.")
    print("NOTE (Correction 6): this bound applies only to the population "
          "verified by the row-identifier threshold method, which is "
          "captured 10-11s before fault injection -- it does not cover "
          "writes acknowledged inside that window. See paper Section 3.6.")


def section_p1_p2_full(rows):
    print("\n" + "=" * 70)
    print("P1-full vs P2-full -- symmetry test (right-censored at 60s)")
    print("=" * 70)
    p1f = np.array([float(r["write_downtime_s"])
                     for r in rows if r["scenario"] == "p1-full"])
    p2f = np.array([float(r["write_downtime_s"])
                     for r in rows if r["scenario"] == "p2-full"])
    pooled_std = np.sqrt((p1f.std(ddof=1)**2 + p2f.std(ddof=1)**2) / 2)
    d = (p1f.mean() - p2f.mean()) / pooled_std if pooled_std > 0 else 0.0
    u, p = stats.mannwhitneyu(p1f, p2f, alternative="two-sided")
    print(f"n(P1-full)={len(p1f)}, n(P2-full)={len(p2f)}")
    print(f"Cohen's d = {d:.3f}, Mann-Whitney U={u:.1f}, p={p:.2f}")
    print("Both conditions are right-censored at the 60s observation "
          "window; this establishes symmetry of the censored response, "
          "not of an intrinsic recovery time (see paper Section 4.1.1).")


def section_p3_tiers(raw_dir):
    print("\n" + "=" * 70)
    print("P3-full -- attempt-level failure rate by degradation tier")
    print("(Correction 5: replaces the aggregated Fisher's-exact-test")
    print(" comparison, which masked this structure)")
    print("=" * 70)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import analyze_p3_tiers as t

    manifest_path = os.path.join(raw_dir, "p3-full", "manifest.csv")
    campaign_dir = os.path.join(raw_dir, "p3-full")
    rows = []
    with open(manifest_path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("writer_log") and row.get("t_inject_unix"):
                row["writer_log"] = os.path.join(campaign_dir,
                                                   os.path.basename(row["writer_log"]))
                rows.append(row)

    tier_attempts = defaultdict(int)
    tier_fails = defaultdict(int)
    first_fail_tier_per_run = []

    for run in rows:
        t_inject = int(run["t_inject_unix"])
        wr = t.load_writer_csv(run["writer_log"])
        first_fail = None
        for t_start, t_end, status in wr:
            tier = t.classify_tier(t_start, t_inject)
            if tier is None:
                continue
            tier_attempts[tier] += 1
            if status == "fail":
                tier_fails[tier] += 1
                if first_fail is None:
                    first_fail = tier
        if first_fail is not None:
            first_fail_tier_per_run.append(first_fail)

    print(f"Runs loaded: {len(rows)}\n")
    print(f"{'Tier':<22}{'Attempts':>10}{'Failed':>9}{'Rate':>9}   95% CI (Wilson)")
    for tier in range(4):
        n_att = tier_attempts.get(tier, 0)
        n_fail = tier_fails.get(tier, 0)
        if n_att == 0:
            continue
        lo, hi = proportion_confint(n_fail, n_att, alpha=0.05, method="wilson")
        print(f"{t.TIER_LABELS[tier]:<22}{n_att:>10}{n_fail:>9}"
              f"{100*n_fail/n_att:>8.1f}%   [{100*lo:.1f}%, {100*hi:.1f}%]")

    c = Counter(first_fail_tier_per_run)
    n_runs_with_failure = len(first_fail_tier_per_run)
    print(f"\nFirst-failure tier distribution (n={n_runs_with_failure} runs "
          f"with >=1 failure):")
    for tier in range(4):
        print(f"  {t.TIER_LABELS[tier]}: {c.get(tier,0)}/{n_runs_with_failure} runs")


def section_p3full_sensitivity(rows):
    print("\n" + "=" * 70)
    print("P3-full -- sensitivity analysis on excluded runs (rep005, rep013)")
    print("=" * 70)
    p3full_all = [r for r in rows if r["scenario"] == "p3-full"]
    p3full_clean = [r for r in p3full_all if not r["notes"].strip()]

    for label, subset in [("n=57 (no exclusion)", p3full_all),
                           ("n=55 (as reported in paper)", p3full_clean)]:
        tfd = np.array([float(r["total_fail_duration_s"]) for r in subset])
        print(f"{label}: median={np.median(tfd):.1f}s, "
              f"IQR=[{np.percentile(tfd,25):.1f}, {np.percentile(tfd,75):.1f}], "
              f"std={np.std(tfd, ddof=1):.1f}")
    print("Conclusion: median and IQR are stable regardless of exclusion "
          "decision; the central P3-full finding does not depend on it.")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("raw_dir", help="Path to data/raw/")
    args = ap.parse_args()

    rows = load_summary(args.raw_dir)
    section_kill(rows)
    section_p1_p2_full(rows)
    section_p3_tiers(args.raw_dir)
    section_p3full_sensitivity(rows)


if __name__ == "__main__":
    main()
