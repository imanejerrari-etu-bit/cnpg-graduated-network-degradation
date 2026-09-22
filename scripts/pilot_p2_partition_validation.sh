#!/usr/bin/env bash
# ==============================================================================
# PILOT — Validation de la mesurabilité des pannes réseau P1/P2/P3 sur kind
# ==============================================================================
#
# Objectif : avant de lancer la campagne complète (CNPG vs Patroni, n=30-50),
# valider techniquement que kind permet de produire une partition ASYMÉTRIQUE
# (P2) propre — c'est-à-dire A->B bloqué mais B->A fonctionnel — et de la
# distinguer sans ambiguïté d'une partition symétrique (P1) dans les logs.
#
# Ce pilote N'UTILISE PAS CNPG/Patroni : 3 pods busybox légers suffisent pour
# valider la couche d'injection de fautes réseau. On ajoute la vraie base de
# données seulement après un GO sur ce pilote (cf. PILOT_PROTOCOL.md).
#
# ADAPTÉ À VOTRE ENVIRONNEMENT RÉEL (cluster "pi-cluster" déjà existant,
# 1 control-plane + 2 workers seulement, CNI kindnet, k8s v1.27.3) :
#   - Pas de création de cluster : on réutilise pi-cluster tel quel, dans un
#     nouveau namespace "pilot" isolé de vos namespaces mongodb-pi/rpo-ycsb.
#   - Seulement 2 workers dispo -> le 3e pod ("replica-b") est placé sur le
#     control-plane, avec une tolérance du taint NoSchedule.
#
# Prérequis : kind, kubectl, docker (déjà en place chez vous).
#
# Usage :
#   ./pilot_p2_partition_validation.sh setup      # crée le namespace + les 3 pods
#   ./pilot_p2_partition_validation.sh probe-start # lance les sondes en fond
#   ./pilot_p2_partition_validation.sh inject-p1   # partition symétrique
#   ./pilot_p2_partition_validation.sh heal
#   ./pilot_p2_partition_validation.sh inject-p2   # partition asymétrique
#   ./pilot_p2_partition_validation.sh heal
#   ./pilot_p2_partition_validation.sh inject-p3   # dégradation graduée (tc netem)
#   ./pilot_p2_partition_validation.sh heal
#   ./pilot_p2_partition_validation.sh probe-stop
#   ./pilot_p2_partition_validation.sh report      # résumé + verdict GO/NO-GO
#   ./pilot_p2_partition_validation.sh teardown
#
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="pi-cluster"          # cluster existant, PAS recréé par ce script
NS="pilot"
LOGDIR="./pilot_logs"
PROBE_INTERVAL_S=0.5
PROBE_PID_FILE="${LOGDIR}/probe.pid"
CSV_LOG="${LOGDIR}/probes.csv"

# Mapping rôle -> nœud réel de votre cluster (cf. `kubectl get nodes -o wide`)
declare -A NODE_OF=(
  [primary]="pi-cluster-control-plane"
  [replica-a]="pi-cluster-worker"
  [replica-b]="pi-cluster-worker2"
)

mkdir -p "${LOGDIR}"

# ------------------------------------------------------------------------------
# Namespace + 3 pods de sonde, un par nœud (condition nécessaire pour que les
# règles iptables/tc appliquées au niveau du nœud isolent bien le trafic
# pod-à-pod). "primary" est placé sur le control-plane -> il faut tolérer son
# taint NoSchedule.
# ------------------------------------------------------------------------------
setup() {
  echo "[setup] Vérification du cluster '${CLUSTER_NAME}'..."
  kind get clusters | grep -qx "${CLUSTER_NAME}" || { echo "Cluster ${CLUSTER_NAME} introuvable. Abandon."; exit 1; }

  kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

  for role in primary replica-a replica-b; do
    node="${NODE_OF[$role]}"
    tolerations=""
    if [ "${role}" = "primary" ]; then
      # primary est sur le control-plane -> tolérance requise
      tolerations='"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}],'
    fi
    kubectl -n "${NS}" run "${role}" \
      --image=busybox:1.36 --restart=Never \
      --overrides="{\"spec\":{${tolerations}\"nodeName\":\"${node}\"}}" \
      -- sh -c "sleep infinity"
  done

  echo "[setup] Attente que les 3 pods soient Running..."
  kubectl -n "${NS}" wait --for=condition=Ready pod --all --timeout=120s

  echo "[setup] IPs des pods :"
  kubectl -n "${NS}" get pods -o wide
  echo "[setup] OK. 3 pods prêts, un par nœud (primary=control-plane, replica-a=worker, replica-b=worker2)."
}

# ------------------------------------------------------------------------------
# Sondes : depuis CHAQUE pod vers CHAQUE autre pod, ping continu horodaté.
# On lance 6 sondes directionnelles (3 paires x 2 sens) pour pouvoir vérifier
# qu'une panne P2 casse bien un seul sens et pas l'autre.
# ------------------------------------------------------------------------------
probe_start() {
  echo "timestamp,src,dst,direction,rtt_ms,status" > "${CSV_LOG}"

  declare -A IP
  for role in primary replica-a replica-b; do
    IP[$role]=$(kubectl -n "${NS}" get pod "${role}" -o jsonpath='{.status.podIP}')
  done

  echo "[probe-start] IPs capturées : ${IP[primary]} (primary) / ${IP[replica-a]} (replica-a) / ${IP[replica-b]} (replica-b)"

  (
    while true; do
      ts=$(date +%s.%N)
      for pair in "primary replica-a" "replica-a primary" \
                  "primary replica-b" "replica-b primary" \
                  "replica-a replica-b" "replica-b replica-a"; do
        set -- $pair
        src=$1; dst=$2
        rtt=$(kubectl -n "${NS}" exec "${src}" -- \
              ping -c1 -W1 "${IP[$dst]}" 2>/dev/null \
              | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
        if [ -n "${rtt:-}" ]; then
          echo "${ts},${src},${dst},${src}->${dst},${rtt},ok" >> "${CSV_LOG}"
        else
          echo "${ts},${src},${dst},${src}->${dst},,timeout" >> "${CSV_LOG}"
        fi
      done
      sleep "${PROBE_INTERVAL_S}"
    done
  ) &
  echo $! > "${PROBE_PID_FILE}"
  echo "[probe-start] Sondes lancées en fond (PID $(cat ${PROBE_PID_FILE})). Log: ${CSV_LOG}"
}

probe_stop() {
  if [ -f "${PROBE_PID_FILE}" ]; then
    kill "$(cat "${PROBE_PID_FILE}")" 2>/dev/null || true
    rm -f "${PROBE_PID_FILE}"
    echo "[probe-stop] Sondes arrêtées."
  fi
}

# ------------------------------------------------------------------------------
# Injections de fautes : exécutées DANS le netns du nœud hôte du pod cible,
# via `docker exec` sur le conteneur kind-node (c'est un conteneur Docker
# normal, donc iptables/tc s'y appliquent comme sur une VM).
# ------------------------------------------------------------------------------
node_of() {
  echo "${NODE_OF[$1]}"
}

ip_of() {
  kubectl -n "${NS}" get pod "$1" -o jsonpath='{.status.podIP}'
}

inject_p1() {
  # Partition SYMÉTRIQUE complète entre primary et replica-a : DROP dans les
  # deux sens, sur les deux nœuds.
  echo "[inject-p1] Partition symétrique primary <-> replica-a"
  a_ip=$(ip_of replica-a); p_ip=$(ip_of primary)
  docker exec "$(node_of primary)"   iptables -A OUTPUT -d "${a_ip}" -j DROP
  docker exec "$(node_of primary)"   iptables -A INPUT  -s "${a_ip}" -j DROP
  docker exec "$(node_of replica-a)" iptables -A OUTPUT -d "${p_ip}" -j DROP
  docker exec "$(node_of replica-a)" iptables -A INPUT  -s "${p_ip}" -j DROP
  echo "[inject-p1] Fault injectée à $(date +%s.%N)"
}

inject_p2() {
  # Partition ASYMÉTRIQUE : replica-a NE PEUT PLUS ENVOYER vers primary
  # (DROP en sortie sur replica-a + en entrée sur primary), mais primary
  # PEUT toujours envoyer vers replica-a. C'est le cas critique à valider :
  # dans un vrai cluster PG, ça correspond à "le follower ne peut plus faire
  # de heartbeat vers le DCS/primary mais reçoit encore le WAL".
  echo "[inject-p2] Partition asymétrique : replica-a -> primary bloqué, primary -> replica-a OK"
  a_ip=$(ip_of replica-a); p_ip=$(ip_of primary)
  docker exec "$(node_of replica-a)" iptables -A OUTPUT -d "${p_ip}" -j DROP
  docker exec "$(node_of primary)"   iptables -A INPUT  -s "${a_ip}" -j DROP
  echo "[inject-p2] Fault injectée à $(date +%s.%N)"
}

inject_p3() {
  # Dégradation graduée : latence + perte de paquets croissantes sur
  # l'interface eth0 du nœud "replica-a", via tc netem. Rampe simple en
  # 4 paliers de 15s pour le pilote (la campagne finale utilisera une
  # rampe continue paramétrable).
  echo "[inject-p3] Dégradation graduée sur replica-a (tc netem, 4 paliers)"
  node=$(node_of replica-a)
  for step in "50ms 0%" "150ms 2%" "400ms 5%" "800ms 15%"; do
    delay=$(echo "$step" | cut -d' ' -f1)
    loss=$(echo "$step" | cut -d' ' -f2)
    docker exec "${node}" tc qdisc replace dev eth0 root netem delay "${delay}" loss "${loss}" 2>/dev/null \
      || docker exec "${node}" tc qdisc add dev eth0 root netem delay "${delay}" loss "${loss}"
    echo "  palier: delay=${delay} loss=${loss} @ $(date +%s.%N)"
    sleep 15
  done
}

heal() {
  echo "[heal] Nettoyage des règles iptables et tc sur tous les nœuds..."
  for role in primary replica-a replica-b; do
    node=$(node_of "${role}")
    docker exec "${node}" iptables -F 2>/dev/null || true
    docker exec "${node}" tc qdisc del dev eth0 root 2>/dev/null || true
  done
  echo "[heal] OK à $(date +%s.%N)"
}

# ------------------------------------------------------------------------------
# Rapport : lit le CSV et calcule, pour chaque direction, le taux d'échec
# pendant chaque fenêtre d'injection. C'est ce qui donne le verdict GO/NO-GO.
# ------------------------------------------------------------------------------
report() {
  echo "[report] Résumé du fichier ${CSV_LOG} :"
  echo ""
  echo "Taux de timeout par direction (global sur toute la capture) :"
  awk -F, 'NR>1 {tot[$4]++; if ($6=="timeout") fail[$4]++}
           END {for (d in tot) printf "  %-25s %d/%d timeouts (%.1f%%)\n", d, fail[d]+0, tot[d], 100*(fail[d]+0)/tot[d]}' \
           "${CSV_LOG}"
  echo ""
  echo "-> Ouvrez ${CSV_LOG} dans un tableur / pandas et croisez les colonnes"
  echo "   timestamp / direction / status avec les horodatages 'Fault injectée à ...'"
  echo "   affichés par inject-p1 / inject-p2 pour visualiser les fenêtres."
  echo ""
  echo "Critères GO/NO-GO (voir PILOT_PROTOCOL.md pour le détail) :"
  echo "  GO  si, pendant P2 : replica-a->primary ~100% timeout"
  echo "                       ET primary->replica-a ~0% timeout"
  echo "  NO-GO si les deux sens sont affectés de façon comparable pendant P2"
  echo "        (signe que kind ne permet pas une asymétrie propre en l'état)."
}

teardown() {
  # NE SUPPRIME PAS le cluster (il héberge vos expériences mongodb-pi /
  # rpo-ycsb en cours) : on ne retire que le namespace du pilote.
  probe_stop
  heal
  kubectl delete namespace "${NS}" --ignore-not-found
  echo "[teardown] Namespace '${NS}' supprimé. Cluster '${CLUSTER_NAME}' intact."
}

case "${1:-}" in
  setup)        setup ;;
  probe-start)  probe_start ;;
  probe-stop)   probe_stop ;;
  inject-p1)    inject_p1 ;;
  inject-p2)    inject_p2 ;;
  inject-p3)    inject_p3 ;;
  heal)         heal ;;
  report)       report ;;
  teardown)     teardown ;;
  *)
    echo "Usage: $0 {setup|probe-start|probe-stop|inject-p1|inject-p2|inject-p3|heal|report|teardown}"
    exit 1
    ;;
esac
