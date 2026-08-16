<#
==============================================================================
 probe_worker.ps1 -- Worker de sondage reseau
==============================================================================
 Lance en PROCESSUS SEPARE (Start-Process) par
 pilot_p2_partition_validation.ps1, PAS en PowerShell Job. Les parametres
 arrivent comme de simples chaines en ligne de commande -- le mecanisme le
 plus simple et le plus fiable de PowerShell, sans serialisation d'objets
 complexes (Hashtable, etc.) entre processus.

 Ecrit en continu dans -CsvLog jusqu'a etre arrete (Stop-Process, fait par
 probe-stop / teardown dans le script principal). Les erreurs eventuelles
 vont dans -ErrLog plutot que de disparaitre silencieusement.

 Ce fichier DOIT rester a cote de pilot_p2_partition_validation.ps1 (meme
 dossier) : le script principal le localise via $PSScriptRoot.
==============================================================================
#>

param(
    [Parameter(Mandatory = $true)][string]$NS,
    [Parameter(Mandatory = $true)][string]$CsvLog,
    [Parameter(Mandatory = $true)][string]$ErrLog,
    [Parameter(Mandatory = $true)][int]$IntervalMs,
    [Parameter(Mandatory = $true)][string]$IpPrimary,
    [Parameter(Mandatory = $true)][string]$IpReplicaA,
    [Parameter(Mandatory = $true)][string]$IpReplicaB
)

$ErrorActionPreference = "Continue"

$IPs = @{
    "primary"   = $IpPrimary
    "replica-a" = $IpReplicaA
    "replica-b" = $IpReplicaB
}

$pairs = @(
    ,@("primary","replica-a")
    ,@("replica-a","primary")
    ,@("primary","replica-b")
    ,@("replica-b","primary")
    ,@("replica-a","replica-b")
    ,@("replica-b","replica-a")
)

while ($true) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    foreach ($pair in $pairs) {
        try {
            $src = $pair[0]; $dst = $pair[1]
            $dstIp = $IPs[$dst]
            $out = kubectl -n $NS exec $src -- ping -c 1 -W 1 $dstIp 2>$null
            $outText = ($out -join "`n")
            $rtt = ""
            $status = "timeout"
            $m = [regex]::Match($outText, 'time=([\d\.]+)')
            if ($m.Success) {
                $rtt = $m.Groups[1].Value
                $status = "ok"
            }
            "$ts,$src,$dst,$src->$dst,$rtt,$status" | Add-Content -Path $CsvLog
        } catch {
            "$ts,ERROR,$($pair -join '->'),$($_.Exception.Message)" | Add-Content -Path $ErrLog
        }
    }
    Start-Sleep -Milliseconds $IntervalMs
}
