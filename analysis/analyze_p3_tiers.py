#!/usr/bin/env python3
"""
analyze_p3_tiers.py -- Reconstruit la latence de commit et le taux d'echec par
PALIER pour le scenario P3 (degradation graduee), a partir des writer.csv deja
archives -- sans ré-instrumentation.

Motivation : write_downtime_s (metrique binaire ok/fail par tentative) donne
une mediane a 0s sur P3 (cf. brouillon section 2.1 : "une metrique de latence
de commit continue serait plus informative pour ce regime"). Cette information
existe DEJA dans writer.csv (t_start/t_end par tentative) -- il suffit de la
ventiler par palier (P3 = 4 paliers de 15s pile, sequentiels, a partir de
t_inject) plutot que de la regarder en bloc.

Usage :
    python3 analyze_p3_tiers.py <dossier_campagne_ancien_format> [--out rapport.md]

    Le dossier doit contenir manifest.csv (avec t_inject_unix et writer_log)
    et les .writer.csv archives pour scenario=p3.

[A VERIFIER AVANT PUBLICATION]
    - Granularite de mesure : writer.sh utilise `date +%s` (resolution 1
      seconde). Les paliers 1-2 (retard ajoute 50-150ms) sont probablement
      INVISIBLES a cette granularite -- une latence de 20-150ms s'arrondit a
      0s. Seuls les paliers 3-4 (400-800ms, proches ou depassant 1s cumule
      avec la latence reseau normale) ont une chance d'etre visibles. Si ce
      script montre une latence quasi-nulle sur TOUS les paliers y compris le
      4eme, c'est le signe qu'il FAUT re-instrumenter avec une resolution
      sub-seconde (`date +%s.%N`) plutot que conclure a l'absence d'effet.
    - Le taux d'echec par palier reste fiable independamment de cette
      limitation (un echec est un echec, peu importe la resolution du chrono).
"""

import sys
import argparse
import os
import csv
from collections import defaultdict
import numpy as np

TIER_SECONDS = 15  # duree de chaque palier P3
N_TIERS = 4
TIER_LABELS = ["Tier 1 (50ms/0%)", "Tier 2 (150ms/2%)", "Tier 3 (400ms/5%)", "Tier 4 (800ms/15%)"]


def load_manifest(campaign_dir):
    path = os.path.join(campaign_dir, "manifest.csv")
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("scenario") == "p3" and row.get("writer_log") and row.get("t_inject_unix"):
                # Le manifeste stocke un chemin ABSOLU capture au moment de la
                # campagne -- s'il a ete renomme depuis (constate en pratique :
                # results_cnpg -> results_cnpg_ancien_format_...), ce chemin ne
                # pointe plus vers rien. On ne garde que le NOM du fichier et on
                # le resout contre le dossier reellement fourni en argument.
                row["writer_log"] = os.path.join(campaign_dir, os.path.basename(row["writer_log"]))
                rows.append(row)
    return rows


def load_writer_csv(path):
    if not path or not os.path.exists(path):
        return []
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            try:
                rows.append((int(row["t_start"]), int(row["t_end"]), row["status"]))
            except (KeyError, ValueError):
                continue
    return rows


def classify_tier(t_start, t_inject):
    offset = t_start - t_inject
    if offset < 0 or offset >= N_TIERS * TIER_SECONDS:
        return None  # avant injection ou apres la fin des 4 paliers (recuperation)
    return int(offset // TIER_SECONDS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("campaign_dir")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    manifest = load_manifest(args.campaign_dir)
    if not manifest:
        print(f"Aucun run P3 trouve dans {args.campaign_dir}/manifest.csv", file=sys.stderr)
        sys.exit(1)

    tier_latencies = defaultdict(list)   # tier -> [duree en s, ...] (attempts ok uniquement)
    tier_attempts = defaultdict(int)
    tier_fails = defaultdict(int)
    runs_used = 0
    runs_skipped = 0

    for run in manifest:
        t_inject = int(run["t_inject_unix"])
        writer_rows = load_writer_csv(run["writer_log"])
        if not writer_rows:
            runs_skipped += 1
            continue
        runs_used += 1
        for t_start, t_end, status in writer_rows:
            tier = classify_tier(t_start, t_inject)
            if tier is None:
                continue
            tier_attempts[tier] += 1
            if status == "fail":
                tier_fails[tier] += 1
            else:
                tier_latencies[tier].append(t_end - t_start)

    lines = ["# Analyse P3 par palier -- latence de commit et taux d'echec\n"]
    lines.append(f"Source : `{args.campaign_dir}`  \n"
                  f"Runs P3 utilises : {runs_used} (ecartes/logs manquants : {runs_skipped})\n")

    for tier in range(N_TIERS):
        n = tier_attempts.get(tier, 0)
        nfail = tier_fails.get(tier, 0)
        lat = tier_latencies.get(tier, [])
        lines.append(f"\n## {TIER_LABELS[tier]}\n")
        if n == 0:
            lines.append("- Aucune tentative capturee dans cette fenetre.\n")
            continue
        fail_rate = nfail / n
        lines.append(f"- Tentatives : {n} (cumulees sur {runs_used} runs), echecs : {nfail} ({fail_rate:.1%})")
        if lat:
            lat_arr = np.array(lat)
            lines.append(f"- Latence des tentatives reussies (resolution 1s) : "
                         f"mediane={np.median(lat_arr):.0f}s, "
                         f"moyenne={np.mean(lat_arr):.2f}s, "
                         f"max={np.max(lat_arr):.0f}s, "
                         f"% a 0s (arrondi)={100*np.mean(lat_arr == 0):.0f}%")
        else:
            lines.append("- Aucune tentative reussie dans cette fenetre (100% d'echec).")

    # Alerte automatique si la granularite semble avoir tout aplati
    all_lat = [v for tier_list in tier_latencies.values() for v in tier_list]
    if all_lat and np.mean(np.array(all_lat) == 0) > 0.95:
        lines.append("\n## ATTENTION\n")
        lines.append(">95% des tentatives reussies affichent une latence de 0s (arrondie) sur "
                      "TOUS les paliers -- la resolution 1 seconde de `date +%s` masque "
                      "probablement l'effet reel de la degradation en latence. Le taux "
                      "d'echec par palier ci-dessus reste fiable, mais pour une courbe de "
                      "latence exploitable il faudra re-instrumenter writer.sh avec "
                      "`date +%s.%N` (resolution sub-seconde) et relancer P3.\n")

    report = "\n".join(lines)
    print(report)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"\n[analyze_p3_tiers] Rapport ecrit dans {args.out}")


if __name__ == "__main__":
    main()
