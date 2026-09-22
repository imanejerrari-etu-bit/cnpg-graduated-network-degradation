<#
==============================================================================
 merge_summary.ps1 -- Fusionne les campagnes CNPG en un summary final.
==============================================================================
 Source A (results_cnpg_ancien_format_20260808) : campagne complete n=40 sur
   p1/p1-full/p2/p2-full/p3, ancien calcul RPO (rpo_lsn_gap, invalide --
   contamine par l'artefact de changement de timeline) et SANS la colonne
   total_fail_duration_s (ajoutee apres coup). On garde TOUT SAUF "kill" de ce
   fichier -- p3 (simple) y reste valide, RPO non calcule de toute facon pour
   ces scenarios (pas de bascule).
 Source B (results_cnpg, dossier courant) : "kill" (n=40, RPO corrige) et
   "p3-full" (n=57, nouveau scenario, avec total_fail_duration_s). On garde
   ces deux scenarios de ce fichier.

 Sortie : results_final\summary.csv -- pret pour analyze_stats.py.
==============================================================================
#>

$srcOld = "results_cnpg_ancien_format_20260808\summary.csv"
$srcNew = "results_cnpg\summary.csv"
$outDir = "results_final"
$outCsv = Join-Path $outDir "summary.csv"

if (-not (Test-Path $srcOld)) { Write-Error "Introuvable : $srcOld"; exit 1 }
if (-not (Test-Path $srcNew)) { Write-Error "Introuvable : $srcNew"; exit 1 }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$fromOld = Import-Csv $srcOld | Where-Object { $_.scenario -ne "kill" } | ForEach-Object {
    [PSCustomObject]@{
        run_id                = $_.run_id
        system                = $_.system
        scenario              = $_.scenario
        rep                   = $_.rep
        failover_detected     = $_.failover_detected
        rto_s                 = $_.rto_s
        write_downtime_s      = $_.write_downtime_s
        total_fail_duration_s = ""   # n'existait pas au moment de cette campagne -- absent, pas zero
        rpo_rows_lost         = $_.rpo_lsn_gap   # vide de toute facon pour ces scenarios -- simple renommage
        notes                 = $_.notes
    }
}

$fromNew = Import-Csv $srcNew | Where-Object { $_.scenario -eq "kill" -or $_.scenario -eq "p3-full" }

$combined = @($fromOld) + @($fromNew)
$combined | Export-Csv -Path $outCsv -NoTypeInformation

Write-Host "[merge_summary] $($fromOld.Count) lignes (hors kill) depuis $srcOld"
Write-Host "[merge_summary] $($fromNew.Count) lignes (kill + p3-full) depuis $srcNew"
Write-Host "[merge_summary] Total : $($combined.Count) lignes -> $outCsv"
Write-Host ""
Write-Host "[merge_summary] Repartition par scenario :"
$combined | Group-Object scenario | ForEach-Object {
    $notesCount = ($_.Group | Where-Object { $_.notes -ne "" }).Count
    Write-Host ("  {0,-10} n={1,-4} avec_notes={2}" -f $_.Name, $_.Count, $notesCount)
}
