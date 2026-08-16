<#
==============================================================================
 deploy_patroni.ps1 -- Deploiement Patroni minimal (DCS = Kubernetes, pas
 d'etcd) + observateur de role/LSN + generateur d'ecriture + injection de
 pannes reseau P1/P1-full/P2/P2-full/P3.
==============================================================================
 Meme architecture que deploy_cnpg.ps1 (voir ce fichier pour le detail des
 principes valides : sondage in-pod, kubectl cp pour le transfert de script,
 setsid pour le detachement, resolution dynamique primaire/noeud/IP,
 evitement du noeud control-plane pour eviter le confond K8s control-plane).

 PREREQUIS (a faire une seule fois, EN DEHORS de ce script) :
   git clone --depth 1 https://github.com/patroni/patroni.git patroni-src
   cd patroni-src
   docker build -t patroni:local .
   cd ..
   kind load docker-image patroni:local --name pi-cluster

 Usage :
   .\deploy_patroni.ps1 deploy-cluster
   .\deploy_patroni.ps1 status
   .\deploy_patroni.ps1 writer-start
   .\deploy_patroni.ps1 writer-stop
   .\deploy_patroni.ps1 probe-start
   .\deploy_patroni.ps1 probe-status
   .\deploy_patroni.ps1 probe-stop
   .\deploy_patroni.ps1 inject-p1 [-TargetReplica <pod>]
   .\deploy_patroni.ps1 inject-p1-full
   .\deploy_patroni.ps1 inject-p2 [-TargetReplica <pod>]
   .\deploy_patroni.ps1 inject-p2-full
   .\deploy_patroni.ps1 inject-p3 [-TargetReplica <pod>]
   .\deploy_patroni.ps1 heal
   .\deploy_patroni.ps1 teardown
==============================================================================
#>

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("deploy-cluster","status","writer-start","writer-stop","probe-start","probe-status","probe-stop","inject-p1","inject-p1-full","inject-p2","inject-p2-full","inject-p3","heal","teardown")]
    [string]$Action,
    [string]$TargetReplica = ""
)

$ErrorActionPreference = "Continue"

$NS          = "patroni"
$ClusterName = "patronidemo"
$Image       = "patroni:local"

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LogDir    = Join-Path $ScriptDir "patroni_logs"
$RoleLog   = Join-Path $LogDir "role.csv"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ------------------------------------------------------------------------------
function Invoke-DeployCluster {
    kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

    # Mots de passe generes localement (pas les valeurs de demo du depot).
    $superPass = -join ((48..57)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_})
    $replPass  = -join ((48..57)+(97..122) | Get-Random -Count 20 | ForEach-Object {[char]$_})
    $superPassB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($superPass))
    $replPassB64  = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($replPass))

    $manifest = @"
apiVersion: v1
kind: Service
metadata:
  name: $ClusterName-config
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName}
spec:
  clusterIP: None
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $ClusterName
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName}
spec:
  replicas: 3
  serviceName: $ClusterName
  selector:
    matchLabels: {application: patroni, cluster-name: $ClusterName}
  template:
    metadata:
      labels: {application: patroni, cluster-name: $ClusterName}
    spec:
      serviceAccountName: $ClusterName
      # Tolerance + anti-affinite : repartir les 3 instances sur les 3 noeuds
      # (control-plane + 2 workers), comme pour CNPG.
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: {application: patroni, cluster-name: $ClusterName}
                topologyKey: kubernetes.io/hostname
      containers:
        - name: $ClusterName
          image: $Image
          imagePullPolicy: IfNotPresent
          readinessProbe:
            httpGet: {scheme: HTTP, path: /readiness, port: 8008}
            initialDelaySeconds: 3
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          ports:
            - containerPort: 8008
            - containerPort: 5432
          volumeMounts:
            - mountPath: /home/postgres/pgdata
              name: pgdata
          env:
            - name: PATRONI_KUBERNETES_POD_IP
              valueFrom: {fieldRef: {fieldPath: status.podIP}}
            - name: PATRONI_KUBERNETES_NAMESPACE
              valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
            - name: PATRONI_KUBERNETES_BYPASS_API_SERVICE
              value: 'true'
            - name: PATRONI_KUBERNETES_USE_ENDPOINTS
              value: 'true'
            - name: PATRONI_KUBERNETES_LABELS
              value: '{application: patroni, cluster-name: $ClusterName}'
            - name: PATRONI_SUPERUSER_USERNAME
              value: postgres
            - name: PATRONI_SUPERUSER_PASSWORD
              valueFrom: {secretKeyRef: {name: $ClusterName, key: superuser-password}}
            - name: PATRONI_REPLICATION_USERNAME
              value: standby
            - name: PATRONI_REPLICATION_PASSWORD
              valueFrom: {secretKeyRef: {name: $ClusterName, key: replication-password}}
            - name: PATRONI_SCOPE
              value: $ClusterName
            - name: PATRONI_NAME
              valueFrom: {fieldRef: {fieldPath: metadata.name}}
            - name: PATRONI_POSTGRESQL_DATA_DIR
              value: /home/postgres/pgdata/pgroot/data
            - name: PATRONI_POSTGRESQL_PGPASS
              value: /tmp/pgpass
            - name: PATRONI_POSTGRESQL_LISTEN
              value: '0.0.0.0:5432'
            - name: PATRONI_RESTAPI_LISTEN
              value: '0.0.0.0:8008'
      terminationGracePeriodSeconds: 0
      volumes:
        - name: pgdata
          emptyDir: {}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: $ClusterName
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName}
subsets: []
---
apiVersion: v1
kind: Service
metadata:
  name: $ClusterName
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName}
spec:
  type: ClusterIP
  ports:
    - {port: 5432, targetPort: 5432}
---
apiVersion: v1
kind: Service
metadata:
  name: $ClusterName-repl
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName, role: replica}
spec:
  type: ClusterIP
  selector: {application: patroni, cluster-name: $ClusterName, role: replica}
  ports:
    - {port: 5432, targetPort: 5432}
---
apiVersion: v1
kind: Secret
metadata:
  name: $ClusterName
  namespace: $NS
  labels: {application: patroni, cluster-name: $ClusterName}
type: Opaque
data:
  superuser-password: $superPassB64
  replication-password: $replPassB64
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ClusterName
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ClusterName
  namespace: $NS
rules:
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [create, get, list, patch, update, watch, delete, deletecollection]
  - apiGroups: [""]
    resources: [endpoints]
    verbs: [get, patch, update, create, list, watch, delete, deletecollection]
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, patch, update, watch]
  - apiGroups: [""]
    resources: [services]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $ClusterName
  namespace: $NS
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: $ClusterName}
subjects:
  - {kind: ServiceAccount, name: $ClusterName, namespace: $NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: patroni-k8s-ep-access
rules:
  - apiGroups: [""]
    resources: [endpoints]
    resourceNames: [kubernetes]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: patroni-k8s-ep-access
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: patroni-k8s-ep-access}
subjects:
  - {kind: ServiceAccount, name: $ClusterName, namespace: $NS}
"@

    $manifest | kubectl apply -f -

    # Sauvegarde locale du mot de passe superuser -- necessaire pour les
    # sondes/le generateur d'ecriture, pas recuperable depuis le Secret sans
    # decoder a nouveau (equivalent possible, mais plus simple ainsi).
    $credFile = Join-Path $LogDir "credentials.txt"
    "postgres:$superPass" | Set-Content -Path $credFile
    Write-Host "[deploy-cluster] Cluster '$ClusterName' cree dans '$NS'. Mot de passe superuser sauvegarde dans $credFile"
    Write-Host "[deploy-cluster] Ca peut prendre 1-2 minutes. Suivez avec : .\deploy_patroni.ps1 status"
}

function Invoke-Status {
    kubectl -n $NS get pods -o wide -L role
}

function Get-PgCredentials {
    $credFile = Join-Path $LogDir "credentials.txt"
    if (-not (Test-Path $credFile)) { return $null }
    $parts = (Get-Content $credFile) -split ":"
    return @{ user = $parts[0]; pass = $parts[1] }
}

# ------------------------------------------------------------------------------
function Get-CurrentPrimary {
    # Patroni etiquette lui-meme ses pods (role=master / role=replica).
    return (kubectl -n $NS get pods -l "cluster-name=$ClusterName,role=master" -o jsonpath='{.items[0].metadata.name}')
}

function Get-PodNode {
    param([string]$Pod)
    return (kubectl -n $NS get pod $Pod -o jsonpath='{.spec.nodeName}')
}

function Get-AllInstancePods {
    $raw = kubectl -n $NS get pods -l "cluster-name=$ClusterName" -o jsonpath='{.items[*].metadata.name}'
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
        $nonCpReplicas = @($replicas | Where-Object { (Get-PodNode $_) -ne "pi-cluster-control-plane" })
        $target = if ($nonCpReplicas.Count -gt 0) { $nonCpReplicas[0] } else {
            Write-Warning "[inject] Tous les replicas disponibles sont sur le control-plane."
            $replicas[0]
        }
    }

    $primaryNode = Get-PodNode $primary
    $targetNode  = Get-PodNode $target
    $primaryIp   = kubectl -n $NS get pod $primary -o jsonpath='{.status.podIP}'
    $targetIp    = kubectl -n $NS get pod $target -o jsonpath='{.status.podIP}'

    if ($primaryNode -eq "pi-cluster-control-plane" -or $targetNode -eq "pi-cluster-control-plane") {
        Write-Warning "[inject] Le primaire ou la cible tourne sur le control-plane -- interpretez avec prudence."
    }
    if ($primaryNode -eq $targetNode) {
        Write-Warning "[inject] $primary et $target sont sur le MEME noeud ($primaryNode) -- injection FORWARD sans effet. Utilisez -TargetReplica."
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
    docker exec $t.PrimaryNode iptables -A FORWARD -s $t.PrimaryIp -d $t.TargetIp -j DROP
    docker exec $t.PrimaryNode iptables -A FORWARD -s $t.TargetIp -d $t.PrimaryIp -j DROP
    docker exec $t.TargetNode  iptables -A FORWARD -s $t.PrimaryIp -d $t.TargetIp -j DROP
    docker exec $t.TargetNode  iptables -A FORWARD -s $t.TargetIp -d $t.PrimaryIp -j DROP
    Write-Host "[inject-p1] Fault injectee a $(Get-Date -Format o) (primaire=$($t.Primary), cible=$($t.Target))"
}

function Invoke-InjectP1Full {
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
        docker exec $primaryNode iptables -A FORWARD -s $primaryIp -d $rIp -j DROP
        docker exec $primaryNode iptables -A FORWARD -s $rIp -d $primaryIp -j DROP
        docker exec $rNode       iptables -A FORWARD -s $primaryIp -d $rIp -j DROP
        docker exec $rNode       iptables -A FORWARD -s $rIp -d $primaryIp -j DROP
    }
    Write-Host "[inject-p1-full] Fault injectee a $(Get-Date -Format o) (primaire=$primary, replicas=$($replicas -join ', '))"
}

function Invoke-InjectP2 {
    $t = Resolve-InjectionTargets -PreferredReplica $TargetReplica
    if (-not $t) { return }
    Write-Host "[inject-p2] Partition asymetrique : $($t.Target) -> $($t.Primary) bloque, $($t.Primary) -> $($t.Target) OK"
    docker exec $t.TargetNode  iptables -A FORWARD -s $t.TargetIp -d $t.PrimaryIp -j DROP
    docker exec $t.PrimaryNode iptables -A FORWARD -s $t.TargetIp -d $t.PrimaryIp -j DROP
    Write-Host "[inject-p2] Fault injectee a $(Get-Date -Format o) (primaire=$($t.Primary), cible=$($t.Target))"
}

function Invoke-InjectP2Full {
    $primary = Get-CurrentPrimary
    if (-not $primary) { Write-Error "[inject-p2-full] Primaire introuvable."; return }
    $allPods = Get-AllInstancePods
    $replicas = @($allPods | Where-Object { $_ -ne $primary })
    if ($replicas.Count -lt 2) { Write-Error "[inject-p2-full] Moins de 2 replicas trouves."; return }
    $primaryNode = Get-PodNode $primary
    $primaryIp   = kubectl -n $NS get pod $primary -o jsonpath='{.status.podIP}'
    Write-Host "[inject-p2-full] Blocage replica->primaire pour TOUS les replicas :"
    foreach ($r in $replicas) {
        $rNode = Get-PodNode $r
        $rIp = kubectl -n $NS get pod $r -o jsonpath='{.status.podIP}'
        Write-Host "  -> $r ($rNode) : $r -> $primary bloque"
        docker exec $rNode       iptables -A FORWARD -s $rIp -d $primaryIp -j DROP
        docker exec $primaryNode iptables -A FORWARD -s $rIp -d $primaryIp -j DROP
    }
    Write-Host "[inject-p2-full] Fault injectee a $(Get-Date -Format o) (primaire=$primary, replicas=$($replicas -join ', '))"
}

function Invoke-InjectP3 {
    $t = Resolve-InjectionTargets -PreferredReplica $TargetReplica
    if (-not $t) { return }
    Write-Host "[inject-p3] Degradation graduee sur $($t.Target) ($($t.TargetNode)), 4 paliers"
    $steps = @(
        @{delay="50ms";  loss="0%"}, @{delay="150ms"; loss="2%"},
        @{delay="400ms"; loss="5%"}, @{delay="800ms"; loss="15%"}
    )
    foreach ($s in $steps) {
        docker exec $t.TargetNode tc qdisc replace dev eth0 root netem delay $s.delay loss $s.loss 2>$null
        if ($LASTEXITCODE -ne 0) { docker exec $t.TargetNode tc qdisc add dev eth0 root netem delay $s.delay loss $s.loss }
        Write-Host "  palier: delay=$($s.delay) loss=$($s.loss) @ $(Get-Date -Format o)"
        Start-Sleep -Seconds 15
    }
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
    result=$(psql -h "$ip" -U __PGUSER__ -d postgres -tAc "SELECT pg_is_in_recovery(), CASE WHEN pg_is_in_recovery() THEN COALESCE(pg_last_wal_replay_lsn()::text,'') ELSE pg_current_wal_lsn()::text END;" -w 2>>/tmp/probe_errors.log)
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

function Invoke-ProbeStart {
    $creds = Get-PgCredentials
    if (-not $creds) { Write-Error "[probe-start] Identifiants introuvables -- deploy-cluster a-t-il ete lance ?"; return }

    $instancePods = Get-AllInstancePods
    if ($instancePods.Count -lt 3) { Write-Error "[probe-start] Moins de 3 pods trouves. Cluster pas pret ?"; return }

    $ips = @{}
    foreach ($p in $instancePods) { $ips[$p] = kubectl -n $NS get pod $p -o jsonpath='{.status.podIP}' }
    Write-Host "[probe-start] Instances : $($instancePods -join ', ')"

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
    $script = $script.Replace("__NAME1__", $instancePods[0]).Replace("__IP1__", $ips[$instancePods[0]])
    $script = $script.Replace("__NAME2__", $instancePods[1]).Replace("__IP2__", $ips[$instancePods[1]])
    $script = $script.Replace("__NAME3__", $instancePods[2]).Replace("__IP3__", $ips[$instancePods[2]])
    $script = $script -replace "`r`n", "`n" -replace "`r", "`n"

    $tmpFile = Join-Path $env:TEMP "role_probe_patroni.sh"
    [System.IO.File]::WriteAllText($tmpFile, $script, [System.Text.UTF8Encoding]::new($false))
    Push-Location $env:TEMP
    kubectl cp "role_probe_patroni.sh" "${NS}/role-observer:/tmp/role_probe.sh"
    Pop-Location

    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/probe.pid && kill `$(cat /tmp/probe.pid) 2>/dev/null; true" 2>$null | Out-Null
    kubectl -n $NS exec role-observer -- sh -c "setsid sh /tmp/role_probe.sh </dev/null >/tmp/probe.out 2>&1 & echo `$! > /tmp/probe.pid" 2>$null | Out-Null
    Write-Host "[probe-start] Observateur de role lance."
}

function Invoke-ProbeStatus {
    $pidVal = kubectl -n $NS exec role-observer -- sh -c "cat /tmp/probe.pid 2>/dev/null"
    if ($pidVal) {
        $alive = kubectl -n $NS exec role-observer -- sh -c "kill -0 $pidVal 2>/dev/null && echo RUNNING || echo STOPPED-mort"
    } else { $alive = "STOPPED (pas de fichier PID)" }
    $lines = kubectl -n $NS exec role-observer -- sh -c "wc -l < /tmp/role.log 2>/dev/null || echo 0"
    Write-Host "[probe-status] role-observer: $alive -- $lines lignes"
    Write-Host "[probe-status] Dernieres lignes :"
    kubectl -n $NS exec role-observer -- sh -c "tail -n 6 /tmp/role.log 2>/dev/null"
    Write-Host ""
    Write-Host "[probe-status] Erreurs eventuelles :"
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
    if ($written) { Write-Host "[probe-stop] $($lines.Count - 1) mesures enregistrees dans $RoleLog" }
    else { Write-Error "[probe-stop] Echec d'ecriture apres 5 tentatives." }
}

# ------------------------------------------------------------------------------
$WriterScriptTemplate = @'
#!/bin/sh
export PGPASSWORD="__PGPASS__"
export PGCONNECT_TIMEOUT=1
psql -h __SVCNAME__.__NS__.svc -U __PGUSER__ -d postgres -c "CREATE TABLE IF NOT EXISTS rpotest (id serial primary key, ts timestamp default now());" >/tmp/writer_init.out 2>&1
rm -f /tmp/writer_timed.log
while true; do
  t0=$(date +%s)
  if psql -h __SVCNAME__.__NS__.svc -U __PGUSER__ -d postgres -c "INSERT INTO rpotest DEFAULT VALUES;" >/tmp/writer_last.out 2>&1; then
    status=ok
  else
    status=fail
  fi
  t1=$(date +%s)
  echo "$t0,$t1,$status" >> /tmp/writer_timed.log
  sleep 0.1
done
'@

function Invoke-WriterStart {
    $creds = Get-PgCredentials
    if (-not $creds) { Write-Error "[writer-start] Identifiants introuvables."; return }
    $script = $WriterScriptTemplate.Replace("__PGPASS__", $creds.pass).Replace("__PGUSER__", $creds.user).Replace("__NS__", $NS).Replace("__SVCNAME__", $ClusterName)
    $script = $script -replace "`r`n", "`n" -replace "`r", "`n"
    $tmpFile = Join-Path $env:TEMP "writer_patroni.sh"
    [System.IO.File]::WriteAllText($tmpFile, $script, [System.Text.UTF8Encoding]::new($false))
    Push-Location $env:TEMP
    kubectl cp "writer_patroni.sh" "${NS}/role-observer:/tmp/writer.sh"
    Pop-Location
    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/writer.pid && kill `$(cat /tmp/writer.pid) 2>/dev/null; rm -f /tmp/writer.out; true" 2>$null | Out-Null
    kubectl -n $NS exec role-observer -- sh -c "setsid sh /tmp/writer.sh </dev/null >/tmp/writer_loop.out 2>&1 & echo `$! > /tmp/writer.pid" 2>$null | Out-Null
    Write-Host "[writer-start] Generateur d'ecriture lance (1 INSERT/0.1s vers le primaire courant via $ClusterName)."
}

function Invoke-WriterStop {
    kubectl -n $NS exec role-observer -- sh -c "test -f /tmp/writer.pid && kill `$(cat /tmp/writer.pid) 2>/dev/null; true" 2>$null | Out-Null
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
    Write-Host "[writer-stop] Generateur arrete. $okCount INSERT reussis, $failCount echecs. Detail : $writerLog"
}

function Invoke-Teardown {
    Invoke-ProbeStop
    kubectl delete pod role-observer -n $NS --ignore-not-found
    kubectl delete namespace $NS --ignore-not-found
    Write-Host "[teardown] Namespace '$NS' supprime."
}

switch ($Action) {
    "deploy-cluster"    { Invoke-DeployCluster }
    "status"            { Invoke-Status }
    "writer-start"      { Invoke-WriterStart }
    "writer-stop"       { Invoke-WriterStop }
    "inject-p1"         { Invoke-InjectP1 }
    "inject-p1-full"    { Invoke-InjectP1Full }
    "inject-p2"         { Invoke-InjectP2 }
    "inject-p2-full"    { Invoke-InjectP2Full }
    "inject-p3"         { Invoke-InjectP3 }
    "heal"              { Invoke-Heal }
    "probe-start"       { Invoke-ProbeStart }
    "probe-status"      { Invoke-ProbeStatus }
    "probe-stop"        { Invoke-ProbeStop }
    "teardown"          { Invoke-Teardown }
}
