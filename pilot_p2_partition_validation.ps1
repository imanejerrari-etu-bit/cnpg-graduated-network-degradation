<#
==============================================================================
 PILOT (PowerShell) — Validation de la mesurabilite des pannes reseau
 P1 (partition symetrique) / P2 (asymetrique) / P3 (degradation graduee)
 sur votre cluster kind existant "pi-cluster".
==============================================================================

 Objectif : avant de lancer la campagne complete (CNPG vs Patroni, n=30-50),
 valider techniquement que kind permet de produire une partition ASYMETRIQUE
 (P2) propre -- A->B bloque mais B->A fonctionnel -- et de la distinguer sans
 ambiguite d'une partition symetrique (P1).

 Ce pilote N'UTILISE PAS CNPG/Patroni : 3 pods busybox legers suffisent pour
 valider la couche d'injection de fautes reseau.

 v6 -- SONDAGE IN-POD (changement architectural important) :
   Les versions precedentes lancaient un `kubectl exec ... ping` DEPUIS
   L'HOTE a chaque mesure (toutes les 0.5s). Sur un cluster kind sous
   WSL2/Docker Desktop, ce va-et-vient host<->API-server repete finissait
   par saturer et produisait un taux de timeout ~uniforme sur TOUTES les
   directions (meme celles jamais touchees par une panne) -- un artefact
   de mesure, pas un vrai signal reseau.
   Desormais, une boucle de ping tourne EN CONTINU A L'INTERIEUR de chaque
   pod (via nohup), sans jamais re-solliciter l'API server pendant la
   mesure elle-meme. L'hote ne parle a l'API server qu'au demarrage
   (deploiement du script) et a l'arret (recuperation des logs).

 ADAPTE A VOTRE ENVIRONNEMENT REEL :
   - Cluster "pi-cluster" deja existant : PAS recree par ce script.
   - Namespace "pilot" isole de vos namespaces mongodb-pi / rpo-ycsb.
   - Seulement 2 workers dispo -> "primary" va sur le control-plane
     (tolerance de taint ajoutee).
   - CNI kindnet, Kubernetes v1.27.3.

 Prerequis : kubectl.exe et docker.exe dans le PATH PowerShell, kind.exe
 disponible pour la verification du nom de cluster.

 Usage (dans PowerShell, depuis le dossier du script) :
   .\pilot_p2_partition_validation.ps1 setup
   .\pilot_p2_partition_validation.ps1 probe-start
   .\pilot_p2_partition_validation.ps1 probe-status
   .\pilot_p2_partition_validation.ps1 inject-p1
   .\pilot_p2_partition_validation.ps1 heal
   .\pilot_p2_partition_validation.ps1 inject-p2
   .\pilot_p2_partition_validation.ps1 heal
   .\pilot_p2_partition_validation.ps1 inject-p3
   .\pilot_p2_partition_validation.ps1 heal
   .\pilot_p2_partition_validation.ps1 probe-stop
   .\pilot_p2_partition_validation.ps1 report
   .\pilot_p2_partition_validation.ps1 teardown

 Si l'execution de scripts est bloquee, lancez d'abord (dans le meme
 PowerShell, pas besoin d'admin) :
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

 Fichier UNIQUE -- plus besoin de probe_worker.ps1 (supprime en v6).
==============================================================================
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("setup","probe-start","probe-status","probe-stop","inject-p1","inject-p2","inject-p3","heal","report","teardown")]
    [string]$Action
)

$ErrorActionPreference = "Continue"   # NE PAS mettre "Stop" : casse "heal" sur des erreurs benignes (tc qdisc absent, etc.)

$ClusterName = "pi-cluster"        # cluster existant, PAS recree par ce script
$NS          = "pilot"

$ScriptDir   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogDir      = Join-Path $ScriptDir "pilot_logs"
$CsvLog      = Join-Path $LogDir "probes.csv"

# Mapping role -> noeud reel de votre cluster (cf. `kubectl get nodes -o wide`)
$NodeOf = @{
    "primary"   = "pi-cluster-control-plane"
    "replica-a" = "pi-cluster-worker"
    "replica-b" = "pi-cluster-worker2"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Get-PodIP {
    param([string]$Role)
    return (kubectl -n $NS get pod $Role -o jsonpath='{.status.podIP}')
}

# ------------------------------------------------------------------------------
function Invoke-Setup {
    Write-Host "[setup] Verification du cluster '$ClusterName'..."
    $clusters = kind get clusters
    if (-not ($clusters -contains $ClusterName)) {
        Write-Error "Cluster $ClusterName introuvable (kind get clusters: $clusters). Abandon."
        exit 1
    }

    kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    # IMPORTANT : manifests YAML complets envoyes via stdin (pas
    # `kubectl run --overrides=...`) -- du JSON avec guillemets imbriques
    # comme argument a un .exe natif depuis PowerShell est corrompu presque
    # a coup sur ("Invalid JSON Patch").
    $podPrimary = @"
apiVersion: v1
kind: Pod
metadata:
  name: primary
  namespace: $NS
spec:
  nodeName: pi-cluster-control-plane
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: netshoot
      image: nicolaka/netshoot:latest
      command: ["sh", "-c", "sleep infinity"]
"@

    $podReplicaA = @"
apiVersion: v1
kind: Pod
metadata:
  name: replica-a
  namespace: $NS
spec:
  nodeName: pi-cluster-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot:latest
      command: ["sh", "-c", "sleep infinity"]
"@

    $podReplicaB = @"
apiVersion: v1
kind: Pod
metadata:
  name: replica-b
  namespace: $NS
spec:
  nodeName: pi-cluster-worker2
  containers:
    - name: netshoot
      image: nicolaka/netshoot:latest
      command: ["sh", "-c", "sleep infinity"]
"@

    $podPrimary   | kubectl apply -f -
    $podReplicaA  | kubectl apply -f -
    $podReplicaB  | kubectl apply -f -

    Write-Host "[setup] Attente que les 3 pods soient Ready..."
    kubectl -n $NS wait --for=condition=Ready pod --all --timeout=120s

    Write-Host "[setup] Pods:"
    kubectl -n $NS get pods -o wide
    Write-Host "[setup] OK. primary=control-plane, replica-a=worker, replica-b=worker2."
}

# ------------------------------------------------------------------------------
# Sondage IN-POD, en UDP UNIDIRECTIONNEL (pas ping, pas nc). Apres plusieurs
# echecs avec `nc` sous busybox (bloque apres le tout premier paquet, quel
# que soit le mecanisme de redemarrage essaye), on passe a l'image netshoot
# (Python3 inclus) et a de vraies sockets UDP -- comportement previsible,
# sans les zones d'ombre de nc. Un seul processus Python gere emission
# (thread principal) ET reception (thread demon), donc un seul PID a suivre.
# ------------------------------------------------------------------------------

# Jetons __ROLE__/__IP1__/__IP2__ remplaces par simple .Replace() (pas -f,
# qui entrerait en collision avec les accolades des f-strings Python).
$UdpProbeScriptTemplate = @'
import socket, threading, time

role = "__ROLE__"
target1_ip = "__IP1__"
target2_ip = "__IP2__"
PORT = 5005

def receiver():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", PORT))
    with open("/tmp/recv.log", "a", buffering=1) as f:
        while True:
            try:
                data, addr = s.recvfrom(1024)
                f.write(str(int(time.time())) + "," + data.decode(errors="ignore").strip() + "\n")
                f.flush()
            except Exception:
                pass

threading.Thread(target=receiver, daemon=True).start()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
seqA = 0
seqB = 0
while True:
    seqA += 1
    try:
        sock.sendto((role + ":" + str(seqA)).encode(), (target1_ip, PORT))
    except Exception:
        pass
    seqB += 1
    try:
        sock.sendto((role + ":" + str(seqB)).encode(), (target2_ip, PORT))
    except Exception:
        pass
    time.sleep(0.1)
'@

function Invoke-ProbeStart {
    $ipPrimary  = Get-PodIP "primary"
    $ipReplicaA = Get-PodIP "replica-a"
    $ipReplicaB = Get-PodIP "replica-b"
    Write-Host "[probe-start] IPs: primary=$ipPrimary replica-a=$ipReplicaA replica-b=$ipReplicaB"

    if (-not $ipPrimary -or -not $ipReplicaA -or -not $ipReplicaB) {
        Write-Error "[probe-start] IP(s) vide(s) -- les pods sont-ils Running ? (kubectl -n $NS get pods -o wide). Abandon."
        return
    }

    $targetIpsByRole = @{
        "primary"   = @($ipReplicaA, $ipReplicaB)
        "replica-a" = @($ipPrimary,  $ipReplicaB)
        "replica-b" = @($ipPrimary,  $ipReplicaA)
    }

    foreach ($role in @("primary","replica-a","replica-b")) {
        $ips = $targetIpsByRole[$role]
        $script = $UdpProbeScriptTemplate.Replace("__ROLE__", $role).Replace("__IP1__", $ips[0]).Replace("__IP2__", $ips[1])
        # IMPORTANT : on n'envoie plus le script via un pipe PowerShell vers
        # stdin de kubectl exec -- PowerShell y ajoute systematiquement un
        # \r\n final invisible. On ecrit le script dans un fichier LOCAL en
        # LF pur (sans BOM), puis on le copie octet-pour-octet dans le pod
        # via `kubectl cp`, qui ne passe pas par ce pipe texte.
        $script = $script -replace "`r`n", "`n" -replace "`r", "`n"
        $tmpFile = Join-Path $env:TEMP "probe_$role.py"
        [System.IO.File]::WriteAllText($tmpFile, $script, [System.Text.UTF8Encoding]::new($false))

        # kubectl cp decoupe ses arguments sur les ":" -- un chemin Windows
        # absolu (C:\...) le fait echouer, d'ou le passage par un nom de
        # fichier relatif depuis le dossier temp.
        Push-Location $env:TEMP
        kubectl cp "probe_$role.py" "${NS}/${role}:/tmp/probe.py"
        Pop-Location

        # Tue une eventuelle instance precedente et repart d'un log propre.
        kubectl -n $NS exec $role -- sh -c "test -f /tmp/probe.pid && kill `$(cat /tmp/probe.pid) 2>/dev/null; rm -f /tmp/recv.log; true" 2>$null | Out-Null

        # setsid = detachement complet d'une nouvelle session (sinon le
        # process backgrounde se fait tuer des que la connexion kubectl exec
        # se ferme). $! capture le PID du process juste backgrounde.
        kubectl -n $NS exec $role -- sh -c "setsid python3 /tmp/probe.py </dev/null >/tmp/probe.out 2>&1 & echo `$! > /tmp/probe.pid" 2>$null | Out-Null
    }

    Start-Sleep -Seconds 2
    Write-Host "[probe-start] Emetteurs/recepteurs UDP lances DANS les 3 pods (aucun processus hote requis pendant la mesure)."
}

function Invoke-ProbeStatus {
    foreach ($role in @("primary","replica-a","replica-b")) {
        $pidVal = kubectl -n $NS exec $role -- sh -c "cat /tmp/probe.pid 2>/dev/null"
        if ($pidVal) {
            $alive = kubectl -n $NS exec $role -- sh -c "kill -0 $pidVal 2>/dev/null && echo RUNNING || echo STOPPED-mort"
        } else {
            $alive = "STOPPED (pas de fichier PID -- probe-start a-t-il ete lance ?)"
        }
        $lines = kubectl -n $NS exec $role -- sh -c "wc -l < /tmp/recv.log 2>/dev/null || echo 0"
        Write-Host "[probe-status] ${role}: $alive -- $lines messages recus dans /tmp/recv.log"
    }
}

function Invoke-ProbeStop {
    $allLines = New-Object System.Collections.Generic.List[string]
    $allLines.Add("timestamp,src,dst,direction,rtt_ms,status")

    foreach ($role in @("primary","replica-a","replica-b")) {
        kubectl -n $NS exec $role -- sh -c "test -f /tmp/probe.pid && kill `$(cat /tmp/probe.pid) 2>/dev/null; true" 2>$null | Out-Null
        $raw = kubectl -n $NS exec $role -- sh -c "cat /tmp/recv.log 2>/dev/null" 2>$null
        if ($raw) {
            foreach ($line in $raw) {
                # format d'une ligne : "<ts_reception>,<role_expediteur>:<seq>"
                $parts = $line -split ","
                if ($parts.Count -ge 2) {
                    $ts = $parts[0]
                    $payload = $parts[1]
                    $src = ($payload -split ":")[0]
                    $dst = $role
                    if ($src) {
                        $allLines.Add("$ts,$src,$dst,$src->$dst,,received")
                    }
                }
            }
        }
    }

    # UNE SEULE ecriture (au lieu de centaines d'Add-Content successifs) --
    # moins d'occasions de tomber sur le fichier verrouille par un autre
    # programme, et avec 5 tentatives en cas de verrou transitoire.
    $written = $false
    for ($attempt = 1; $attempt -le 5 -and -not $written; $attempt++) {
        try {
            [System.IO.File]::WriteAllLines($CsvLog, $allLines)
            $written = $true
        } catch {
            Write-Host "[probe-stop] Fichier verrouille (tentative $attempt/5), nouvel essai dans 2s..."
            Start-Sleep -Seconds 2
        }
    }

    if ($written) {
        Write-Host "[probe-stop] Sondes arretees. $($allLines.Count - 1) mesures fusionnees dans $CsvLog"
    } else {
        Write-Error "[probe-stop] Impossible d'ecrire $CsvLog apres 5 tentatives -- fermez tout programme qui pourrait l'avoir ouvert (Excel, editeur de texte, une autre fenetre PowerShell) et relancez 'probe-stop' seul (pas besoin de refaire tout le pilote)."
    }
}

# ------------------------------------------------------------------------------
# Injections de fautes : executees DANS le netns du conteneur-noeud kind via
# `docker exec` (un noeud kind est un conteneur Docker normal).
# ------------------------------------------------------------------------------
function Invoke-InjectP1 {
    Write-Host "[inject-p1] Partition symetrique primary <-> replica-a"
    $aIp = Get-PodIP "replica-a"
    $pIp = Get-PodIP "primary"
    $nodeP = $NodeOf["primary"]
    $nodeA = $NodeOf["replica-a"]

    # IMPORTANT : chaine FORWARD, pas INPUT/OUTPUT. Le trafic pod-a-pod
    # inter-noeuds traverse le noeud comme un routeur (le noeud n'est ni
    # source ni destination finale) -- INPUT/OUTPUT ne s'appliquent qu'au
    # trafic adresse au noeud lui-meme, donc ne bloquaient rien en pratique
    # (constate : 0% timeout pendant P1/P2 alors que les regles etaient
    # posees). Regles precises -s/-d sur les deux noeuds, dans les deux sens.
    docker exec $nodeP iptables -A FORWARD -s $pIp -d $aIp -j DROP
    docker exec $nodeP iptables -A FORWARD -s $aIp -d $pIp -j DROP
    docker exec $nodeA iptables -A FORWARD -s $pIp -d $aIp -j DROP
    docker exec $nodeA iptables -A FORWARD -s $aIp -d $pIp -j DROP

    Write-Host "[inject-p1] Fault injectee a $(Get-Date -Format o)"
}

function Invoke-InjectP2 {
    # ASYMETRIQUE : replica-a NE PEUT PLUS ENVOYER vers primary, mais
    # primary PEUT toujours envoyer vers replica-a. C'est le cas critique
    # a valider (ex: follower ne peut plus heartbeat vers le DCS/primary
    # mais recoit encore le WAL).
    Write-Host "[inject-p2] Partition asymetrique : replica-a -> primary bloque, primary -> replica-a OK"
    $aIp = Get-PodIP "replica-a"
    $pIp = Get-PodIP "primary"
    $nodeP = $NodeOf["primary"]
    $nodeA = $NodeOf["replica-a"]

    # Chaine FORWARD (cf. inject-p1) -- UNE SEULE direction ciblee (-s aIp -d pIp),
    # posee sur les deux noeuds par prudence. Aucune regle -s pIp -d aIp n'est
    # ajoutee : le sens primary->replica-a reste donc intact.
    docker exec $nodeA iptables -A FORWARD -s $aIp -d $pIp -j DROP
    docker exec $nodeP iptables -A FORWARD -s $aIp -d $pIp -j DROP

    Write-Host "[inject-p2] Fault injectee a $(Get-Date -Format o)"
}

function Invoke-InjectP3 {
    # Degradation graduee sur replica-a : 4 paliers de 15s via tc netem.
    # VERIFIEZ D'ABORD le nom de l'interface reseau du noeud (souvent eth0
    # sur kind, mais a confirmer) :
    #   docker exec pi-cluster-worker ip addr show
    Write-Host "[inject-p3] Degradation graduee sur replica-a (tc netem, 4 paliers)"
    $node = $NodeOf["replica-a"]
    $steps = @(
        @{delay="50ms";  loss="0%"},
        @{delay="150ms"; loss="2%"},
        @{delay="400ms"; loss="5%"},
        @{delay="800ms"; loss="15%"}
    )
    foreach ($s in $steps) {
        docker exec $node tc qdisc replace dev eth0 root netem delay $s.delay loss $s.loss 2>$null
        if ($LASTEXITCODE -ne 0) {
            docker exec $node tc qdisc add dev eth0 root netem delay $s.delay loss $s.loss
        }
        Write-Host "  palier: delay=$($s.delay) loss=$($s.loss) @ $(Get-Date -Format o)"
        Start-Sleep -Seconds 15
    }
}

function Invoke-Heal {
    Write-Host "[heal] Nettoyage iptables/tc sur tous les noeuds..."
    foreach ($role in @("primary","replica-a","replica-b")) {
        $node = $NodeOf[$role]
        docker exec $node iptables -F 2>$null
        docker exec $node tc qdisc del dev eth0 root 2>$null
    }
    Write-Host "[heal] OK a $(Get-Date -Format o)"
}

# ------------------------------------------------------------------------------
function Invoke-Report {
    if (-not (Test-Path $CsvLog)) {
        Write-Error "Aucun log trouve ($CsvLog). Avez-vous lance probe-stop apres probe-start ?"
        return
    }
    Write-Host "[report] Resume de $CsvLog :"
    Write-Host ""
    $rows = Import-Csv -Path $CsvLog
    if ($rows.Count -eq 0) {
        Write-Host "[report] AUCUNE ligne de donnees dans le CSV (juste l'en-tete)."
        Write-Host "  -> Avez-vous bien lance probe-stop (c'est lui qui recupere les logs des pods) ?"
        return
    }
    Write-Host "[report] $($rows.Count) mesures au total (nombre de messages UDP recus, par direction)."
    $rows | Group-Object direction | Sort-Object Name | ForEach-Object {
        "{0,-25} {1} messages recus" -f $_.Name, $_.Count
    }
    Write-Host ""
    Write-Host "-> Ce compte brut ne veut pas dire grand-chose seul : utilisez"
    Write-Host "   analyze_pilot.ps1 (decoupage par fenetre temporelle) pour comparer"
    Write-Host "   le debit par direction pendant P1/P2/P3 contre la baseline."
    Write-Host ""
    Write-Host "Criteres GO/NO-GO :"
    Write-Host "  GO    si, pendant P2 : replica-a->primary chute fortement (proche de 0)"
    Write-Host "                         ET primary->replica-a reste proche du debit baseline"
    Write-Host "  NO-GO si les deux sens sont affectes de facon comparable pendant P2."
}

function Invoke-Teardown {
    # NE SUPPRIME PAS le cluster (il heberge mongodb-pi / rpo-ycsb en cours) :
    # on ne retire que le namespace du pilote.
    Invoke-ProbeStop
    Invoke-Heal
    kubectl delete namespace $NS --ignore-not-found
    Write-Host "[teardown] Namespace '$NS' supprime. Cluster '$ClusterName' intact."
}

# ------------------------------------------------------------------------------
switch ($Action) {
    "setup"       { Invoke-Setup }
    "probe-start" { Invoke-ProbeStart }
    "probe-status"{ Invoke-ProbeStatus }
    "probe-stop"  { Invoke-ProbeStop }
    "inject-p1"   { Invoke-InjectP1 }
    "inject-p2"   { Invoke-InjectP2 }
    "inject-p3"   { Invoke-InjectP3 }
    "heal"        { Invoke-Heal }
    "report"      { Invoke-Report }
    "teardown"    { Invoke-Teardown }
}
