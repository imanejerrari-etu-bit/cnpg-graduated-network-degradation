#!/usr/bin/env python3
"""
analyze_stats.py -- Analyse statistique standard (Shapiro-Wilk, bootstrap BCa,
Cohen's d) sur le summary.csv produit par analyze_run.ps1.

Usage :
    python3 analyze_stats.py results_cnpg/summary.csv
    python3 analyze_stats.py results_cnpg/summary.csv --out results_cnpg/stats_report.md

Produit :
    - Un rapport lisible (stdout, et en Markdown si --out est fourni)
    - Pour chaque scenario : n, moyenne, mediane, ecart-type, IQR,
      Shapiro-Wilk (normalite), intervalle de confiance bootstrap BCa (95%)
      sur la mediane.
    - Comparaisons par paires (Cohen's d) definies dans COMPARISONS ci-dessous
      -- a adapter selon les hypotheses de ton papier.

[A VERIFIER AVANT PUBLICATION]
    - Le bootstrap BCa echoue ou degenere sur des donnees constantes (ex: p1/p2
      avec 40 zeros) -- c'est signale explicitement dans le rapport, pas une
      erreur du script. Un scenario a variance nulle n'a simplement pas besoin
      d'IC bootstrap (la valeur EST 0, point).
    - Shapiro-Wilk sur des donnees tres discretes/a fort effet de plancher
      (beaucoup de zeros, ex: p3) va quasi-systematiquement rejeter la
      normalite -- c'est attendu, pas un signe d'erreur. Pour ce type de
      distribution, la mediane + IQR est plus informative que moyenne + ecart-type,
      et un test non-parametrique (Mann-Whitney) est plus approprie qu'un test-t
      pour les comparaisons.
    - Pour p3 specifiquement, la metrique write_downtime_s binaire (fail/ok par
      tentative) risque d'etre peu informative par nature (cf. brouillon,
      section 2.1 -- "une metrique de latence de commit continue serait plus
      informative"). Ce script calcule ce qu'il peut avec les donnees
      disponibles, mais ne remplace pas une re-instrumentation de P3 si tu
      decides d'en avoir besoin.
"""

import sys
import argparse
import warnings
import numpy as np
import pandas as pd
from scipy import stats

# Le cas BCa degenere (median, donnees a fort effet de plancher) est deja
# detecte et gere explicitement via repli percentile -- on n'a pas besoin que
# scipy imprime un warning a chaque occurrence.
warnings.filterwarnings("ignore", category=RuntimeWarning, module="scipy")
warnings.filterwarnings("ignore", message=".*BCa confidence interval.*")

N_RESAMPLES = 9999
CONFIDENCE = 0.95
RNG_SEED = 12345

# Comparaisons par paires a rapporter (Cohen's d). Adapte cette liste aux
# hypotheses reelles de ton papier -- ex: verifier la symetrie P1-full/P2-full,
# ou comparer un jour CNPG vs Patroni sur le meme scenario.
COMPARISONS = [
    ("p1-full", "p2-full", "write_downtime_s"),
    ("p1", "p2", "write_downtime_s"),
]


def clean_numeric(series):
    """Convertit en numerique, retire les valeurs manquantes/vides."""
    s = pd.to_numeric(series, errors="coerce")
    return s.dropna().to_numpy(dtype=float)


def cohens_d(x, y):
    """Cohen's d avec ecart-type combine (pooled), pour deux echantillons independants."""
    nx, ny = len(x), len(y)
    if nx < 2 or ny < 2:
        return None
    vx, vy = np.var(x, ddof=1), np.var(y, ddof=1)
    pooled_sd = np.sqrt(((nx - 1) * vx + (ny - 1) * vy) / (nx + ny - 2))
    if pooled_sd == 0:
        return 0.0 if np.mean(x) == np.mean(y) else float("inf")
    return (np.mean(x) - np.mean(y)) / pooled_sd


def bootstrap_bca_median(data):
    """IC bootstrap BCa (95%) sur la mediane. Renvoie (low, high) ou None si non calculable."""
    if len(data) < 3 or np.all(data == data[0]):
        return None  # donnees constantes ou trop peu nombreuses : BCa non defini

    def _try(method):
        res = stats.bootstrap(
            (data,), np.median, method=method,
            confidence_level=CONFIDENCE, n_resamples=N_RESAMPLES,
            random_state=RNG_SEED,
        )
        lo, hi = res.confidence_interval.low, res.confidence_interval.high
        if np.isnan(lo) or np.isnan(hi):
            return None
        return (lo, hi)

    try:
        r = _try("BCa")
        if r is not None:
            return (r[0], r[1], "BCa")
    except Exception:
        pass
    # BCa degenere frequemment sur la mediane (statistique non lisse, beaucoup
    # de ties) -- scipy renvoie alors NaN SANS lever d'exception. Repli
    # systematique sur percentile, moins precis mais robuste dans ce cas.
    try:
        r = _try("percentile")
        if r is not None:
            return (r[0], r[1], "percentile (repli, BCa degenere)")
    except Exception:
        pass
    return None


def shapiro_report(data):
    """Shapiro-Wilk. Renvoie (W, p) ou None si non applicable (n<3 ou constant)."""
    if len(data) < 3 or np.all(data == data[0]):
        return None
    try:
        w, p = stats.shapiro(data)
        return (w, p)
    except Exception:
        return None


def describe_scenario(df, scenario, metric):
    sub = df[df["scenario"] == scenario]
    data = clean_numeric(sub[metric])
    n = len(data)
    if n == 0:
        return None

    mean = np.mean(data)
    median = np.median(data)
    std = np.std(data, ddof=1) if n > 1 else 0.0
    q1, q3 = np.percentile(data, [25, 75])
    iqr = q3 - q1

    sh = shapiro_report(data)
    ci = bootstrap_bca_median(data)

    return {
        "scenario": scenario, "metric": metric, "n": n,
        "mean": mean, "median": median, "std": std, "iqr": iqr,
        "shapiro_W": sh[0] if sh else None,
        "shapiro_p": sh[1] if sh else None,
        "ci95_low": ci[0] if ci else None,
        "ci95_high": ci[1] if ci else None,
        "ci95_method": ci[2] if ci else None,
        "constant_data": bool(np.all(data == data[0])) if n > 0 else None,
    }


def format_row(r):
    lines = [f"### {r['scenario']} -- {r['metric']} (n={r['n']})"]
    lines.append(f"- Moyenne = {r['mean']:.2f}, Mediane = {r['median']:.2f}, "
                  f"Ecart-type = {r['std']:.2f}, IQR = {r['iqr']:.2f}")
    if r["constant_data"]:
        lines.append("- Donnees constantes (variance nulle) -- pas de test de normalite "
                      "ni d'IC bootstrap applicable, ce n'est pas une erreur.")
    else:
        if r["shapiro_p"] is not None:
            verdict = "normalite rejetee" if r["shapiro_p"] < 0.05 else "normalite non rejetee"
            lines.append(f"- Shapiro-Wilk : W={r['shapiro_W']:.4f}, p={r['shapiro_p']:.4f} ({verdict})")
        if r["ci95_low"] is not None:
            lines.append(f"- IC bootstrap 95% (mediane, methode={r['ci95_method']}) : "
                          f"[{r['ci95_low']:.2f}, {r['ci95_high']:.2f}]")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_path")
    ap.add_argument("--out", default=None, help="Chemin du rapport Markdown (optionnel)")
    args = ap.parse_args()

    df_raw = pd.read_csv(args.csv_path)
    n_total = len(df_raw)
    # Convention deja etablie dans analyze_run.ps1 : une note non vide signale
    # un run a inspecter manuellement (log manquant, anomalie type bascule
    # inattendue sur un scenario "-full", etc.) -- on les exclut des stats
    # plutot que de les laisser polluer silencieusement moyennes/medianes.
    has_notes = df_raw["notes"].notna() & (df_raw["notes"].astype(str).str.strip() != "")
    df = df_raw[~has_notes].copy()
    n_excluded = has_notes.sum()
    scenarios = df["scenario"].unique().tolist()

    report_lines = ["# Rapport d'analyse statistique\n"]
    report_lines.append(f"Source : `{args.csv_path}`  \n"
                         f"Scenarios : {', '.join(scenarios)}\n")
    if n_excluded > 0:
        report_lines.append(f"**{n_excluded}/{n_total} runs exclus** (colonne `notes` non vide -- "
                             f"logs manquants, anomalies signalees). Voir le CSV source pour le detail.\n")

    # --- write_downtime_s pour tous les scenarios ---
    report_lines.append("## write_downtime_s par scenario\n")
    for scenario in scenarios:
        r = describe_scenario(df, scenario, "write_downtime_s")
        if r:
            report_lines.append(format_row(r) + "\n")

    # --- total_fail_duration_s : metrique complementaire, uniquement pour les
    # scenarios ou elle est renseignee (absente des campagnes anterieures a
    # son introduction -- cf. merge_summary.ps1). Plus fiable que
    # write_downtime_s pour un scenario a pannes en plusieurs episodes (ex.
    # p3-full, ou write_downtime_s ne capture que le premier episode).
    has_total_fail = "total_fail_duration_s" in df.columns and clean_numeric(df["total_fail_duration_s"]).size > 0
    if has_total_fail:
        report_lines.append("## total_fail_duration_s par scenario (metrique complementaire)\n")
        report_lines.append("Somme des durees de TOUTES les tentatives en echec apres l'injection, "
                             "peu importe leur regroupement en un ou plusieurs episodes. A comparer a "
                             "write_downtime_s ci-dessus : un ecart important indique une panne en "
                             "plusieurs episodes (write_downtime_s sous-estime alors la vraie duree "
                             "d'indisponibilite).\n")
        for scenario in scenarios:
            r = describe_scenario(df, scenario, "total_fail_duration_s")
            if r:
                report_lines.append(format_row(r) + "\n")

    # --- rto_s et rpo_rows_lost pour les scenarios avec bascule ---
    failover_scenarios = df[df["failover_detected"] == True]["scenario"].unique().tolist()
    if failover_scenarios:
        report_lines.append("## rto_s (scenarios avec bascule detectee)\n")
        for scenario in failover_scenarios:
            r = describe_scenario(df[df["failover_detected"] == True], scenario, "rto_s")
            if r:
                report_lines.append(format_row(r) + "\n")

        report_lines.append("## rpo_rows_lost (scenarios avec bascule detectee)\n")
        for scenario in failover_scenarios:
            r = describe_scenario(df[df["failover_detected"] == True], scenario, "rpo_rows_lost")
            if r:
                report_lines.append(format_row(r) + "\n")

    # --- Comparaisons par paires (Cohen's d) ---
    report_lines.append("## Comparaisons par paires (Cohen's d)\n")
    for scen_a, scen_b, metric in COMPARISONS:
        if scen_a not in scenarios or scen_b not in scenarios:
            continue
        a = clean_numeric(df[df["scenario"] == scen_a][metric])
        b = clean_numeric(df[df["scenario"] == scen_b][metric])
        d = cohens_d(a, b)
        if d is None:
            report_lines.append(f"- {scen_a} vs {scen_b} ({metric}) : n insuffisant\n")
            continue
        magnitude = (
            "negligeable" if abs(d) < 0.2 else
            "petit" if abs(d) < 0.5 else
            "moyen" if abs(d) < 0.8 else
            "grand"
        )
        # Mann-Whitney en complement -- plus robuste que le test-t si non-normal
        try:
            u_stat, u_p = stats.mannwhitneyu(a, b, alternative="two-sided")
            mw_txt = f", Mann-Whitney U p={u_p:.4f}"
        except Exception:
            mw_txt = ""
        report_lines.append(
            f"- **{scen_a} vs {scen_b}** ({metric}) : Cohen's d = {d:.3f} ({magnitude}){mw_txt}\n"
        )

    report = "\n".join(report_lines)
    print(report)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"\n[analyze_stats] Rapport ecrit dans {args.out}")


if __name__ == "__main__":
    main()
