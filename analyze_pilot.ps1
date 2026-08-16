<#
==============================================================================
 analyze_pilot.ps1 -- Analyse par fenetre temporelle du CSV du pilote
==============================================================================
 Objectif : le rapport agrege ("report") melange baseline / P1 / accalmie /
 P2 / P3 et peut masquer un vrai signal de panne derriere du bruit constant.
 Ce script decoupe le CSV par fenetre (en utilisant les horodatages ISO
 affiches par inject-p1/p2/p3 pendant votre run) et calcule le taux de
 timeout PAR DIRECTION ET PAR FENETRE.

 Les timestamps par defaut ci-dessous sont ceux de VOTRE run du 2026-08-01.
 Si vous relancez le pilote, remplacez les valeurs dans $Windows par les
 nouveaux horodatages affiches par le script principal.

 Usage : .\analyze_pilot.ps1
         .\analyze_pilot.ps1 -CsvPath "chemin\vers\probes.csv"
==============================================================================
#>

param(
    [string]$CsvPath = ".\pilot_logs\probes.csv"
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV introuvable: $CsvPath"
    exit 1
}

function ToUnix([string]$iso) {
    ([DateTimeOffset]::Parse($iso)).ToUnixTimeSeconds()
}

# Fenetres tirees de votre run (ajustez si vous relancez le pilote) :
$Windows = @(
    @{ Name = "baseline (20s avant P1)";  Start = (ToUnix "2026-08-03T21:55:44.5371674+01:00") - 20; End = (ToUnix "2026-08-03T21:55:44.5371674+01:00") }
    @{ Name = "P1 (partition symetrique)"; Start = (ToUnix "2026-08-03T21:55:44.5371674+01:00"); End = (ToUnix "2026-08-03T21:56:16.8779057+01:00") }
    @{ Name = "accalmie apres P1";         Start = (ToUnix "2026-08-03T21:56:16.8779057+01:00"); End = (ToUnix "2026-08-03T21:56:38.0647880+01:00") }
    @{ Name = "P2 (partition asymetrique)";Start = (ToUnix "2026-08-03T21:56:38.0647880+01:00"); End = (ToUnix "2026-08-03T21:57:11.0313098+01:00") }
    @{ Name = "accalmie apres P2";         Start = (ToUnix "2026-08-03T21:57:11.0313098+01:00"); End = (ToUnix "2026-08-03T21:57:31.4522238+01:00") }
    @{ Name = "P3 (degradation graduee)";  Start = (ToUnix "2026-08-03T21:57:31.4522238+01:00"); End = (ToUnix "2026-08-03T21:58:34.3029451+01:00") }
    @{ Name = "apres heal final";          Start = (ToUnix "2026-08-03T21:58:34.3029451+01:00"); End = [double]::MaxValue }
)

$rows = Import-Csv -Path $CsvPath | ForEach-Object {
    # busybox `date` ne supporte pas %N (nanosecondes) -- il ecrit "%N" litteralement,
    # ex: "1785697864.%N". On ne garde que la partie entiere (secondes), suffisante
    # pour un decoupage par fenetre a la seconde pres.
    $tsInt = ($_.timestamp -split '\.')[0]
    $_ | Add-Member -NotePropertyName "ts_d" -NotePropertyValue ([double]$tsInt) -PassThru
}

foreach ($w in $Windows) {
    Write-Host ""
    Write-Host "=== $($w.Name) ===" -ForegroundColor Cyan
    $durationSec = $w.End - $w.Start
    $inWindow = $rows | Where-Object { $_.ts_d -ge $w.Start -and $_.ts_d -lt $w.End }
    if ($inWindow.Count -eq 0) {
        Write-Host "  (aucun message recu dans cette fenetre)"
        continue
    }
    $inWindow | Group-Object direction | Sort-Object Name | ForEach-Object {
        $count = $_.Count
        $rate = if ($durationSec -gt 0 -and $durationSec -lt [double]::MaxValue) { [math]::Round($count / $durationSec, 2) } else { $null }
        if ($null -ne $rate) {
            "{0,-25} {1,4} messages  ({2} msg/s)" -f $_.Name, $count, $rate
        } else {
            "{0,-25} {1,4} messages" -f $_.Name, $count
        }
    }
}

Write-Host ""
Write-Host "Ce qu'il faut regarder :" -ForegroundColor Yellow
Write-Host "  - baseline : notez le debit normal (msg/s) de chaque direction, c'est"
Write-Host "    votre reference."
Write-Host "  - P2 : replica-a->primary doit chuter fortement (proche de 0 msg/s)."
Write-Host "    primary->replica-a doit rester proche de son debit de baseline --"
Write-Host "    c'est la comparaison qui tranche le GO/NO-GO (contrairement au ping,"
Write-Host "    l'UDP one-way ne peut plus etre fausse par le sens retour bloque)."
