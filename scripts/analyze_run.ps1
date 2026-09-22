<#
==============================================================================
 analyze_run.ps1 -- Calcul automatique RTO / downtime / RPO
==============================================================================
 Lit results_<system>/manifest.csv (produit par run_campaign.ps1) et, pour
 chaque run, calcule a partir des CSV bruts archives :

   - failover_detected : un primaire DIFFERENT de celui d'avant l'injection
                          est-il apparu (colonne role.csv, is_in_recovery=f) ?
   - rto_s              : si failover, temps entre l'injection et la premiere
                           apparition du nouveau primaire (t_inject -> premiere
                           ligne is_in_recovery=f pour l'instance qui prend le
                           relais).
   - write_downtime_s   : temps entre le premier INSERT en echec APRES
                           l'injection, et la reprise d'une serie stable de
                           succes (writer_timed.csv). C'est cette metrique,
                           PAS rto_s, qui capture P1-full/P2-full/P3 (le
                           primaire ne change pas, CNPG bloque juste les
                           ecritures -- voir brouillon section 2.1).
   - rpo_rows_lost      : nombre de lignes, confirmees ou en cours au moment de
                           l'injection, disparues apres la bascule. Calcule a
                           partir de count_before/max_id_before/rows_surviving
                           (captures par run_campaign.ps1 via des requetes
                           SQL directes), PAS par difference de LSN brute --
                           cette derniere s'est averee contaminee par un
                           artefact de changement de timeline lors d'une
                           promotion (ecart quasi-constant de ~16 Mo observe,
                           soit la taille d'un segment WAL par defaut, sans
                           rapport avec une vraie perte).

 [A VERIFIER] Definitions a valider avec toi avant de faire confiance aux
 chiffres sur un grand nombre de runs :
   - "reprise stable" = -MinConsecutiveOk succes d'affilee (defaut 3), pour
     eviter qu'un succes isole au milieu d'une serie d'echecs soit compte
     comme la fin de l'indisponibilite. Augmente si tu vois des valeurs de
     downtime qui semblent trop courtes dans le detail par run.
   - Le "nouveau primaire" est detecte comme la premiere instance != ancien
     primaire a afficher is_in_recovery=f apres l'injection. Si aucune
     instance ne bascule (cas P1/P2/P1-full/P2-full/P3 observes dans le
     pilote), failover_detected=false et rto_s est vide -- c'est attendu,
     pas un bug.

 Usage :
   .\analyze_run.ps1 -System cnpg
   .\analyze_run.ps1 -System cnpg -MinConsecutiveOk 5
==============================================================================
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cnpg","patroni")]
    [string]$System,

    [int]$MinConsecutiveOk = 3
)

$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ResultsDir  = Join-Path $ScriptDir "results_$System"
$ManifestCsv = Join-Path $ResultsDir "manifest.csv"
$SummaryCsv  = Join-Path $ResultsDir "summary.csv"

if (-not (Test-Path $ManifestCsv)) {
    Write-Error "[analyze_run] Manifeste introuvable : $ManifestCsv (lance d'abord run_campaign.ps1)"
    exit 1
}

function Import-RoleCsv {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    return Import-Csv -Path $Path | ForEach-Object {
        [PSCustomObject]@{
            ts       = [int]$_.timestamp
            instance = $_.instance
            status   = $_.is_in_recovery   # "t" (replica), "f" (primaire), "unreachable"
            lsn      = $_.lsn
        }
    } | Sort-Object ts
}

function Import-WriterCsv {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return @() }
    return Import-Csv -Path $Path | ForEach-Object {
        [PSCustomObject]@{
            t_start = [int]$_.t_start
            t_end   = [int]$_.t_end
            status  = $_.status
        }
    } | Sort-Object t_start
}

function Get-PrimaryBefore {
    # Dernier instance vue avec is_in_recovery=f AVANT t_inject
    param([array]$RoleRows, [int]$TInject)
    $before = $RoleRows | Where-Object { $_.ts -lt $TInject -and $_.status -eq "f" } | Sort-Object ts
    if ($before.Count -eq 0) { return $null }
    return $before[-1].instance
}

function Get-Failover {
    # Premiere instance != oldPrimary a afficher is_in_recovery=f apres t_inject
    param([array]$RoleRows, [int]$TInject, [string]$OldPrimary)
    $after = $RoleRows | Where-Object { $_.ts -ge $TInject -and $_.status -eq "f" -and $_.instance -ne $OldPrimary } | Sort-Object ts
    if ($after.Count -eq 0) { return $null }
    return $after[0]   # objet avec ts, instance, lsn du nouveau primaire au moment de la bascule
}

function Get-WriteDowntime {
    param([array]$WriterRows, [int]$TInject, [int]$MinConsecutiveOk)
    $after = $WriterRows | Where-Object { $_.t_start -ge $TInject } | Sort-Object t_start

    # Metrique complementaire : somme des durees de TOUTES les tentatives en
    # echec apres l'injection, peu importe qu'elles forment un seul bloc
    # continu ou plusieurs episodes separes. write_downtime_s (ci-dessous) ne
    # capture que le PREMIER episode (du premier echec a la premiere serie
    # stable de succes) -- adapte a une panne continue (kill, P1-full,
    # P2-full), mais risque de sous-estimer fortement une panne en paliers
    # comme P3-full si un episode precoce et bref (palier a faible taux de
    # perte) est suivi d'une recuperation transitoire avant qu'un episode
    # plus severe (palier suivant) ne survienne plus tard dans le meme run.
    $totalFailDuration = 0
    foreach ($row in $after) {
        if ($row.status -eq "fail") { $totalFailDuration += ($row.t_end - $row.t_start) }
    }

    $firstFailIdx = -1
    for ($i = 0; $i -lt $after.Count; $i++) {
        if ($after[$i].status -eq "fail") { $firstFailIdx = $i; break }
    }
    if ($firstFailIdx -eq -1) {
        # AUCUN_ECHEC n'est PAS suspect en soi : c'est le resultat attendu pour
        # une isolation partielle (p1/p2, 1 seul replica isole) ou le quorum
        # synchrone reste satisfait par l'autre replica. On ne le met plus dans
        # 'notes' (qui doit signaler des runs a INSPECTER, pas des resultats
        # normaux) -- il reste visible via write_downtime_s=0.
        return @{ downtime = 0; totalFail = 0; notes = "" }
    }
    $failStart = $after[$firstFailIdx].t_start

    $consec = 0
    for ($i = $firstFailIdx; $i -lt $after.Count; $i++) {
        if ($after[$i].status -eq "ok") {
            $consec++
            if ($consec -ge $MinConsecutiveOk) {
                $recoveryStart = $after[$i - $MinConsecutiveOk + 1].t_start
                return @{ downtime = ($recoveryStart - $failStart); totalFail = $totalFailDuration; notes = "" }
            }
        } else {
            $consec = 0
        }
    }
    return @{ downtime = $null; totalFail = $totalFailDuration; notes = "PAS_DE_REPRISE_STABLE_DANS_LA_FENETRE_OBSERVEE" }
}

# ------------------------------------------------------------------------------
$manifest = Import-Csv -Path $ManifestCsv
$summaryRows = New-Object System.Collections.Generic.List[string]
$summaryRows.Add("run_id,system,scenario,rep,failover_detected,rto_s,write_downtime_s,total_fail_duration_s,rpo_rows_lost,notes")

foreach ($run in $manifest) {
    $notes = @()
    if ($run.notes) { $notes += $run.notes }

    $roleRows   = Import-RoleCsv -Path $run.role_log
    $writerRows = Import-WriterCsv -Path $run.writer_log
    $tInject    = [int]$run.t_inject_unix

    if ($roleRows.Count -eq 0)   { $notes += "ROLE_LOG_VIDE_OU_MANQUANT" }
    if ($writerRows.Count -eq 0) { $notes += "WRITER_LOG_VIDE_OU_MANQUANT" }

    $failoverDetected = $false
    $rtoS = ""

    if ($roleRows.Count -gt 0) {
        $oldPrimary = Get-PrimaryBefore -RoleRows $roleRows -TInject $tInject
        if (-not $oldPrimary) {
            $notes += "ANCIEN_PRIMAIRE_INTROUVABLE_AVANT_INJECTION"
        } else {
            $switch = Get-Failover -RoleRows $roleRows -TInject $tInject -OldPrimary $oldPrimary
            if ($switch) {
                $failoverDetected = $true
                $rtoS = $switch.ts - $tInject

                if ($run.scenario -match "-full$") {
                    # p1-full/p2-full/p3-full ne degradent QUE les replicas
                    # par design -- une bascule ici est structurellement
                    # inattendue (le primaire n'est jamais une cible directe).
                    # Cas reel rencontre : cnpg_p3-full_rep005_20260810_215528,
                    # primaire devenu "unreachable" pendant l'injection, cause
                    # exacte non elucidee retroactivement (topologie de noeud
                    # au moment du run non journalisee). A exclure des stats
                    # principales et signaler, pas a fusionner silencieusement.
                    $notes += "BASCULE_INATTENDUE_SUR_SCENARIO_FULL"
                }
            }
        }
    }

    # RPO base sur des lignes reellement presentes (count_before/max_id_before/
    # rows_surviving, captures par run_campaign.ps1), PAS sur une difference de
    # LSN brute -- cette derniere s'est averee contaminee par un artefact de
    # changement de timeline (~16 Mo constant observe sur la premiere
    # campagne, sans rapport avec une vraie perte). rows_surviving = combien de
    # lignes avec id <= max_id_before existent encore ; par construction cette
    # population ne peut que RETRECIR (jamais grandir), donc
    # count_before - rows_surviving >= 0 est directement le nombre de lignes
    # confirmees/en cours au moment de l'injection qui ont disparu.
    $rpoRowsLost = ""
    if ($run.count_before -match '^\d+$' -and $run.rows_surviving -match '^\d+$') {
        $rpoRowsLost = [int]$run.count_before - [int]$run.rows_surviving
        if ($rpoRowsLost -lt 0) {
            $notes += "RPO_INCOHERENT_SURVIVING_SUPERIEUR_A_BEFORE"
        }
    } elseif ($run.notes -notmatch "ROW_COUNT_ECHEC") {
        $notes += "RPO_DONNEES_MANQUANTES"
    }

    $downtimeResult = @{ downtime = ""; notes = "" }
    if ($writerRows.Count -gt 0) {
        $downtimeResult = Get-WriteDowntime -WriterRows $writerRows -TInject $tInject -MinConsecutiveOk $MinConsecutiveOk
        if ($downtimeResult.notes) { $notes += $downtimeResult.notes }
    }

    $notesStr = ($notes -join ";")
    $summaryRows.Add("$($run.run_id),$($run.system),$($run.scenario),$($run.rep),$failoverDetected,$rtoS,$($downtimeResult.downtime),$($downtimeResult.totalFail),$rpoRowsLost,$notesStr")
}

[System.IO.File]::WriteAllLines($SummaryCsv, $summaryRows)
Write-Host "[analyze_run] $($manifest.Count) runs analyses -> $SummaryCsv"
Write-Host ""
Write-Host "[analyze_run] Apercu par scenario :"
Import-Csv -Path $SummaryCsv | Group-Object scenario | ForEach-Object {
    $rtos = $_.Group | Where-Object { $_.rto_s -ne "" } | ForEach-Object { [double]$_.rto_s }
    $downs = $_.Group | Where-Object { $_.write_downtime_s -ne "" -and $_.write_downtime_s -ne $null } | ForEach-Object { [double]$_.write_downtime_s }
    $failCount = ($_.Group | Where-Object { $_.notes -ne "" }).Count
    Write-Host ("  {0,-10} n={1,-3} failover_rate={2:P0}  downtime_median={3}s  runs_avec_notes={4}" -f `
        $_.Name, $_.Count, `
        (($_.Group | Where-Object { $_.failover_detected -eq "True" }).Count / $_.Count), `
        $(if ($downs.Count -gt 0) { ($downs | Sort-Object)[[int]($downs.Count/2)] } else { "n/a" }), `
        $failCount)
}
Write-Host ""
Write-Host "[analyze_run] Colonne 'notes' non vide = a inspecter manuellement avant d'utiliser le run dans les stats finales."
