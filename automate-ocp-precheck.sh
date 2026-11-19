#!/bin/bash
#
# pmcm.sh : Preventive Maintenance Health Check OpenShift
# Output tampil di terminal & save sebagai .log
# Summary ada di bagian paling bawah
#

############################ VARIABLE ############################
# Log disimpan di folder yang sama dengan script
# ENV_NAME otomatis dari nama cluster (oc whoami --show-console), bisa override: ENV_NAME=xxx ./pmcm.sh
LOG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

DISK_THRESHOLD=85        # persen, di atas nilai ini = WARN
RES_THRESHOLD=85         # persen CPU/Memory node, di atas nilai ini = WARN
CERT_WARN_DAYS=30        # sisa hari cert, di bawah nilai ini = WARN
NTP_MAX_OFFSET=1         # detik, offset di atas nilai ini = WARN

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes"

# Endpoint whitelist internet, dicek dari SEMUA node (bastion tidak dicek)
# Referensi: OCP docs "Configuring your firewall" (link otomatis sesuai versi cluster)
# Kosongkan array untuk cluster disconnected (hasil = SKIP)
WHITELIST_URLS=(
  # Registry / pull image
  "https://registry.redhat.io"
  "https://access.redhat.com"
  "https://registry.access.redhat.com"
  "https://registry.connect.redhat.com"
  "https://quay.io"
  "https://cdn.quay.io"
  "https://cdn01.quay.io"
  "https://cdn02.quay.io"
  "https://cdn03.quay.io"
  "https://cdn04.quay.io"
  "https://cdn05.quay.io"
  "https://cdn06.quay.io"
  "https://quayio-production-s3.s3.amazonaws.com"
  # Update dan signature (CVO)
  "https://api.openshift.com"
  "https://mirror.openshift.com"
  "https://storage.googleapis.com/openshift-release"
  # Telemetry / Insights (jika telemetry aktif)
  "https://console.redhat.com"
  "https://sso.redhat.com"
  "https://cert-api.access.redhat.com"
  "https://api.access.redhat.com"
  "https://infogw.api.openshift.com"
)
WL_CONNECT_TIMEOUT=5     # detik, timeout koneksi TCP per endpoint
WL_MAX_TIME=10           # detik, timeout total per endpoint
WL_RETRY=3               # jumlah percobaan per endpoint sebelum dianggap BLOCKED
WL_BATCH=6               # jumlah node yang dicek bersamaan (hindari burst/rate limit dari IP NAT yang sama)

# Namespace dengan cert auto rotate oleh OCP, tidak dihitung WARN
CERT_IGNORE_NS='^(openshift-kube-apiserver|openshift-kube-apiserver-operator|openshift-kube-controller-manager|openshift-kube-controller-manager-operator|openshift-kube-scheduler|openshift-kube-scheduler-operator|openshift-etcd|openshift-config-managed|openshift-operator-lifecycle-manager)$'

############################ SETUP ############################
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

if ! oc whoami >/dev/null 2>&1; then
  echo -e "${RED}Belum login ke cluster. Jalankan oc login terlebih dahulu.${NC}"
  exit 1
fi

# Ambil nama cluster dari URL console:
#   https://console-openshift-console.apps.<cluster>.<domain> -> <cluster>
# Fallback ke URL API jika console tidak ada: https://api.<cluster>.<domain>:6443 -> <cluster>
if [ -z "$ENV_NAME" ]; then
  CONSOLE_URL=$(oc whoami --show-console 2>/dev/null)
  ENV_NAME=$(echo "$CONSOLE_URL" | sed -E 's|^https?://[^.]+\.apps\.([^.]+)\..*|\1|')
  if [ -z "$ENV_NAME" ] || [ "$ENV_NAME" = "$CONSOLE_URL" ]; then
    ENV_NAME=$(oc whoami --show-server | sed -E 's|^https?://api\.([^.]+)\..*|\1|')
  fi
  [ -z "$ENV_NAME" ] && ENV_NAME="cluster"
fi

LOG_FILE="${LOG_DIR}/pmcm-${ENV_NAME}-$(date +%Y%m%d-%H%M).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  echo -e "${YELLOW}Folder ${LOG_DIR} tidak bisa ditulis, log disimpan di /tmp${NC}"
  LOG_FILE="/tmp/pmcm-${ENV_NAME}-$(date +%Y%m%d-%H%M).log"
fi
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

declare -A RES DET
PRECHECK_KEYS=("Check Node" "Check CO" "Check Pods" "Check Whitelist Internet" "Check NTP" "Check DNS")
ADDITIONAL_KEYS=("Check MCP" "Check ETCD" "Check Node Disk" "Check Node Resource" "Check Monitoring PVC" "Check Certificate" "Check Alert")

set_result() { RES["$1"]="$2"; DET["$1"]="$3"; }

section() {
  echo
  echo -e "${BOLD}${CYAN}======================================================================${NC}"
  echo -e "${BOLD}${CYAN} $1${NC}"
  echo -e "${BOLD}${CYAN}======================================================================${NC}"
}

colorize() {
  case "$1" in
    PASS) echo -e "${GREEN}[PASS]${NC}" ;;
    WARN) echo -e "${YELLOW}[WARN]${NC}" ;;
    FAIL) echo -e "${RED}[FAIL]${NC}" ;;
    *)    echo -e "${CYAN}[SKIP]${NC}" ;;
  esac
}

# Jalankan command via SSH ke semua node secara paralel
# Hasil per node disimpan di $SSH_TMP/<tag>/<node>
SSH_TMP=$(mktemp -d)
trap 'rm -rf "$SSH_TMP"' EXIT
ssh_all() {
  local tag="$1" cmd="$2" n pids=()
  mkdir -p "$SSH_TMP/$tag"
  for n in "${NODES[@]}"; do
    ssh $SSH_OPTS core@"$n" "$cmd" > "$SSH_TMP/$tag/$n" 2>/dev/null &
    pids+=($!)
  done
  wait "${pids[@]}"
}

over_limit() { awk -v v="$1" -v m="$2" 'BEGIN{exit !(v+0 > m+0)}'; }

resolve_a() {
  if command -v dig >/dev/null 2>&1; then
    dig +short "$1" A | grep -E '^[0-9.]+$' | head -1
  else
    getent ahostsv4 "$1" | awk 'NR==1{print $1}'
  fi
}

resolve_ptr() {
  if command -v dig >/dev/null 2>&1; then
    dig +short -x "$1" | head -1 | sed 's/\.$//'
  else
    getent hosts "$1" | awk '{print $2}'
  fi
}

############################ PRE ############################
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
API_URL=$(oc whoami --show-server)
NODES=($(oc get nodes --no-headers -o custom-columns=N:.metadata.name))
PROXY=$(oc get proxy cluster -o jsonpath='{.status.httpsProxy}')

section "PMCM HEALTH CHECK : ${ENV_NAME}"
echo "Date         : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "API          : ${API_URL}"
echo "Console      : ${CONSOLE_URL:-$(oc whoami --show-console 2>/dev/null)}"
echo "Version      : ${CLUSTER_VERSION}"
echo "Base Domain  : ${BASE_DOMAIN}"
echo "Total Node   : ${#NODES[@]}"
echo "Cluster Proxy: ${PROXY:-none}"
echo
oc get clusterversion

############################ 1. NODE ############################
section "1. CHECK NODE"
oc get nodes -o wide
NODE_RAW=$(oc get nodes --no-headers)
notready=$(echo "$NODE_RAW" | awk '$2 ~ /NotReady|Unknown/ {print $1}')
schedoff=$(echo "$NODE_RAW" | awk '$2 ~ /SchedulingDisabled/ {print $1}')
ready_cnt=$(echo "$NODE_RAW" | awk '$2 ~ /^Ready/ {c++} END{print c+0}')

if [ -n "$notready" ]; then
  set_result "Check Node" FAIL "NotReady: $(echo $notready)"
elif [ -n "$schedoff" ]; then
  set_result "Check Node" WARN "SchedulingDisabled: $(echo $schedoff)"
else
  set_result "Check Node" PASS "${ready_cnt}/${#NODES[@]} Node Ready"
fi

############################ 2. CLUSTER OPERATOR ############################
section "2. CHECK CLUSTER OPERATOR"
oc get co
CO_DATA=$(oc get co -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Available")].status}{" "}{.status.conditions[?(@.type=="Progressing")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}')
co_total=$(echo "$CO_DATA" | grep -c .)
co_fail=$(echo "$CO_DATA" | awk '$2!="True" || $4=="True" {print $1}')
co_prog=$(echo "$CO_DATA" | awk '$2=="True" && $4!="True" && $3=="True" {print $1}')

if [ -n "$co_fail" ]; then
  set_result "Check CO" FAIL "Unavailable/Degraded: $(echo $co_fail)"
elif [ -n "$co_prog" ]; then
  set_result "Check CO" WARN "Progressing: $(echo $co_prog)"
else
  set_result "Check CO" PASS "${co_total}/${co_total} CO Available"
fi

############################ 3. PODS ############################
section "3. CHECK PODS (Pods Apps)"
POD_RAW=$(oc get pods -A --no-headers)
pod_total=$(echo "$POD_RAW" | grep -c .)
BAD_PODS=$(echo "$POD_RAW" | awk '{split($3,r,"/"); if ($4=="Completed") next; if ($4!="Running" || r[1]!=r[2]) print}')
bad_cnt=$(echo "$BAD_PODS" | grep -c .)
bad_ocp=$(echo "$BAD_PODS" | awk '$1 ~ /^openshift-|^kube-/' | grep -c .)

echo "Total Pod Platform: ${pod_total}, Error Pod Apps: ${bad_cnt}"
if [ "$bad_cnt" -gt 0 ]; then
  echo
  ( echo "NAMESPACE NAME READY STATUS RESTARTS"; echo "$BAD_PODS" | awk '{print $1,$2,$3,$4,$5}' ) | column -t
fi

if [ "$bad_ocp" -gt 0 ]; then
  set_result "Check Pods" FAIL "${bad_cnt} pod kendala (${bad_ocp} di namespace platform)"
elif [ "$bad_cnt" -gt 0 ]; then
  set_result "Check Pods" WARN "${bad_cnt} pod kendala di namespace aplikasi"
else
  set_result "Check Pods" PASS "${pod_total} pod Running/Completed"
fi

############################ 4. WHITELIST INTERNET ############################
section "4. CHECK WHITELIST INTERNET"
FW_DOC="https://docs.redhat.com/en/documentation/openshift_container_platform/$(echo "$CLUSTER_VERSION" | cut -d. -f1,2)/html/installation_configuration/configuring-firewall"
echo "Referensi : ${FW_DOC}"

if [ ${#WHITELIST_URLS[@]} -eq 0 ]; then
  echo "WHITELIST_URLS kosong, check dilewati (disconnected)."
  set_result "Check Whitelist Internet" SKIP "WHITELIST_URLS kosong"
else
  PXOPT=""
  [ -n "$PROXY" ] && PXOPT="-x $PROXY"
  # HEAD request tanpa download body
  # time_appconnect > 0 berarti TLS handshake berhasil = firewall open
  CURL_OPTS="-sk -I -o /dev/null -w '%{http_code} %{time_total} %{time_appconnect}' --connect-timeout ${WL_CONNECT_TIMEOUT} --max-time ${WL_MAX_TIME} $PXOPT"


  # Command di node: tiap URL paralel, retry sampai TLS berhasil atau WL_RETRY habis
  # Output per baris: <url> <http_code> <time_total> <time_appconnect> <curl_exit> <attempt>
  REMOTE_CMD='for u in __URLS__; do ( a=0; while :; do a=$((a+1)); r=$(curl __OPTS__ $u); e=$?; set -- $r; { [ "$1" != "000" ] || [ "${3:-0}" != "0.000000" ]; } && break; [ $a -ge __RETRY__ ] && break; sleep $((RANDOM % 4 + 2)); done; echo "$u $r $e $a" ) & done; wait'
  REMOTE_CMD="${REMOTE_CMD/__URLS__/${WHITELIST_URLS[*]}}"
  REMOTE_CMD="${REMOTE_CMD/__OPTS__/$CURL_OPTS}"
  REMOTE_CMD="${REMOTE_CMD/__RETRY__/$WL_RETRY}"

  WL_RESULT=$(
    i=0
    for n in "${NODES[@]}"; do
      (
        out=$(ssh $SSH_OPTS core@"$n" "$REMOTE_CMD" 2>/dev/null)
        if [ -z "$out" ]; then echo "$n ssh_failed 000 0 0.000000 255 0"
        else echo "$out" | sed "s|^|$n |"; fi
      ) &
      i=$((i+1))
      [ $((i % WL_BATCH)) -eq 0 ] && wait
    done
    wait
  )
  # Kolom: node url http time appconnect exit attempt status
  #   OPEN    = ada respon HTTP
  #   SLOW    = TLS berhasil tapi HTTP tidak membalas sebelum timeout (firewall tetap open)
  #   BLOCKED = TLS gagal
  WL_RESULT=$(echo "$WL_RESULT" | awk 'NF==7 {
      st=($3!="000" ? "OPEN" : ($5+0>0 ? "SLOW" : "BLOCKED")); print $0, st }' | sort -k1,1 -k2,2)

  # Ringkasan per node
  echo
  echo -e "${BOLD}Ringkasan per node${NC}"
  ( echo "NODE OPEN SLOW BLOCKED RETRIED MAX_TIME(s) RESULT"
    echo "$WL_RESULT" | awk '{
        tot[$1]++
        if ($8=="BLOCKED") bl[$1]++; else ok[$1]++
        if ($8=="SLOW") sl[$1]++
        if ($8!="BLOCKED" && $7>1) rt[$1]++
        if ($4+0>mx[$1]) mx[$1]=$4+0
      } END {
        for (n in tot) printf "%s %d/%d %d %d %d %.2f %s\n", n, ok[n]+0, tot[n], sl[n]+0, bl[n]+0, rt[n]+0, mx[n], (bl[n]>0?"BLOCKED":"OK")
      }' | sort ) | column -t

  group_by_url() { awk -v f="$1" '{c[$2]++; s[$2]=s[$2]","$1(f?"("$7")":"")} END {for (u in c) print u, c[u], substr(s[u],2)}' | sort; }

  # Endpoint lambat (firewall open, server lambat)
  WL_SLOW=$(echo "$WL_RESULT" | awk '$8=="SLOW"')
  if [ -n "$WL_SLOW" ]; then
    echo
    echo -e "${YELLOW}${BOLD}Endpoint SLOW (TLS OK, respon HTTP > ${WL_MAX_TIME}s, firewall tetap open)${NC}"
    ( echo "URL JUMLAH SOURCE"; echo "$WL_SLOW" | group_by_url 0 ) | column -t
  fi

  # Endpoint berhasil setelah retry
  WL_RETRIED=$(echo "$WL_RESULT" | awk '$8!="BLOCKED" && $7>1')
  if [ -n "$WL_RETRIED" ]; then
    echo
    echo -e "${YELLOW}${BOLD}Endpoint berhasil setelah retry${NC}"
    ( echo "URL JUMLAH SOURCE(attempt)"; echo "$WL_RETRIED" | group_by_url 1 ) | column -t
  fi

  # Endpoint BLOCKED dengan jenis error
  WL_BLOCKED=$(echo "$WL_RESULT" | awk '$8=="BLOCKED"')
  if [ -n "$WL_BLOCKED" ]; then
    echo
    echo -e "${RED}${BOLD}Detail endpoint BLOCKED (per URL)${NC}"
    ( echo "URL ERROR JUMLAH SOURCE"
      echo "$WL_BLOCKED" | awk '
        function errname(e) {
          if (e==6)  return "DNS_FAIL";     if (e==7)  return "CONN_REFUSED"
          if (e==28) return "TIMEOUT";      if (e==35) return "SSL_ERROR"
          if (e==52) return "EMPTY_REPLY";  if (e==56) return "CONN_RESET"
          if (e==255) return "SSH_FAILED";  return "CURL_EXIT_" e
        }
        { k=$2" "errname($6); c[k]++; s[k]=s[k]","$1 }
        END { for (k in c) print k, c[k], substr(s[k],2) }' | sort ) | column -t
    echo "Keterangan ERROR: TIMEOUT = tidak ada respon (umumnya firewall drop), CONN_REFUSED/CONN_RESET = ditolak atau diputus (firewall reject atau rate limit), DNS_FAIL = nama tidak bisa di-resolve, SSL_ERROR = TLS gagal (umumnya SSL inspection proxy)"
  fi

  wl_total=$(echo "$WL_RESULT" | grep -c .)
  wl_fail=$(echo "$WL_BLOCKED" | grep -c .)
  if [ "$wl_fail" -gt 0 ]; then
    wl_urls=$(echo "$WL_BLOCKED" | awk '{print $2}' | sort -u | sed 's|https://||' | xargs)
    wl_srcs=$(echo "$WL_BLOCKED" | awk '{print $1}' | sort -u | grep -c .)
    set_result "Check Whitelist Internet" FAIL "${wl_fail}/${wl_total} blocked di ${wl_srcs} source: ${wl_urls}"
  else
    wl_nodes=$(echo "$WL_RESULT" | awk '{print $1}' | sort -u | grep -c .)
    set_result "Check Whitelist Internet" PASS "${#WHITELIST_URLS[@]} URL Red Hat open dari ${wl_nodes} node"
  fi
fi

############################ 5. NTP ############################
section "5. CHECK NTP"
NTP_TABLE="NODE LEAP_STATUS SYNC_SOURCE OFFSET(s) RESULT"$'\n'
ntp_fail=""; ntp_warn=""

echo "Checking chrony di ${#NODES[@]} node secara paralel..."
ssh_all ntp "sudo chronyc -n tracking; echo ===; sudo chronyc -n sources"

for n in "${NODES[@]}"; do
  out=$(cat "$SSH_TMP/ntp/$n")
  if [ -z "$out" ]; then
    NTP_TABLE+="$n - - - SSH_FAILED"$'\n'; ntp_fail+="$n "
    continue
  fi
  leap=$(echo "$out" | awk -F': ' '/Leap status/{print $2}' | tr ' ' '_')
  src=$(echo "$out" | awk '/^\^\*/{print $2; exit}')
  offset=$(echo "$out" | awk '/System time/{print $4}')

  if [ "$leap" != "Normal" ] || [ -z "$src" ]; then
    r="NOT_SYNC"; ntp_fail+="$n "
    echo -e "${RED}Node $n tidak sync, chronyc sources:${NC}"
    echo "$out" | sed -n '/===/,$p' | sed '1d'
    echo
  elif over_limit "$offset" "$NTP_MAX_OFFSET"; then
    r="HIGH_OFFSET"; ntp_warn+="$n "
  else
    r="OK"
  fi
  NTP_TABLE+="$n ${leap:-unknown} ${src:-none} ${offset:-0} $r"$'\n'
done
echo "$NTP_TABLE" | column -t

if [ -n "$ntp_fail" ]; then
  set_result "Check NTP" FAIL "Tidak sync: ${ntp_fail}"
elif [ -n "$ntp_warn" ]; then
  set_result "Check NTP" WARN "Offset > ${NTP_MAX_OFFSET}s: ${ntp_warn}"
else
  set_result "Check NTP" PASS "${#NODES[@]}/${#NODES[@]} node sync"
fi

############################ 6. DNS ############################
section "6. CHECK DNS"
dns_fail=""; dns_warn=""

echo -e "${BOLD}Cluster record (dari bastion)${NC}"
DNS_TABLE="RECORD IP RESULT"$'\n'
for h in "api.${BASE_DOMAIN}" "api-int.${BASE_DOMAIN}" "pmcm-test.apps.${BASE_DOMAIN}" \
         "console-openshift-console.apps.${BASE_DOMAIN}" "oauth-openshift.apps.${BASE_DOMAIN}"; do
  ip=$(resolve_a "$h")
  if [ -z "$ip" ]; then DNS_TABLE+="$h - NXDOMAIN"$'\n'; dns_fail+="$h "
  else DNS_TABLE+="$h $ip OK"$'\n'; fi
done
echo "$DNS_TABLE" | column -t

echo
echo -e "${BOLD}Node forward dan reverse (dari bastion)${NC}"
DNS_TABLE="NODE INTERNAL_IP FORWARD REVERSE RESULT"$'\n'
while read -r n nip; do
  fqdn="$n"; [[ "$n" != *.* ]] && fqdn="${n}.${BASE_DOMAIN}"
  fwd=$(resolve_a "$fqdn"); ptr=$(resolve_ptr "$nip")
  r="OK"
  if [ -z "$fwd" ] || [ -z "$ptr" ]; then r="MISSING"; dns_warn+="$n "
  elif [ "$fwd" != "$nip" ]; then r="MISMATCH"; dns_warn+="$n "; fi
  DNS_TABLE+="$n $nip ${fwd:--} ${ptr:--} $r"$'\n'
done < <(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
echo "$DNS_TABLE" | column -t

echo
echo -e "${BOLD}Resolve dari setiap node${NC}"
DNS_TABLE="NODE NAMESERVER API API-INT APPS RESULT"$'\n'
ssh_all dns "grep '^nameserver' /etc/resolv.conf | awk '{print \$2}' | paste -sd,; for h in api.${BASE_DOMAIN} api-int.${BASE_DOMAIN} pmcm-test.apps.${BASE_DOMAIN}; do ip=\$(getent ahostsv4 \$h | awk 'NR==1{print \$1}'); echo \${ip:-NXDOMAIN}; done"
for n in "${NODES[@]}"; do
  out=$(cat "$SSH_TMP/dns/$n")
  if [ -z "$out" ]; then
    DNS_TABLE+="$n - - - - SSH_FAILED"$'\n'; dns_fail+="$n "
    continue
  fi
  ns=$(echo "$out" | sed -n 1p); a1=$(echo "$out" | sed -n 2p); a2=$(echo "$out" | sed -n 3p); a3=$(echo "$out" | sed -n 4p)
  r="OK"
  if echo "$a1 $a2 $a3" | grep -q NXDOMAIN; then r="FAIL"; dns_fail+="$n "; fi
  DNS_TABLE+="$n ${ns:--} $a1 $a2 $a3 $r"$'\n'
done
echo "$DNS_TABLE" | column -t

if [ -n "$dns_fail" ]; then
  set_result "Check DNS" FAIL "Gagal resolve: ${dns_fail}"
elif [ -n "$dns_warn" ]; then
  set_result "Check DNS" WARN "Forward/reverse node bermasalah: ${dns_warn}"
else
  set_result "Check DNS" PASS "api, api-int, apps, forward/reverse node OK"
fi

############################ 7. MCP ############################
section "7. CHECK MACHINE CONFIG POOL"
oc get mcp
mcp_bad=$(oc get mcp -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Updated")].status}{" "}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' | awk '$2!="True" || $3=="True" {print $1}')
if [ -n "$mcp_bad" ]; then
  set_result "Check MCP" FAIL "Not updated/Degraded: $(echo $mcp_bad)"
else
  set_result "Check MCP" PASS "Semua MCP Updated"
fi

############################ 8. ETCD ############################
section "8. CHECK ETCD"
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
if [ -z "$ETCD_POD" ]; then
  set_result "Check ETCD" FAIL "Tidak ada pod etcd Running"
else
  oc -n openshift-etcd exec "$ETCD_POD" -c etcdctl -- etcdctl endpoint status --cluster -w table
  ETCD_HEALTH=$(oc -n openshift-etcd exec "$ETCD_POD" -c etcdctl -- etcdctl endpoint health --cluster -w table 2>&1)
  echo "$ETCD_HEALTH"
  etcd_ok=$(echo "$ETCD_HEALTH" | grep -cw true)
  etcd_bad=$(echo "$ETCD_HEALTH" | grep -cw false)
  if [ "$etcd_bad" -gt 0 ] || [ "$etcd_ok" -eq 0 ]; then
    set_result "Check ETCD" FAIL "${etcd_bad} endpoint unhealthy"
  else
    set_result "Check ETCD" PASS "${etcd_ok} endpoint healthy"
  fi
fi

############################ 9. NODE DISK ############################
section "9. CHECK NODE DISK USAGE (threshold ${DISK_THRESHOLD}%)"
disk_warn=""; disk_ssh_fail=""
ssh_all disk "df -hP -x tmpfs -x devtmpfs -x overlay -x squashfs"
for n in "${NODES[@]}"; do
  echo -e "${BOLD}>> $n${NC}"
  out=$(cat "$SSH_TMP/disk/$n")
  if [ -z "$out" ]; then echo "ssh gagal"; disk_ssh_fail+="$n "; continue; fi
  echo "$out"
  over=$(echo "$out" | awk -v t="$DISK_THRESHOLD" -v n="$n" 'NR>1 {u=$5; sub("%","",u); if (u+0>t) print n":"$6"("$5")"}')
  disk_warn+="$over "
  echo
done
disk_warn=$(echo $disk_warn)
if [ -n "$disk_ssh_fail" ]; then
  set_result "Check Node Disk" FAIL "SSH gagal: ${disk_ssh_fail}"
elif [ -n "$disk_warn" ]; then
  set_result "Check Node Disk" WARN "Di atas ${DISK_THRESHOLD}%: ${disk_warn}"
else
  set_result "Check Node Disk" PASS "Semua filesystem di bawah ${DISK_THRESHOLD}%"
fi

############################ 10. NODE RESOURCE ############################
section "10. CHECK NODE CPU & MEMORY (threshold ${RES_THRESHOLD}%)"
echo "Catatan: capture juga Grafana > USE Method / Node, last 30 days"
echo
TOP=$(oc adm top nodes 2>&1)
echo "$TOP"
if echo "$TOP" | grep -qi error; then
  set_result "Check Node Resource" WARN "Metrics tidak tersedia"
else
  res_warn=$(echo "$TOP" | awk -v t="$RES_THRESHOLD" 'NR>1 {c=$3; m=$5; sub("%","",c); sub("%","",m); if (c+0>t || m+0>t) print $1"(cpu "$3", mem "$5")"}')
  if [ -n "$res_warn" ]; then
    set_result "Check Node Resource" WARN "$(echo $res_warn)"
  else
    set_result "Check Node Resource" PASS "CPU dan memory semua node di bawah ${RES_THRESHOLD}%"
  fi
fi

############################ 11. MONITORING PVC ############################
section "11. CHECK MONITORING PVC (threshold ${DISK_THRESHOLD}%)"
mon_warn=""
for p in $(oc get pods -n openshift-monitoring --no-headers -o custom-columns=N:.metadata.name | grep -E '^alertmanager-main|^prometheus-k8s'); do
  case "$p" in
    alertmanager*) c=alertmanager; mp=/alertmanager ;;
    prometheus*)   c=prometheus;   mp=/prometheus ;;
  esac
  echo -e "${BOLD}>> $p${NC}"
  out=$(oc exec -n openshift-monitoring "$p" -c "$c" -- df -h "$mp" 2>&1)
  echo "$out"; echo
  u=$(echo "$out" | awk 'END{gsub("%","",$5); print $5}')
  over_limit "${u:-0}" "$DISK_THRESHOLD" && mon_warn+="$p(${u}%) "
done
if [ -n "$mon_warn" ]; then
  set_result "Check Monitoring PVC" WARN "Di atas ${DISK_THRESHOLD}%: ${mon_warn}"
else
  set_result "Check Monitoring PVC" PASS "Semua di bawah ${DISK_THRESHOLD}%"
fi

############################ 12. CERTIFICATE ############################
section "12. CHECK CERTIFICATE (expire < ${CERT_WARN_DAYS} hari)"
NOW=$(date +%s)
CERT_LIST=$(oc get secrets -A --field-selector type=kubernetes.io/tls \
  -o go-template='{{range .items}}{{.metadata.namespace}}{{" "}}{{.metadata.name}}{{" "}}{{index .data "tls.crt"}}{{"\n"}}{{end}}' 2>/dev/null |
  while read -r ns name cert; do
    end=$(echo "$cert" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -z "$end" ] && continue
    days=$(( ($(date -d "$end" +%s) - NOW) / 86400 ))
    echo "$days $ns $name $(date -d "$end" +%Y-%m-%d)"
  done | sort -n)

cert_total=$(echo "$CERT_LIST" | grep -c .)
EXPIRING=$(echo "$CERT_LIST" | awk -v d="$CERT_WARN_DAYS" '$1 < d')
echo "Total TLS secret: ${cert_total}"
echo
echo -e "${BOLD}Router & API cert${NC}"
( echo "DAYS_LEFT NAMESPACE NAME EXPIRY"
  echo "$CERT_LIST" | awk '$2=="openshift-ingress" || $2=="openshift-config"' ) | column -t
echo
echo -e "${BOLD}Cert expire < ${CERT_WARN_DAYS} hari${NC}"
if [ -n "$EXPIRING" ]; then
  ( echo "DAYS_LEFT NAMESPACE NAME EXPIRY TYPE"
    echo "$EXPIRING" | awk -v re="$CERT_IGNORE_NS" '{print $0, ($2 ~ re ? "AUTO_ROTATE" : "CHECK")}' ) | column -t
else
  echo "Tidak ada"
fi
cert_warn=$(echo "$EXPIRING" | awk -v re="$CERT_IGNORE_NS" 'NF && $2 !~ re {print $2"/"$3"("$1"d)"}')
if [ -n "$cert_warn" ]; then
  set_result "Check Certificate" WARN "$(echo $cert_warn)"
else
  set_result "Check Certificate" PASS "Tidak ada cert non auto rotate expire < ${CERT_WARN_DAYS} hari"
fi

############################ 13. ALERT ############################
section "13. CHECK FIRING ALERT"
AM_HOST=$(oc get route alertmanager-main -n openshift-monitoring -o jsonpath='{.spec.host}')
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring 2>/dev/null || oc whoami -t)
ALERT_JSON=$(curl -sk --max-time 20 --noproxy "$AM_HOST" -H "Authorization: Bearer $TOKEN" \
  "https://${AM_HOST}/api/v2/alerts?active=true&silenced=false&inhibited=false")

if command -v jq >/dev/null 2>&1; then
  ALERTS=$(echo "$ALERT_JSON" | jq -r '.[] | select(.labels.alertname!="Watchdog") | [(.labels.severity // "none"), .labels.alertname, (.labels.namespace // "-"), .startsAt[0:19]] | @tsv' 2>/dev/null)
else
  ALERTS=$(echo "$ALERT_JSON" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    l=a.get("labels",{})
    if l.get("alertname")=="Watchdog": continue
    print("\t".join([l.get("severity","none"),l.get("alertname",""),l.get("namespace","-"),a.get("startsAt","")[:19]]))' 2>/dev/null)
fi

if [ -z "$ALERT_JSON" ]; then
  echo "Gagal mengambil alert dari ${AM_HOST}"
  set_result "Check Alert" WARN "Alertmanager tidak bisa diakses"
else
  if [ -n "$ALERTS" ]; then
    ( echo -e "SEVERITY\tALERTNAME\tNAMESPACE\tSTARTS_AT"; echo "$ALERTS" | sort ) | column -t -s $'\t'
  else
    echo "Tidak ada alert firing (selain Watchdog)"
  fi
  crit=$(echo "$ALERTS" | awk -F'\t' '$1=="critical"' | grep -c .)
  warn=$(echo "$ALERTS" | awk -F'\t' '$1=="warning"' | grep -c .)
  if [ "$crit" -gt 0 ]; then
    set_result "Check Alert" FAIL "${crit} critical, ${warn} warning"
  elif [ "$warn" -gt 0 ]; then
    set_result "Check Alert" WARN "${warn} warning"
  else
    set_result "Check Alert" PASS "Tidak ada alert critical/warning"
  fi
fi

############################ SUMMARY ############################
section "SUMMARY"
echo "Environment : ${ENV_NAME}"
echo "API         : ${API_URL}"
echo "Version     : ${CLUSTER_VERSION}"
echo "Date        : $(date '+%Y-%m-%d %H:%M:%S %Z')"

print_rows() {
  for k in "$@"; do
    printf "  * %-26s %b  %s\n" "$k" "$(colorize "${RES[$k]}")" "${DET[$k]}"
  done
}

echo
echo -e "${BOLD}PRECHECK${NC}"
print_rows "${PRECHECK_KEYS[@]}"
echo
echo -e "${BOLD}ADDITIONAL CHECK${NC}"
print_rows "${ADDITIONAL_KEYS[@]}"

n_fail=0; n_warn=0; n_pass=0
for k in "${PRECHECK_KEYS[@]}" "${ADDITIONAL_KEYS[@]}"; do
  case "${RES[$k]}" in FAIL) ((n_fail++));; WARN) ((n_warn++));; PASS) ((n_pass++));; esac
done

echo
if [ "$n_fail" -gt 0 ]; then
  echo -e "${BOLD}OVERALL : ${RED}FAIL${NC}  (pass ${n_pass}, warn ${n_warn}, fail ${n_fail})"
elif [ "$n_warn" -gt 0 ]; then
  echo -e "${BOLD}OVERALL : ${YELLOW}WARN${NC}  (pass ${n_pass}, warn ${n_warn}, fail ${n_fail})"
else
  echo -e "${BOLD}OVERALL : ${GREEN}HEALTHY${NC}  (pass ${n_pass}, warn ${n_warn}, fail ${n_fail})"
fi
echo
echo "Log file : ${LOG_FILE}"
sleep 1
