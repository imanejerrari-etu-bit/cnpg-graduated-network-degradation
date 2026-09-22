<#
==============================================================================
 deploy_cnpg.ps1 -- Deploiement CNPG + observateur de role (etape 1)
==============================================================================
 Installe l'operateur CloudNativePG, cree un Cluster a 3 instances avec le
 quorum failover active (CNPG >=1.28), et lance un observateur qui journalise
 le role (primaire/replica) de chaque instance toutes les ~200ms -- premiere
 brique pour calculer le RTO. Le RPO (LSN) sera ajoute dans une 2e etape une
 fois le suivi de role valide.

 Reprend les principes valides pendant le pilote reseau :
   - pas de kubectl exec repete depuis l'hote pendant la mesure (observateur
     in-pod, setsid, recuperation des logs en fin de run)
   - kubectl cp (pas de pipe stdin) pour deployer les scripts, avec
     contournement Push-Location pour le bug de chemin Windows/kubectl cp
   - chemins absolus $env:TEMP pour eviter les soucis de repertoire courant

 Cluster reutilise "pi-cluster" existant (1 control-plane + 2 workers) --
 tolerance de taint pour permettre aux instances CNPG de se placer aussi sur
 le control-plane (3 instances demandees, seulement 2 workers disponibles).

 Usage :
   .\deploy_cnpg.ps1 install-operator
   .\deploy_cnpg.ps1 deploy-cluster
   .\deploy_cnpg.ps1 status
   .\deploy_cnpg.ps1 get-credentials
   .\deploy_cnpg.ps1 probe-start
   .\deploy_cnpg.ps1 probe-status
   .\deploy_cnpg.ps1 probe-stop
   .\deploy_cnpg.ps1 teardown
==============================================================================
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("install-operator","deploy-cluster","status","get-credentials","writer-start","writer-stop","probe-start","probe-status","probe-stop","inject-p1","inject-p1-full","inject-p2","inject-p2-full","inject-p3","inject-p3-full","heal","teardown","row-count","row-count-upto")]
    [string]$Action,
    [string]$TargetReplica = ""
)

$ErrorActionPreference = "Continue"

$NS = "fw-chaos"
$ClusterName = "pg-cnpg"
$OperatorManifestUrl = "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.3.yaml"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogDir    = Join-Path $ScriptDir "cnpg_logs"
$RoleLog   = Join-Path $LogDir "role.csv"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Invoke-InstallOperator {
    Write-Host "[install-operator] Installation de CloudNativePG 1.28.3..."
    kubectl apply --server-side -f $OperatorManifestUrl
    Write-Host "[install-operator] Attente du rollout..."
    kubectl rollout status deployment -n cnpg-system cnpg-controller-manager --timeout=180s
}

function Invoke-DeployCluster {
    kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

    $clusterYaml = @"
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $ClusterName
  namespace: $NS
spec:
  instances: 3
  affinity:
    tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
  postgresql:
    synchronous:
      method: any
      number: 1
      failoverQuorum: true
  storage:
    size: 1Gi
"@
    $clusterYaml | kubectl apply -f -

    Write-Host "[deploy-cluster] Cluster '$ClusterName' cree dans le namespace '$NS'."
    Write-Host "[deploy-cluster] Ca peut prendre 1-3 minutes (pull image postgres + init des 3 instances)."
    Write-Host "[deploy-cluster] Suivez avec : .\deploy_cnpg.ps1 status"
}

function Invoke-Status {
    kubectl -n $NS get cluster $ClusterName
    Write-Host ""
    kubectl -n $NS get pods -o wide
}

function Invoke-GetCredentials {
    $secretName = "$ClusterName-app"
    $userB64 = kubectl -n $NS get secret $secretName -o jsonpath='{.data.username}'
    $passB64 = kubectl -n $NS get secret $secretName -o jsonpath='{.data.password}'
    if (-not $userB64) {
        Write-Error "[get-credentials] Secret '$secretName' introuvable -- le cluster est-il deploye et pret ? (.\deploy_cnpg.ps1 status)"
        return
    }
    $user = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($userB64))
    $pass = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($passB64))
    Write-Host "Utilisateur : $user"
    Write-Host "Mot de passe : $pass"
    Write-Host ""
    Write-Host "(utilise automatiquement par probe-start -- juste informatif ici)"
}

function Get-PgCredentials {
    $secretName = "$ClusterName-app"
    $userB64 = kubectl -n $NS get secret $secretName -o jsonpath='{.data.username}'
    $passB64 = kubectl -n $NS get secret $secretName -o jsonpath='{.data.password}'
    if (-not $userB64 -or -not $passB64) { return $null }
    $user = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($userB64))
    $pass = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($passB64))
    return @{ user = $user; pass = $pass }
}

function Invoke-RowCount {
    # RPO base sur un comptage de lignes reellement presentes, plutot qu'une
    # difference de LSN brute (contaminee par les artefacts de changement de
    # timeline -- ~16 Mo constant observe sur la premiere campagne, signature
    # typique de cet artefact plutot qu'une vraie perte).
    #
    # ATTENTION (piege deja rencontre et corrige) : comparer un simple total
    # avant/apres NE MARCHE PAS, puisque le writer continue d'ecrire apres la
    # bascule -- un total qui augmente ne prouve rien sur une eventuelle perte.
    # La bonne methode : capturer max(id) AVANT l'injection, puis apres,
    # verifier combien de lignes avec id <= ce seuil existent ENCORE (action
    # "row-count-upto"). Comme les id sont strictement croissants, cette
    # population est "fermee" des l'injection : aucune nouvelle ligne ne peut
    # y entrer, donc toute difference est une vraie perte, pas un artefact des
    # ecritures posterieures.
    #
    # Sortie : "COUNT:<n>|MAXID:<m>" sur stdout.
    $cred = Get-PgCredentials
    if (-not $cred) { Write-Host "COUNT:ERROR_NO_CREDENTIALS|MAXID:ERROR"; return }
    $out = kubectl -n $NS exec role-observer -- sh -c "PGPASSWORD='$($cred.pass)' PGCONNECT_TIMEOUT=2 psql -h pg-cnpg-rw.$NS.svc -U $($cred.user) -d app -tAc 'SELECT count(*), coalesce(max(id),0) FROM rpotest;'" 2>$null
    if ($out -match '^\d+\|\d+$') {
        $parts = $out -split '\|'
        Write-Host "COUNT:$($parts[0])|MAXID:$($parts[1])"
    } else {
        Write-Host "COUNT:ERROR_QUERY_FAILED|MAXID:ERROR"
    }
}

function Invoke-RowCountUpTo {
    # $TargetReplica reutilise ici comme vecteur pour le seuil d'id (evite
    # d'ajouter un nouveau parametre CLI juste pour ce cas). Renvoie combien de
    # lignes avec id <= seuil existent ENCORE -- a comparer au seuil lui-meme
    # (qui EST ce compte au moment de la capture, par definition de max(id)).
    $threshold = $TargetReplica
    if (-not $threshold -or $threshold -notmatch '^\d+$') {
        Write-Host "SURVIVING:ERROR_NO_THRESHOLD"; return
    }
    $cred = Get-PgCredentials
    if (-not $cred) { Write-Host "SURVIVING:ERROR_NO_CREDENTIALS"; return }
    $out = kubectl -n $NS exec role-observer -- sh -c "PGPASSWORD='$($cred.pass)' PGCONNECT_TIMEOUT=2 psql -h pg-cnpg-rw.$NS.svc -U $($cred.user) -d app -tAc 'SELECT count(*) FROM rpotest WHERE id <= $threshold;'" 2>$null
    if ($out -match '^\d+$') {
        Write-Host "SURVIVING:$out"
    } else {
        Write-Host "SURVIVING:ERROR_QUERY_FAILED"
    }
}

# ------------------------------------------------------------------------------
# Observateur de role : pod dedie (image postgres:16-alpine, deja equipee de
# psql), qui interroge pg_is_in_recovery() sur chacune des 3 instances toutes
# les ~200ms et journalise localement (pas de kubectl exec repete depuis
# l'hote pendant la mesure -- meme principe que le pilote reseau).
# ------------------------------------------------------------------------------
$RoleProbeTemplate = @'
#!/bin/sh
rm -f /tmp/role.log
echo $$ > /tmp/probe.pid
export PGPASSWORD="__PGPASS__"
export PGCONNECT_TIMEOUT=1
while true; do
  ts=$(date +%s)
  for entry in "__NAME1__:__IP1__" "__NAME2__:__IP2__" "__NAME3__:__IP3__"; do
    name="${entry%%:*}"
    ip="${entry#*:}"
    result=$(psql -h "$ip" -U __PGUSER__ -d app -tAc "SELECT pg_is_in_recovery(), CASE WHEN pg_is_in_recovery() THEN COALESCE(pg_last_wal_replay_lsn()::text,'') ELSE pg_current_wal_lsn()::text END;" -w 2>>/tmp/probe_errors.log)
    if [ -z "$result" ]; then
      result="unreachable,"
    else
      result=$(echo "$result" | tr '|' ',')
    fi
    echo "$ts,$name,$result" >> /tmp/role.log
  done
  sleep 0.2
done
'@

$WriterScriptTemplate = @'
#!/bin/sh
export PGPASSWORD="__PGPASS__"
export PGCONNECT_TIMEOUT=1
# Sans ceci, un COMMIT bloque par une perte de quorum synchrone reste suspendu
# indefiniment cote client : psql finit par renvoyer "ok" une fois le quorum
# restaure, sans jamais passer par la branche "fail" -- ce qui masque
# completement la fenetre d'indisponibilite (constate empiriquement : 38
# INSERT en ~130s au lieu des ~1000+ attendus, 0 echec rapporte). Avec ce
# timeout, un commit qui ne peut pas obtenir son accuse de reception echoue
# proprement au bout de 2s au lieu de bloquer.
export PGOPTIONS="-c statement_timeout=2000"
psql -h pg-cnpg-rw.__NS__.svc -U __PGUSER__ -d app -c "CREATE TABLE IF NOT EXISTS rpotest (id serial primary key, ts timestamp default now());" >/tmp/writer_init.out 2>&1
rm -f /tmp/writer_timed.log
while true; do
  t0=$(date +%s)
  # timeout (cote shell) plutot que de compter sur statement_timeout : confirme
  # empiriquement (pg_stat_activity, wait_event=SyncRep observe a 17s+) que
  # statement_timeout=2000 n'annule PAS une attente de quorum synchrone dans
  # cet environnement. timeout tue le PROCESSUS psql de force apres 2s, sans
  # dependre du mecanisme d'annulation interne de PostgreSQL.
  if timeout 2 psql -h pg-cnpg-rw.__NS__.svc -U __PGUSER__ -d app -c "INSERT INTO rpotest DEFAULT VALUES;" >/tmp/writer_last.out 2>&1; then
    status=ok
  else
    status=fail
  fi
  t1=$(date +%s)
  echo "$t0,$t1,$status" >> /tmp/writer_timed.log
  sleep 0.1
done
'@

function Get-CurrentPrimary {
    return (kubectl -n $NS get cluster $ClusterName -o jsonpath='{.status.currentPrimary}')
}

function Get-PodNode {
    param([string]$Pod)
    return (kubectl -n $NS get pod $Pod -o jsonpath='{.spec.nodeName}')
}

function Get-AllInstancePods {
    $raw = kubectl -n $NS get pods -l "cnpg.io/cluster=$ClusterName" -o jsonpath='{.items[*].metadata.name}'
    return @($raw -split '\s+' | Where-Object { $_ })
}

function Resolve-InjectionTargets {
    param([string]$PreferredReplica = "")
    $primary = Get-CurrentPrimary
    if (-not $primary) { Write-Error "[inject] Primaire introuvable (cluster pas pret ?)."; return $null }
    $allPods = Get-AllInstancePods
    $replicas = @($allPods | Where-Object { $_ -ne $primary })
    if ($replicas.Count -eq 0) { Write-Error "[inject] Aucun replica trouve."; return $null }

    if ($PreferredReplica -and ($replicas -contains $PreferredReplica)) {
        $target = $PreferredReplica
    } else {
        # IMPORTANT : on evite par defaut de choisir un replica scheduled sur
        # le noeud control-plane. Ce noeud heberge aussi l'API server/etcd du
        # cluster kind -- une degradation reseau dessus confond "panne sur un
        # replica" avec "perturbation du control-plane K8s lui-meme" (constate
        # empiriquement : degrader un replica sur ce noeud a declenche une
        # bascule du PRIMAIRE, situe sur un autre noeud, alors que rien ne le
        # justifiait cote reseau applicatif pur).
        $nonCpReplicas = @($replicas | Where-Object { (Get-PodNode $_) -ne "pi-cluster-control-plane" })
        $target = if ($nonCpReplicas.Count -gt 0) { $nonCpReplicas[0] } else {
            Write-Warning "[inject] Tous les replicas disponibles sont sur le control-plane -- impossible d'eviter le confond cette fois."
            $replicas[0]
        }
    }

    $primaryNode = Get-PodNode $primary
    $targetNode  = Get-PodNode $target
    $primaryIp   = kubectl -n $NS get pod $primary -o jsonpath='{.status.podIP}'
    $targetIp    = kubectl -n $NS get pod $target -o jsonpath='{.status.podIP}'

    if ($primaryNode -eq "pi-cluster-control-plane" -or $targetNode -eq "pi-cluster-control-plane") {
        Write-Warning "[inject] Le primaire ou la cible tourne sur le control-plane -- interpretez le RTO/RPO de ce run avec prudence (confond possible avec une perturbation du control-plane K8s, pas seulement du reseau applicatif)."
    }
    if ($primaryNode -eq $targetNode) {
        Write-Warning "[inject] $primary et $target sont sur le MEME noeud ($primaryNode) -- l'injection FORWARD ne peut pas isoler leur trafic (il ne traverse pas le routage inter-noeuds). Choisissez un autre replica avec -TargetReplica, ou relancez le cluster pour forcer une repartition differente."
    }

    return @{
        Primary = $primary; PrimaryNode = $primaryNode; PrimaryIp = $primaryIp
        Target = $target;  TargetNode = $targetNode;   TargetIp = $targetIp
    }
}

function Invoke-InjectP1 {
    $t = Resolve-InjectionTargets -PreferredReplica $TargetReplica
    if (-not $t) { return }
    Write-Host "[inject-p1] Partition symetrique $($t.Primary) ($($t.PrimaryNode)) <-> $($t.Target) ($($t.TargetNode))"
    docker exec $t.PrimaryNode iptables -I FORWARD 1 -s $t.PrimaryIp -d $t.TargetIp -j DROP
    docker exec $t.PrimaryNode iptables -I FORWARD 1 -s $t.TargetIp -d $t.PrimaryIp -j DROP
    docker exec $t.TargetNode  iptables -I FORWARD 1 -s $t.PrimaryIp -d $t.TargetIp -j DROP
    docker exec $t.TargetNode  iptables -I FORWARD 1 -s $t.TargetIp -d $t.PrimaryIp -j DROP
    Write-Host "[inject-p1] Fault injectee a $(Get-Date -Format o) (primaire=$($t.Primary), cible=$($t.Target))"
}

function Invoke-InjectP2 {
    $t = Resolve-InjectionTargets -PreferredReplica $TargetReplica
    if (-not $t) { return }
    Write-Host "[inject-p2] Partition asymetrique : $($t.Target) -> $($t.Primary) bloque, $($t.Primary) -> $($t.Target) OK"
    docker exec $t.TargetNode  iptables -I FORWARD 1 -s $t.TargetIp -d $t.PrimaryIp -j DROP
    docker exec $t.PrimaryNode iptables -I FORWARD 1 -s $t.TargetIp -d $t.PrimaryIp -j DROP
    Write-Host "[inject-p2] Fault injectee a $(Get-Date -Format o) (primaire=$($t.Primary), cible=$($t.Target))"
}

function Invoke-InjectP3 {
    $t = Resolve-InjectionTargets -PreferredReplica $TargetReplica
    if (-not $t) { return }
    Write-Host "[inject-p3] Degradation graduee sur $($t.Target) ($($t.TargetNode)), 4 paliers"
    $steps = @(
        @{delay="50ms";  loss="0%"},
        @{delay="150ms"; loss="2%"},
        @{delay="400ms"; loss="5%"},
        @{delay="800ms"; loss="15%"}
    )
    foreach ($s in $steps) {
        docker exec $t.TargetNode tc qdisc replace dev eth0 root netem delay $s.delay loss $s.loss 2>$null
        if ($LASTEXITCODE -ne 0) {
            docker exec $t.TargetNode tc qdisc add dev eth0 root netem delay $s.delay loss $s.loss
        }
        Write-Host "  palier: delay=$($s.delay) loss=$($s.loss) @ $(Get-Date -Format o)"
        Start-Sleep -Seconds 15
    }
}

function Invoke-InjectP3Full {
    # Degradation graduee simultanee sur LES DEUX replicas (contrairement a
    # inject-p3 qui n'en degrade qu'un seul). Motivation : la campagne n=40 a
    # montre que P3 (1 seul replica) n'a AUCUN effet observable a aucun
    # palier, quorum ANY-1 satisfait par le second replica reste sain. Cette
    # variante coupe cette echappatoire, sur le meme principe que P1-full/
    # P2-full vis-a-vis de P1/P2.
    $primary = Get-CurrentPrimary
    if (-not $primary) { Write-Error "[inject-p3-full] Primaire introuvable."; return }
    $allPods = Get-AllInstancePods
    $replicas = @($allPods | Where-Object { $_ -ne $primary })
    if ($replicas.Count -lt 2) { Write-Error "[inject-p3-full] Moins de 2 replicas trouves."; return }

    $primaryNode = Get-PodNode $primary
    $replicaNodes = @{}
    foreach ($r in $replicas) {
        $rNode = Get-PodNode $r
        if ($rNode -eq $primaryNode) {
            Write-Warning "[inject-p3-full] $r et le primaire $primary sont sur le MEME noeud ($rNode) -- la degradation tc netem s'appliquera aussi au trafic du primaire lui-meme sur ce noeud, pas seulement a ce replica. Resultat a interpreter avec prudence si ce cas se presente."
        }
        $replicaNodes[$r] = $rNode
    }
    $uniqueNodes = $replicaNodes.Values | Sort-Object -Unique

    Write-Host "[inject-p3-full] Degradation graduee simultanee sur $($replicas -join ', ') ($($uniqueNodes -join ', ')), 4 paliers"
    $steps = @(
        @{delay="50ms";  loss="0%"},
        @{delay="150ms"; loss="2%"},
        @{delay="400ms"; loss="5%"},
        @{delay="800ms"; loss="15%"}
    )
    foreach ($s in $steps) {
        foreach ($node in $uniqueNodes) {
            docker exec $node tc qdisc replace dev eth0 root netem delay $s.delay loss $s.loss 2>$null
            if ($LASTEXITCODE -ne 0) {
                docker exec $node tc qdisc add dev eth0 root netem delay $s.delay loss $s.loss
            }
        }
        Write-Host "  palier: delay=$($s.delay) loss=$($s.loss) sur $($uniqueNodes -join ', ') @ $(Get-Date -Format o)"
        Start-Sleep -Seconds 15
    }
    Write-Host "[inject-p3-full] Termine a $(Get-Date -Format o)"
}

function Invoke-Heal {
    Write-Host "[heal] Nettoyage iptables/tc sur les noeuds des 3 instances..."
    $allPods = Get-AllInstancePods
    $nodes = $allPods | ForEach-Object { Get-PodNode $_ } | Sort-Object -Unique
    foreach ($node in $nodes) {
        docker exec $node iptables -F 2>$null
        docker exec $node tc qdisc del dev eth0 root 2>$null
    }
    Write-Host "[heal] OK a $(Get-Date -Format o) (noeuds nettoyes : $($nodes -join ', '))"
}

function Invoke-InjectP1Full {
    # Isole le PRIMAIRE des DEUX replicas simultanement -- vraie perte de
    # quorum, contrairement a inject-p1 (une seule paire isolee, quorum
    # preserve via l'autre replica avec synchronous.number=1).
    $primary = Get-CurrentPrimary
    if (-not $primary) { Write-Error "[inject-p1-full] Primaire introuvable."; return }
    $allPods = Get-AllInstancePods
    $replicas = @($allPods | Where-Object { $_ -ne $primary })
    if ($replicas.Count -lt 2) { Write-Error "[inject-p1-full] Moins de 2 replicas trouves."; return }

    $primaryNode = Get-PodNode $primary
    $primaryIp   = kubectl -n $NS get pod $primary -o jsonpath='{.status.podIP}'

    Write-Host "[inject-p1-full] Isolation complete du primaire $primary ($primaryNode) de TOUS ses replicas :"
    foreach ($r in $replicas) {
        $rNode = Get-PodNode $r
        $rIp = kubectl -n $NS get pod $r -o jsonpath='{.status.podIP}'
        Write-Host "  -> $r ($rNode)"
        docker exec $primaryNode iptables -I FORWARD 1 -s $primaryIp -d $rIp -j DROP
        docker exec $primaryNode iptables -I FORWARD 1 -s $rIp -d $primaryIp -j DROP
        docker exec $rNode       iptables -I FORWARD 1 -s $primaryIp -d $rIp -j DROP
        docker exec $rNode       iptables -I FORWARD 1 -s $rIp -d $primaryIp -j DROP
    }
    Write-Host "[inject-p1-full] Fault injectee a $(Get-Date -Format o) (primaire=$primary, replicas isoles=$($replicas -join ', '))"
}

function Invoke-InjectP2Full {
    # Bloque le sens replica->primaire pour LES DEUX replicas simultanement
    # (le primaire peut toujours ENVOYER le WAL aux deux) -- equivalent
    # asymetrique de inject-p1-full. Teste si le blocage des ecritures cote
    # CNPG depend d'une vraie coupure bidirectionnelle ou se declenche deja
    # sur une simple perte d'accuses de reception.
    $primary = Get-CurrentPrimary
    if (-not $primary) { Write-Error "[inject-p2-full] Primaire introuvable."; return }
    $allPods = Get-AllInstancePods
    $replicas = @($allPods | Where-Object { $_ -ne $primary })
    if ($replicas.Count -lt 2) { Write-Error "[inject-p2-full] Moins de 2 replicas trouves."; return }

    $primaryNode = Get-PodNode $primary
    $primaryIp   = kubectl -n $NS get pod $primary -o jsonpath='{.status.podIP}'

    Write-Host "[inject-p2-full] Blocage replica->primaire pour TOUS les replicas (primaire->replica reste OK) :"
    foreach ($r in $replicas) {
        $rNode = Get-PodNode $r
        $rIp = kubectl -n $NS get pod $r -o jsonpath='{.status.podIP}'
        Write-Host "  -> $r ($rNode) : $r -> $primary bloque"
        docker exec $rNode       iptables -I FORWARD 1 -s $rIp -d $primaryIp -j DROP
        docker exec $primaryNode iptables -I FORWARD 1 -s $rIp -d $primaryIp -j DROP
    }
    Write-Host "[inject-p2-full] Fault injectee a $(Get-Date -Format o) (primaire=$primary, replicas=$($replicas -join ', '))"
}

function Invoke-WriterStart {
    $creds = Get-PgCredentials
    if (-not $creds) { Write-Error "[writer-start] Identifiants introuvables."; return }

    $script = $WriterScriptTemplate.Replace("__PGPASS__", $creds.pass).Replace("__PGUSER__", $creds.user).Replace("__NS__", $NS)
    $script = $script -replace "`r`n", "`n" -replace "`r", "`n"
    $tmpFile = Join-Path $env:TEMP "writer.sh"
    [System.IO.File]::WriteAllText($tmpFile, $script, [System.Text.UTF8Encoding]::new($false))

    Push-Location $env:TEMP
    kubectl cp "writer.sh" "${NS}/role-observer:/tmp/writer.sh"
    Pop-Location

    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/writer.pid && kill -- -`$(cat /tmp/writer.pid) 2>/dev/null; rm -f /tmp/writer.out /tmp/writer_timed.log; true" 2>$null | Out-Null
    kubectl -n $NS exec role-observer -- sh -c "setsid sh /tmp/writer.sh </dev/null >/tmp/writer_loop.out 2>&1 & echo `$! > /tmp/writer.pid" 2>$null | Out-Null

    # Verification obligatoire : on a deja observe un writer-start qui rend la
    # main sans erreur visible mais sans qu'aucun process ne demarre reellement
    # (writer-stop suivant renvoyait alors les donnees du run PRECEDENT, ce qui
    # a fausse une campagne entiere sans avertissement). On attend un court
    # instant puis on verifie qu'un process writer.sh tourne vraiment ; sinon
    # on hurle plutot que de laisser passer une mesure silencieusement vide.
    Start-Sleep -Milliseconds 800
    $psCheck = kubectl -n $NS exec role-observer -- sh -c "pgrep -f 'sh /tmp/writer.sh' 2>/dev/null || ps | grep '[w]riter.sh'" 2>$null
    if (-not $psCheck) {
        Write-Error "[writer-start] ECHEC : aucun processus writer.sh detecte apres lancement. Le prochain writer-stop renverrait des donnees perimees ou vides -- NE PAS continuer ce run tel quel."
        return
    }
    Remove-Item -ErrorAction SilentlyContinue (Join-Path $LogDir "writer_timed.csv")
    Write-Host "[writer-start] Generateur d'ecriture lance (1 INSERT/0.1s vers le primaire courant via pg-cnpg-rw). Process confirme actif."
}

function Invoke-WriterStop {
    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/writer.pid && kill -- -`$(cat /tmp/writer.pid) 2>/dev/null; true" 2>$null | Out-Null

    $raw = kubectl -n $NS exec role-observer -- sh -c "cat /tmp/writer_timed.log 2>/dev/null" 2>$null
    $writerLog = Join-Path $LogDir "writer_timed.csv"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("t_start,t_end,status")
    $okCount = 0; $failCount = 0
    if ($raw) {
        foreach ($l in $raw) {
            $lines.Add($l)
            if ($l -match ",ok$") { $okCount++ } elseif ($l -match ",fail$") { $failCount++ }
        }
    }
    [System.IO.File]::WriteAllLines($writerLog, $lines)

    Write-Host "[writer-stop] Generateur arrete. $okCount INSERT reussis, $failCount echecs. Detail par tentative : $writerLog"
}

function Invoke-ProbeStart {
    $creds = Get-PgCredentials
    if (-not $creds) {
        Write-Error "[probe-start] Impossible de recuperer les identifiants PG -- le cluster est-il pret ?"
        return
    }

    # Recupere les 3 pods d'instance (nommage CNPG standard : <cluster>-1/-2/-3)
    $instancePods = kubectl -n $NS get pods -l "cnpg.io/cluster=$ClusterName" -o jsonpath='{.items[*].metadata.name}'
    $podList = $instancePods -split '\s+' | Where-Object { $_ }
    if ($podList.Count -lt 3) {
        Write-Error "[probe-start] Moins de 3 pods d'instance trouves ($($podList.Count)). Cluster pas encore pret ? (.\deploy_cnpg.ps1 status)"
        return
    }

    $ips = @{}
    foreach ($p in $podList) {
        $ips[$p] = kubectl -n $NS get pod $p -o jsonpath='{.status.podIP}'
    }
    Write-Host "[probe-start] Instances : $($podList -join ', ')"
    Write-Host "[probe-start] IPs : $(($ips.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"

    # Deploie un pod observateur dedie (image postgres:16-alpine -> psql deja present)
    $observerYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: role-observer
  namespace: $NS
spec:
  containers:
    - name: observer
      image: postgres:16-alpine
      command: ["sh", "-c", "sleep infinity"]
"@
    $observerYaml | kubectl apply -f -
    kubectl -n $NS wait --for=condition=Ready pod/role-observer --timeout=60s

    $script = $RoleProbeTemplate
    $script = $script.Replace("__PGPASS__", $creds.pass).Replace("__PGUSER__", $creds.user)
    $script = $script.Replace("__NAME1__", $podList[0]).Replace("__IP1__", $ips[$podList[0]])
    $script = $script.Replace("__NAME2__", $podList[1]).Replace("__IP2__", $ips[$podList[1]])
    $script = $script.Replace("__NAME3__", $podList[2]).Replace("__IP3__", $ips[$podList[2]])
    $script = $script -replace "`r`n", "`n" -replace "`r", "`n"

    $tmpFile = Join-Path $env:TEMP "role_probe.sh"
    [System.IO.File]::WriteAllText($tmpFile, $script, [System.Text.UTF8Encoding]::new($false))

    Push-Location $env:TEMP
    kubectl cp "role_probe.sh" "${NS}/role-observer:/tmp/role_probe.sh"
    Pop-Location

    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/probe.pid && kill `$(cat /tmp/probe.pid) 2>/dev/null; true" 2>$null | Out-Null
    kubectl -n $NS exec role-observer -- sh -c "setsid sh /tmp/role_probe.sh </dev/null >/tmp/probe.out 2>&1 & echo `$! > /tmp/probe.pid" 2>$null | Out-Null

    Write-Host "[probe-start] Observateur de role lance (pod role-observer)."
}

function Invoke-ProbeStatus {
    $pidVal = kubectl -n $NS exec role-observer -- sh -c "cat /tmp/probe.pid 2>/dev/null"
    if ($pidVal) {
        $alive = kubectl -n $NS exec role-observer -- sh -c "kill -0 $pidVal 2>/dev/null && echo RUNNING || echo STOPPED-mort"
    } else {
        $alive = "STOPPED (pas de fichier PID)"
    }
    $lines = kubectl -n $NS exec role-observer -- sh -c "wc -l < /tmp/role.log 2>/dev/null || echo 0"
    Write-Host "[probe-status] role-observer: $alive -- $lines lignes"
    Write-Host "[probe-status] Dernieres lignes :"
    kubectl -n $NS exec role-observer -- sh -c "tail -n 6 /tmp/role.log 2>/dev/null"
    Write-Host ""
    Write-Host "[probe-status] Erreurs eventuelles (psql, connexion...) :"
    kubectl -n $NS exec role-observer -- sh -c "cat /tmp/probe.out 2>/dev/null; cat /tmp/probe_errors.log 2>/dev/null | tail -n 10"
}

function Invoke-ProbeStop {
    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/probe.pid && kill `$(cat /tmp/probe.pid) 2>/dev/null; true" 2>$null | Out-Null
    $raw = kubectl -n $NS exec role-observer -- sh -c "cat /tmp/role.log 2>/dev/null" 2>$null

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("timestamp,instance,is_in_recovery,lsn")
    if ($raw) { foreach ($l in $raw) { $lines.Add($l) } }

    $written = $false
    for ($attempt = 1; $attempt -le 5 -and -not $written; $attempt++) {
        try { [System.IO.File]::WriteAllLines($RoleLog, $lines); $written = $true }
        catch { Write-Host "[probe-stop] Fichier verrouille (tentative $attempt/5)..."; Start-Sleep -Seconds 2 }
    }
    if ($written) {
        Write-Host "[probe-stop] $($lines.Count - 1) mesures enregistrees dans $RoleLog"
    } else {
        Write-Error "[probe-stop] Echec d'ecriture apres 5 tentatives."
    }
}

function Invoke-Teardown {
    Invoke-ProbeStop
    kubectl delete pod role-observer -n $NS --ignore-not-found
    kubectl delete cluster $ClusterName -n $NS --ignore-not-found
    kubectl delete namespace $NS --ignore-not-found
    Write-Host "[teardown] Namespace '$NS' supprime. Operateur CNPG (cnpg-system) NON supprime -- reutilisable."
}

switch ($Action) {
    "install-operator"  { Invoke-InstallOperator }
    "deploy-cluster"    { Invoke-DeployCluster }
    "status"            { Invoke-Status }
    "get-credentials"   { Invoke-GetCredentials }
    "writer-start"      { Invoke-WriterStart }
    "writer-stop"       { Invoke-WriterStop }
    "row-count"         { Invoke-RowCount }
    "row-count-upto"    { Invoke-RowCountUpTo }
    "inject-p1"         { Invoke-InjectP1 }
    "inject-p1-full"    { Invoke-InjectP1Full }
    "inject-p2"         { Invoke-InjectP2 }
    "inject-p2-full"    { Invoke-InjectP2Full }
    "inject-p3"         { Invoke-InjectP3 }
    "inject-p3-full"    { Invoke-InjectP3Full }
    "heal"              { Invoke-Heal }
    "probe-start"       { Invoke-ProbeStart }
    "probe-status"      { Invoke-ProbeStatus }
    "probe-stop"        { Invoke-ProbeStop }
    "teardown"          { Invoke-Teardown }
}
