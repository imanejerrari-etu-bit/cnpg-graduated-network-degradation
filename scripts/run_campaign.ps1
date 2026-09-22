<#
==============================================================================
 run_campaign.ps1 -- Orchestrateur de campagne d'experiences
==============================================================================
 Boucle scenarios x repetitions par-dessus deploy_cnpg.ps1 (ou deploy_patroni.ps1
 une fois valide), et resout le probleme principal des scripts actuels : chaque
 probe-stop / writer-stop ECRASE role.csv / writer_timed.csv (fichier fixe, pas
 d'historique). Ici, chaque run est immediatement copie vers un dossier dedie
 et enregistre dans un manifeste CSV (results/manifest.csv) que analyze_run.ps1
 consomme ensuite.

 HYPOTHESES A VERIFIER AVANT DE LANCER UNE VRAIE CAMPAGNE (voir commentaires
 marques [A VERIFIER] ci-dessous) :
   - Le cluster N'EST PAS redeploye entre chaque run (reuse + heal + attente de
     stabilisation). C'est plus rapide pour n=30-50, mais ce n'est PAS une
     replication totalement independante (etat residuel possible d'un run a
     l'autre). Si tu veux l'independance stricte, mets -FreshClusterEachRun,
     mais prevois large (chaque deploy-cluster ~1-3 min).
   - Les fenetres d'attente (BaselineSeconds, PostInjectWaitSeconds,
     StabilizeSeconds) sont des valeurs de depart raisonnables au vu du
     pilote (RTO max observe ~34s), PAS des valeurs validees statistiquement.
     Ajuste-les si des runs se terminent avant que le systeme ait fini de
     reagir (verifiable dans les CSV archives : un writer_timed.csv qui finit
     encore en "fail" est un signe que PostInjectWaitSeconds est trop court).
   - Le scenario "kill" (panne franche) utilise `kubectl delete pod --force`
     directement ici (pas dans deploy_cnpg.ps1) -- a verifier une fois contre
     ton resultat pilote (~7s de RTO).

 Usage :
   .\run_campaign.ps1 -System cnpg -Scenarios p1,p1-full,p2,p2-full,p3,kill -Reps 30
   .\run_campaign.ps1 -System cnpg -Scenarios p3 -Reps 5 -FreshClusterEachRun
==============================================================================
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cnpg","patroni")]
    [string]$System,

    [Parameter(Mandatory = $true)]
    [string[]]$Scenarios,   # sous-ensemble de: p1, p1-full, p2, p2-full, p3, kill

    [Parameter(Mandatory = $true)]
    [int]$Reps,

    [int]$BaselineSeconds = 10,        # duree d'ecriture stable AVANT l'injection (capture le "avant")

    # [IMPORTANT -- CHOIX METHODOLOGIQUE, PAS UN DETAIL TECHNIQUE]
    # Pour les scenarios SANS bascule de primaire (p1-full, p2-full, et
    # probablement le palier severe de P3), CNPG bloque les ecritures
    # INDEFINIMENT tant que le quorum synchrone n'est pas restaure -- il n'y a
    # aucune borne systeme naturelle. Le "downtime" mesure par analyze_run.ps1
    # pour ces scenarios est donc mecaniquement egal a (PostInjectWaitSeconds -
    # delai de detection), PAS une propriete intrinseque de CNPG. Constate
    # empiriquement : downtime_median ~92s avec PostInjectWaitSeconds=90.
    # Choisis cette valeur deliberement et REPORTE-LA explicitement dans le
    # papier comme fenetre d'observation standardisee (ex: "CNPG reste bloque
    # au moins Xs, fenetre d'observation fixee a Xs pour tous les runs"), pas
    # comme un RTO mesure objectivement.
    # Choix retenu : 60s. Marge confortable par rapport a la stabilisation du
    # blocage observee empiriquement (~34-42s lors du pilote et de la
    # validation manuelle) sans etre arbitrairement long -- a citer tel quel
    # dans la section Methodologie du papier.
    [int]$PostInjectWaitSeconds = 60,

    [int]$StabilizeSeconds = 20,       # attente apres heal, avant le run suivant (laisse le quorum se resynchroniser)

    [switch]$FreshClusterEachRun
)

$ErrorActionPreference = "Continue"

$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$DeployScript = Join-Path $ScriptDir "deploy_$System.ps1"
if (-not (Test-Path $DeployScript)) {
    Write-Error "[run_campaign] Introuvable : $DeployScript (doit etre dans le meme dossier que run_campaign.ps1)"
    exit 1
}

$ResultsDir  = Join-Path $ScriptDir "results_$System"
$ManifestCsv = Join-Path $ResultsDir "manifest.csv"
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

if (-not (Test-Path $ManifestCsv)) {
    "run_id,system,scenario,rep,t_baseline_start_unix,t_inject_unix,t_heal_unix,t_run_end_unix,role_log,writer_log,count_before,max_id_before,rows_surviving,notes" | Set-Content -Path $ManifestCsv
}

$SourceLogDir = Join-Path $ScriptDir "$($System)_logs"   # cnpg_logs/ ou patroni_logs/, produit par deploy_*.ps1
$RoleCsv      = Join-Path $SourceLogDir "role.csv"
$WriterCsv    = Join-Path $SourceLogDir "writer_timed.csv"

function Invoke-Deploy { param([string]$Action, [string]$TargetReplica = "")
    if ($TargetReplica) {
        & $DeployScript $Action -TargetReplica $TargetReplica
    } else {
        & $DeployScript $Action
    }
    return $?   # $true si deploy_cnpg.ps1 n'a pas leve d'erreur (ex: le Write-Error de writer-start si aucun process ne demarre)
}

function Wait-ClusterReady {
    # "healthy state" (pas juste "Running") : plus strict, necessaire apres un
    # "kill" ou CNPG doit RECREER un pod entier (pas juste retablir une
    # connexion reseau) -- constate empiriquement : ecart de 15 min observe
    # entre deux runs "kill" consecutifs, largement au-dela des 15s de
    # stabilisation prevus, ce qui a laisse writer-start/probe-start s'executer
    # sur un cluster pas encore reellement stable (logs vides en resultat).
    param([int]$MaxTries = 40, [int]$SleepSeconds = 5)
    for ($i = 0; $i -lt $MaxTries; $i++) {
        $out = Invoke-Deploy "status" 2>$null
        if ($out -match "healthy state") { return $true }
        Start-Sleep -Seconds $SleepSeconds
    }
    return $false
}

function Invoke-KillPrimary {
    # Scenario "panne franche" -- pas dans deploy_cnpg.ps1, implemente ici
    # directement via kubectl. Namespace/nom du cluster : mêmes conventions
    # que dans deploy_cnpg.ps1 / deploy_patroni.ps1 -- [A VERIFIER] si tu
    # changes ces valeurs la-bas, il faut les repercuter ici.
    $NS = if ($System -eq "cnpg") { "fw-chaos" } else { "patroni" }
    $labelSelector = if ($System -eq "cnpg") { "cnpg.io/cluster=pg-cnpg" } else { "cluster-name=patronidemo" }
    $primary = if ($System -eq "cnpg") {
        kubectl -n $NS get cluster pg-cnpg -o jsonpath='{.status.currentPrimary}'
    } else {
        kubectl -n $NS get pods -l "cluster-name=patronidemo,role=master" -o jsonpath='{.items[0].metadata.name}'
    }
    if (-not $primary) { Write-Error "[kill] Primaire introuvable."; return }
    Write-Host "[kill] Suppression brutale du pod primaire $primary a $(Get-Date -Format o)"
    kubectl -n $NS delete pod $primary --grace-period=0 --force --wait=$false
}

function Invoke-Inject { param([string]$Scenario)
    switch ($Scenario) {
        "p1"      { Invoke-Deploy "inject-p1" }
        "p1-full" { Invoke-Deploy "inject-p1-full" }
        "p2"      { Invoke-Deploy "inject-p2" }
        "p2-full" { Invoke-Deploy "inject-p2-full" }
        "p3"      { Invoke-Deploy "inject-p3" }   # bloquant ~60s (4 paliers x 15s), inclus dans PostInjectWaitSeconds
        "p3-full" { Invoke-Deploy "inject-p3-full" }   # idem, mais sur les 2 replicas simultanement
        "kill"    { Invoke-KillPrimary }
        default   { Write-Error "[inject] Scenario inconnu: $Scenario" }
    }
}

function Copy-RunLogs { param([string]$RunId)
    $roleDst   = Join-Path $ResultsDir "$RunId.role.csv"
    $writerDst = Join-Path $ResultsDir "$RunId.writer.csv"
    if (Test-Path $RoleCsv)   { Copy-Item $RoleCsv   $roleDst   -Force } else { $roleDst = "" }
    if (Test-Path $WriterCsv) { Copy-Item $WriterCsv $writerDst -Force } else { $writerDst = "" }
    return @{ role = $roleDst; writer = $writerDst }
}

# ------------------------------------------------------------------------------
Write-Host "[run_campaign] Systeme=$System Scenarios=$($Scenarios -join ',') Reps=$Reps"
Write-Host "[run_campaign] Resultats -> $ResultsDir"
Write-Host "[run_campaign] Manifeste -> $ManifestCsv"

if (-not $FreshClusterEachRun) {
    Write-Host "[run_campaign] Deploiement initial du cluster (reutilise pour tous les runs)..."
    if ($System -eq "cnpg") { Invoke-Deploy "install-operator" | Out-Null }
    Invoke-Deploy "deploy-cluster" | Out-Null
    if (-not (Wait-ClusterReady)) {
        Write-Error "[run_campaign] Cluster pas pret apres attente -- abandon. Verifie '$DeployScript status' manuellement."
        exit 1
    }
}

foreach ($scenario in $Scenarios) {
    for ($rep = 1; $rep -le $Reps; $rep++) {
        $runId = "{0}_{1}_rep{2:D3}_{3}" -f $System, $scenario, $rep, (Get-Date -Format "yyyyMMdd_HHmmss")
        Write-Host ""
        Write-Host "=== [run_campaign] $runId ==="

        if ($FreshClusterEachRun) {
            Invoke-Deploy "teardown" | Out-Null
            if ($System -eq "cnpg") { Invoke-Deploy "install-operator" | Out-Null }
            Invoke-Deploy "deploy-cluster" | Out-Null
            if (-not (Wait-ClusterReady)) {
                Write-Error "[run_campaign] $runId : cluster pas pret -- run saute."
                continue
            }
        } else {
            # Filet de securite : le pod role-observer accumule des processus
            # zombies au fil des cycles writer-start/writer-stop (constate
            # empiriquement -- le kill du process parent ne tuait pas toujours
            # les enfants "timeout" en cours, corrige cote deploy_cnpg.ps1,
            # mais on rafraichit quand meme le pod periodiquement par prudence
            # sur une longue campagne).
            $runIndex = (($Scenarios.IndexOf($scenario)) * $Reps) + $rep
            if ($runIndex % 5 -eq 0) {
                Write-Host "[run_campaign] Rafraichissement preventif du pod role-observer (run #$runIndex)..."
                $NS_probe = if ($System -eq "cnpg") { "fw-chaos" } else { "patroni" }
                kubectl -n $NS_probe delete pod role-observer --ignore-not-found 2>$null | Out-Null
                Invoke-Deploy "probe-start"
            }
            Invoke-Deploy "heal"
            Start-Sleep -Seconds 5
        }

        # probe-start AVANT writer-start : c'est probe-start qui cree/garantit
        # le pod role-observer (kubectl apply). writer-start suppose que ce pod
        # existe deja (il fait juste kubectl exec dessus) -- si on l'appelle en
        # premier sur un cluster tout juste deploye, role-observer n'existe pas
        # encore et writer-start echoue silencieusement (log vide).
        $probeOk  = Invoke-Deploy "probe-start"
        $writerOk = Invoke-Deploy "writer-start"

        if (-not $probeOk -or -not $writerOk) {
            # Un des deux a echoue (ex: cluster pas encore stable apres un
            # "kill" precedent -- constate empiriquement, 15 min d'ecart entre
            # deux runs "kill" consecutifs). On retente une fois apres une
            # pause, plutot que de continuer avec une instrumentation morte
            # (logs vides silencieux).
            Write-Host "[run_campaign] $runId : probe-start/writer-start pas confirmes -- pause 20s puis nouvelle tentative..."
            Start-Sleep -Seconds 20
            $probeOk  = Invoke-Deploy "probe-start"
            $writerOk = Invoke-Deploy "writer-start"
        }

        if (-not $probeOk -or -not $writerOk) {
            Write-Error "[run_campaign] $runId : probe-start/writer-start echouent encore apres nouvelle tentative -- run SAUTE (pas d'instrumentation active)."
            "$runId,$System,$scenario,$rep,,,,,,,,,,INSTRUMENTATION_ECHOUEE_RUN_SAUTE" | Add-Content -Path $ManifestCsv
            Invoke-Deploy "writer-stop" | Out-Null   # nettoyage best-effort, au cas ou l'un des deux ait quand meme demarre
            Invoke-Deploy "probe-stop"  | Out-Null
            continue
        }

        $tBaseline = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-Host "[run_campaign] Baseline ${BaselineSeconds}s..."
        Start-Sleep -Seconds $BaselineSeconds

        $rowsBeforeRaw = Invoke-Deploy "row-count" 6>&1 | Select-String "^COUNT:" | Select-Object -Last 1
        $countBefore = ""
        $maxIdBefore = ""
        if ($rowsBeforeRaw -match 'COUNT:(\S+)\|MAXID:(\S+)') {
            $countBefore = $Matches[1]
            $maxIdBefore = $Matches[2]
        }

        $tInject = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $injectStart = Get-Date
        Invoke-Inject -Scenario $scenario
        $injectElapsedSeconds = [int]((Get-Date) - $injectStart).TotalSeconds

        # P3/P3-full bloquent deja ~60s en interne (4 paliers x 15s) -- ne
        # dormir QUE le complement, pas PostInjectWaitSeconds en plus.
        # Bug corrige : avant ce fix, le heal arrivait a ~120s (60s injection
        # + 60s sommeil) au lieu de 60s pour P3/P3-full, contrairement a
        # P1-full/P2-full (injection quasi instantanee, 60s de sommeil
        # complet) -- constate empiriquement, downtime_median=131s au lieu
        # des ~60s attendus et comparables aux autres scenarios "-full".
        $remainingWait = $PostInjectWaitSeconds - $injectElapsedSeconds
        if ($remainingWait -gt 0) {
            Write-Host "[run_campaign] Observation post-injection ${remainingWait}s (injection a deja dure ${injectElapsedSeconds}s)..."
            Start-Sleep -Seconds $remainingWait
        } else {
            Write-Host "[run_campaign] Injection a deja dure ${injectElapsedSeconds}s (>= PostInjectWaitSeconds=${PostInjectWaitSeconds}s) -- pas d'attente supplementaire."
        }

        $tHeal = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($scenario -ne "kill") { Invoke-Deploy "heal" }   # "kill" n'a rien a nettoyer (pas d'iptables/tc)

        Write-Host "[run_campaign] Stabilisation ${StabilizeSeconds}s avant arret des sondes..."
        Start-Sleep -Seconds $StabilizeSeconds

        # RPO : combien de lignes avec id <= maxIdBefore existent ENCORE.
        # maxIdBefore delimite une population "fermee" au moment de
        # l'injection (aucune nouvelle ligne ne peut y entrer par la suite),
        # donc ce chiffre est comparable a countBefore independamment des
        # ecritures survenues APRES la bascule (contrairement a une simple
        # comparaison de totaux avant/apres, qui serait masquee par les
        # nouvelles ecritures -- erreur deja identifiee et evitee ici).
        $survivingRaw = ""
        if ($maxIdBefore -match '^\d+$') {
            $survivingRaw = Invoke-Deploy "row-count-upto" -TargetReplica $maxIdBefore 6>&1 | Select-String "^SURVIVING:" | Select-Object -Last 1
        }
        $rowsSurviving = if ($survivingRaw -match 'SURVIVING:(\S+)') { $Matches[1] } else { "" }

        Invoke-Deploy "writer-stop"
        Invoke-Deploy "probe-stop"
        $tEnd = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        $paths = Copy-RunLogs -RunId $runId

        $notes = ""
        if (-not $paths.role -or -not $paths.writer) { $notes = "LOGS_MANQUANTS" }
        if ($countBefore -match "ERROR" -or -not $countBefore -or $rowsSurviving -match "ERROR" -or -not $rowsSurviving) {
            $notes = ($notes + ";ROW_COUNT_ECHEC").Trim(";")
        }

        "$runId,$System,$scenario,$rep,$tBaseline,$tInject,$tHeal,$tEnd,$($paths.role),$($paths.writer),$countBefore,$maxIdBefore,$rowsSurviving,$notes" | Add-Content -Path $ManifestCsv
        Write-Host "[run_campaign] $runId termine. role=$($paths.role) writer=$($paths.writer) count_before=$countBefore max_id_before=$maxIdBefore surviving=$rowsSurviving"

        if ($scenario -eq "kill" -and -not $FreshClusterEachRun) {
            # Apres un kill, attendre que le cluster ait retrouve 3 instances
            # avant le run suivant (sinon le prochain "primaire" resolu pourrait
            # etre incoherent, ou une instance encore en cours de recreation).
            Write-Host "[run_campaign] Post-kill : attente de la reconstitution du cluster..."
            Wait-ClusterReady | Out-Null
            Start-Sleep -Seconds 15
        }
    }
}

if ($FreshClusterEachRun) {
    Write-Host "[run_campaign] Campagne terminee. Cluster laisse tel quel (dernier run) -- teardown manuel si besoin."
} else {
    Write-Host "[run_campaign] Campagne terminee."
}
Write-Host "[run_campaign] Prochaine etape : .\analyze_run.ps1 -System $System"
