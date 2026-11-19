#!/bin/bash
#
# ns-utilize.sh : Preventive Maintenance Application Workload Check OpenShift
# Fokus ke namespace aplikasi (exclude openshift*, kube-*, dan namespace platform)
# Output tampil di terminal & save sebagai .log, tabel detail juga di-export ke CSV
# Summary ada di bagian paling bawah
#
# Usage:
#   ./ns-utilize.sh
#   ENV_NAME=prod ./ns-utilize.sh                          # override nama environment
#   INCLUDE_NS_REGEX='^(bisigap|mapp)-' ./ns-utilize.sh    # hanya namespace tertentu
#
# Isi check:
#   1. Inventory namespace  : jumlah pod, workload, HPA, route, PVC, quota per namespace
#   2. Workload             : peruntukkan (label/image/route), replica, PDB, anti-affinity, route TLS
#   3. Distribusi pod & HA  : pembagian pod per node, SPOF (single replica / 1 node), PodDisruptionBudget
#   4. Utilisasi pod        : usage vs request/limit per namespace, per workload, pod bermasalah
#   5. Resource config      : request/limit/probe per container
#   6. Quota & LimitRange
#   7. PVC aplikasi         : status, kapasitas, usage aktual (Thanos), growth 7 hari, estimasi penuh
#   8. Utilisasi node       : usage aktual, total request/limit vs allocatable, sisa kapasitas, ukuran node
#   Housekeeping            : pod Completed/Failed/Evicted yang menumpuk
#   Best practice           : probe, image :latest, route tanpa TLS, PDB
#

############################ VARIABLE ############################
LOG_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

RES_THRESHOLD=85         # persen usage/request node, di atas nilai ini = WARN
POD_THRESHOLD=85         # persen usage pod terhadap limit, di atas nilai ini = WARN
LOW_USAGE=10             # persen usage terhadap request, di bawah nilai ini = OVERPROV (info saja)
QUOTA_THRESHOLD=85       # persen pemakaian ResourceQuota, di atas nilai ini = WARN
RESTART_THRESHOLD=5      # jumlah restart pod, di atas/sama dengan nilai ini = WARN
OC_TIMEOUT=300s          # timeout per request oc get, supaya tidak menggantung
HOUSEKEEP_THRESHOLD=50   # jumlah pod Completed/Failed/Evicted per namespace, di atas nilai ini = WARN
MAX_PODS_WARN=2000       # maxPods node di atas nilai ini = WARN (sesuaikan desain cluster, contoh hostPrefix /20 = 2000)
PVC_THRESHOLD=85         # persen usage PVC, di atas nilai ini = WARN

# Namespace platform yang di-exclude (regex full name)
# Namespace dengan label openshift.io/cluster-monitoring=true juga otomatis di-exclude
# Tambahkan namespace platform/operator lain sesuai cluster
PLATFORM_NS_REGEX="${PLATFORM_NS_REGEX:-^(openshift|openshift-.*|kube-.*|default|assisted-installer|stackrox|rhacs-operator|open-cluster-management.*|multicluster-engine|hive|cert-manager.*|nvidia-gpu-operator|redhat-ods-.*|knative-.*|istio-system)$}"
INCLUDE_NS_REGEX="${INCLUDE_NS_REGEX:-}"

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

PY=$(command -v python3 || command -v /usr/libexec/platform-python)
if [ -z "$PY" ]; then
  echo -e "${RED}python3 tidak ditemukan di bastion, dibutuhkan untuk parsing JSON.${NC}"
  exit 1
fi

if [ -z "$ENV_NAME" ]; then
  CONSOLE_URL=$(oc whoami --show-console 2>/dev/null)
  ENV_NAME=$(echo "$CONSOLE_URL" | sed -E 's|^https?://[^.]+\.apps\.([^.]+)\..*|\1|')
  if [ -z "$ENV_NAME" ] || [ "$ENV_NAME" = "$CONSOLE_URL" ]; then
    ENV_NAME=$(oc whoami --show-server | sed -E 's|^https?://api\.([^.]+)\..*|\1|')
  fi
  [ -z "$ENV_NAME" ] && ENV_NAME="cluster"
fi

LOG_FILE="${LOG_DIR}/report-${ENV_NAME}-$(date +%Y%m%d-%H%M).log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  echo -e "${YELLOW}Folder ${LOG_DIR} tidak bisa ditulis, log disimpan di /tmp${NC}"
  LOG_FILE="/tmp/report-${ENV_NAME}-$(date +%Y%m%d-%H%M).log"
fi
CSV_DIR="${LOG_FILE%.log}-csv"
mkdir -p "$CSV_DIR"
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

declare -A RES DET
INVENTORY_KEYS=("Check App Pods" "Check Workload Replica" "Check Pod Distribution" "Check PDB" "Check PVC" "Check Housekeeping")
CAPACITY_KEYS=("Check Pod Utilization" "Check Resource Limit" "Check Quota" "Check Node Utilization")
PRACTICE_KEYS=("Check Probe" "Check Image Tag" "Check Route TLS")

set_result() { RES["$1"]="$2"; DET["$1"]="$3"; }

section() {
  echo
  echo -e "${BOLD}${CYAN}======================================================================${NC}"
  echo -e "${BOLD}${CYAN} $1${NC}"
  echo -e "${BOLD}${CYAN}======================================================================${NC}"
}

sub() { echo; echo -e "${BOLD}$1${NC}"; }

colorize() {
  case "$1" in
    PASS) echo -e "${GREEN}[PASS]${NC}" ;;
    WARN) echo -e "${YELLOW}[WARN]${NC}" ;;
    FAIL) echo -e "${RED}[FAIL]${NC}" ;;
    *)    echo -e "${CYAN}[SKIP]${NC}" ;;
  esac
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Tampilkan tabel hasil analisa (TSV) dengan column
show() {
  local f="$TMP/tbl_$1.tsv"
  if [ ! -s "$f" ] || [ "$(wc -l < "$f")" -le 1 ]; then
    echo "${2:-Tidak ada data}"
  else
    column -t -s $'\t' < "$f"
  fi
}

############################ PRE ############################
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
API_URL=$(oc whoami --show-server)

section "WORKLOAD CHECK : ${ENV_NAME}"
echo "Date         : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "API          : ${API_URL}"
echo "Console      : ${CONSOLE_URL:-$(oc whoami --show-console 2>/dev/null)}"
echo "Version      : ${CLUSTER_VERSION}"
echo "Exclude NS   : ${PLATFORM_NS_REGEX}"
[ -n "$INCLUDE_NS_REGEX" ] && echo "Include NS   : ${INCLUDE_NS_REGEX}"
echo
echo "Mengambil data dari cluster..."

# Ambil semua object sekali (paralel), analisa offline di python
# replicasets & jobs tidak diambil (paling berat), owner dihitung dari nama pod/label
# Progress per resource ditampilkan dengan durasi dan ukuran, error disimpan ke .err
RESOURCES="namespaces nodes pods deployments statefulsets daemonsets deploymentconfigs cronjobs horizontalpodautoscalers poddisruptionbudgets services routes persistentvolumeclaims resourcequotas limitranges"
fetch() {
  local name="$1"; shift
  local t0=$SECONDS rc
  "$@" > "$TMP/$name.out" 2> "$TMP/$name.err"; rc=$?
  local sz; sz=$(du -h "$TMP/$name.out" 2>/dev/null | cut -f1)
  if [ $rc -eq 0 ]; then
    printf "  %-26s ${GREEN}OK${NC}    %4ss  %s\n" "$name" "$((SECONDS - t0))" "$sz"
  else
    printf "  %-26s ${YELLOW}GAGAL${NC} %4ss  %s\n" "$name" "$((SECONDS - t0))" "$(head -c 120 "$TMP/$name.err" | tr '\n' ' ')"
    echo "$name" >> "$TMP/failed.txt"
  fi
}
# Usage PVC dari Thanos Querier (kubelet_volume_stats), dipakai untuk sizing
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
PROM_TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring 2>/dev/null || oc whoami -t 2>/dev/null)
prom_query() {
  [ -z "$THANOS_HOST" ] && { echo "route thanos-querier tidak ditemukan" >&2; return 1; }
  [ -z "$PROM_TOKEN" ] && { echo "token tidak tersedia (login pakai token atau butuh akses create token)" >&2; return 1; }
  local out
  out=$(curl -sk --max-time 60 --noproxy "$THANOS_HOST" -H "Authorization: Bearer $PROM_TOKEN" \
        "https://${THANOS_HOST}/api/v1/query" --data-urlencode "query=$1")
  if ! echo "$out" | grep -q '"status":"success"'; then
    echo "${out:-tidak ada respon dari $THANOS_HOST}" | head -c 200 >&2; return 1
  fi
  echo "$out"
}
PVC_BY='max by (namespace, persistentvolumeclaim)'

# PENTING: wait harus pakai PID. "wait" tanpa argumen ikut menunggu proses tee (log) sehingga script menggantung
FETCH_START=$SECONDS; PIDS=()
for r in $RESOURCES; do
  fetch "$r" oc get "$r" -A -o json --request-timeout="$OC_TIMEOUT" & PIDS+=($!)
done
fetch top_nodes oc adm top nodes --no-headers & PIDS+=($!)
fetch top_pods oc adm top pods -A --no-headers & PIDS+=($!)
fetch pvc_used prom_query "$PVC_BY (kubelet_volume_stats_used_bytes)" & PIDS+=($!)
fetch pvc_cap prom_query "$PVC_BY (kubelet_volume_stats_capacity_bytes)" & PIDS+=($!)
fetch pvc_used_7d prom_query "$PVC_BY (kubelet_volume_stats_used_bytes offset 7d)" & PIDS+=($!)
wait "${PIDS[@]}"
for r in $RESOURCES; do mv "$TMP/$r.out" "$TMP/$r.json" 2>/dev/null; done
mv "$TMP/top_nodes.out" "$TMP/top_nodes.txt" 2>/dev/null
mv "$TMP/top_pods.out" "$TMP/top_pods.txt" 2>/dev/null
for r in pvc_used pvc_cap pvc_used_7d; do mv "$TMP/$r.out" "$TMP/$r.json" 2>/dev/null; done
echo "Selesai ambil data dalam $((SECONDS - FETCH_START)) detik"

# Resource wajib, jika gagal hasil analisa tidak valid
for r in namespaces nodes pods; do
  if grep -qx "$r" "$TMP/failed.txt" 2>/dev/null; then
    echo -e "${RED}Gagal mengambil ${r}, cek akses user (butuh cluster-reader/cluster-admin). Error:${NC}"
    cat "$TMP/$r.err"
    exit 1
  fi
done
# deploymentconfigs boleh gagal (capability DeploymentConfig bisa dinonaktifkan di OCP 4.14+)
# pvc_used_7d boleh gagal/kosong (PVC baru atau retention Prometheus < 7 hari)
FETCH_FAILED=$(grep -vxE 'deploymentconfigs|pvc_used_7d' "$TMP/failed.txt" 2>/dev/null | xargs)

############################ ANALYZER ############################
cat > "$TMP/analyze.py" <<'PYEOF'
import json, os, re, sys, csv
from collections import Counter, defaultdict

D, OUT = sys.argv[1], sys.argv[2]
E = os.environ
EXCL = re.compile(E.get('PLATFORM_NS_REGEX') or r'^(openshift|openshift-.*|kube-.*|default)$')
INCL = re.compile(E['INCLUDE_NS_REGEX']) if E.get('INCLUDE_NS_REGEX') else None
T_NODE = float(E.get('RES_THRESHOLD', 85))
T_POD = float(E.get('POD_THRESHOLD', 85))
T_LOW = float(E.get('LOW_USAGE', 10))
T_QUOTA = float(E.get('QUOTA_THRESHOLD', 85))
T_RST = int(E.get('RESTART_THRESHOLD', 5))
T_HK = int(E.get('HOUSEKEEP_THRESHOLD', 50))
T_MAXPODS = int(E.get('MAX_PODS_WARN', 2000))
T_PVC = float(E.get('PVC_THRESHOLD', 85))
APPS_DOMAIN = E.get('APPS_DOMAIN', '')
from datetime import datetime, timezone
NOW = datetime.now(timezone.utc).replace(tzinfo=None)
def age(ts):
    try: return (NOW - datetime.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S')).days
    except (TypeError, ValueError): return None

# ---------- helper ----------
def load(name):
    try:
        with open(os.path.join(D, name + '.json')) as f:
            return json.load(f).get('items') or []
    except Exception:
        return []

def readlines(name):
    try:
        with open(os.path.join(D, name)) as f:
            return [l.split() for l in f if l.strip()]
    except Exception:
        return []

def cpu(v):
    """return millicore"""
    if v in (None, ''):
        return None
    v = str(v)
    try:
        if v.endswith('n'): return float(v[:-1]) / 1e6
        if v.endswith('u'): return float(v[:-1]) / 1e3
        if v.endswith('m'): return float(v[:-1])
        return float(v) * 1000
    except ValueError:
        return None

BIN = {'Ki': 2**10, 'Mi': 2**20, 'Gi': 2**30, 'Ti': 2**40, 'Pi': 2**50, 'Ei': 2**60}
DEC = {'k': 1e3, 'K': 1e3, 'M': 1e6, 'G': 1e9, 'T': 1e12, 'P': 1e15, 'E': 1e18, 'm': 1e-3}
def mem(v):
    """return byte"""
    if v in (None, ''):
        return None
    v = str(v)
    try:
        if v[-2:] in BIN: return float(v[:-2]) * BIN[v[-2:]]
        if v[-1] in DEC: return float(v[:-1]) * DEC[v[-1]]
        return float(v)
    except ValueError:
        return None

def fc(m):
    if m is None: return '-'
    return '%dm' % round(m) if m < 1000 else '%.2f' % (m / 1000)

def fm(b):
    if b is None: return '-'
    return '%.1fGi' % (b / 2**30) if b >= 2**30 else '%dMi' % round(b / 2**20)

def pct(a, b):
    return a / b * 100 if a is not None and b else None

def fp(p):
    return '-' if p is None else '%d%%' % round(p)

def short(n):
    if not n: return '-'
    return n if re.match(r'^\d+\.\d+\.\d+\.\d+$', n) else n.split('.')[0]

def clean(x):
    if x is None or x == '': return '-'
    return str(x).replace('\t', ' ').replace('\n', ' ')

def lst(xs, n=5):
    xs = list(xs)
    return ' '.join(xs[:n]) + (' (+%d lainnya)' % (len(xs) - n) if len(xs) > n else '')

def ssum(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) if xs else None

def table(name, header, rows, csv_only=False):
    rows = [[clean(c) for c in r] for r in rows]
    if not csv_only:
        with open(os.path.join(D, 'tbl_' + name + '.tsv'), 'w') as f:
            f.write('\t'.join(header) + '\n')
            for r in rows:
                f.write('\t'.join(r) + '\n')
    if OUT and rows:
        with open(os.path.join(OUT, 'report-' + name + '.csv'), 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(header)
            w.writerows(rows)

RESULTS = []
def result(k, s, d):
    RESULTS.append((k, s, clean(d)))

def ctrl(md):
    refs = md.get('ownerReferences') or []
    return next((r for r in refs if r.get('controller')), refs[0] if refs else None)

# ---------- namespace aplikasi ----------
APP = {}
for n in load('namespaces'):
    md = n['metadata']; name = md['name']
    lab = md.get('labels') or {}; ann = md.get('annotations') or {}
    if EXCL.search(name) or lab.get('openshift.io/cluster-monitoring') == 'true':
        continue
    if INCL and not INCL.search(name):
        continue
    APP[name] = dict(
        desc=ann.get('openshift.io/description') or ann.get('openshift.io/display-name') or '',
        requester=ann.get('openshift.io/requester', ''),
        created=(md.get('creationTimestamp') or '')[:10])

def isapp(o):
    return o['metadata'].get('namespace') in APP

# ---------- node ----------
NODES = {}
for n in load('nodes'):
    md = n['metadata']; lab = md.get('labels') or {}
    roles = sorted(k.split('/', 1)[1] for k in lab if k.startswith('node-role.kubernetes.io/'))
    al = n['status'].get('allocatable') or {}
    ready = next((c['status'] for c in n['status'].get('conditions', []) if c['type'] == 'Ready'), 'Unknown')
    st = 'Ready' if ready == 'True' else 'NotReady'
    if (n.get('spec') or {}).get('unschedulable'):
        st += ',SchedDisabled'
    NODES[md['name']] = dict(
        roles=','.join(roles) or '-', status=st,
        cpu=cpu(al.get('cpu')), mem=mem(al.get('memory')), podcap=int(mem(al.get('pods')) or 0),
        cr=0, cl=0, mr=0, ml=0, pods=0,
        app_pods=0, app_cr=0, app_mr=0, app_cu=0, app_mu=0, ns=Counter(),
        use_cpu=None, use_mem=None)

for p in readlines('top_nodes.txt'):
    if len(p) >= 4 and p[0] in NODES:
        NODES[p[0]]['use_cpu'] = cpu(p[1])
        NODES[p[0]]['use_mem'] = mem(p[3])

# ---------- metrics pod ----------
PU = {}
for p in readlines('top_pods.txt'):
    if len(p) >= 4:
        PU[(p[0], p[1])] = (cpu(p[2]), mem(p[3]))
HAS_METRICS = bool(PU)


# ---------- workload ----------
WL = {}
def add_wl(o, kind, desired, ready, tmpl, extra=''):
    md = o['metadata']
    WL[(md['namespace'], kind, md['name'])] = dict(
        ns=md['namespace'], kind=kind, name=md['name'], desired=desired, ready=ready,
        labels=md.get('labels') or {}, tlabels=((tmpl or {}).get('metadata') or {}).get('labels') or {},
        spec=(tmpl or {}).get('spec') or {}, extra=extra, pods=[], hpa='', dyn=False)

for kind, src in (('Deployment', 'deployments'), ('StatefulSet', 'statefulsets'), ('DeploymentConfig', 'deploymentconfigs')):
    for o in load(src):
        if not isapp(o): continue
        s = o.get('spec') or {}; st = o.get('status') or {}
        add_wl(o, kind, s.get('replicas', 1), st.get('readyReplicas', 0), s.get('template'))
for o in load('daemonsets'):
    if not isapp(o): continue
    st = o.get('status') or {}
    add_wl(o, 'DaemonSet', st.get('desiredNumberScheduled', 0), st.get('numberReady', 0), (o.get('spec') or {}).get('template'))
for o in load('cronjobs'):
    if not isapp(o): continue
    s = o.get('spec') or {}
    last = (o.get('status') or {}).get('lastScheduleTime') or ''
    extra = ('SUSPENDED ' if s.get('suspend') else '') + 'schedule="%s"' % s.get('schedule', '') + (' last=%s' % last[:16] if last else '')
    add_wl(o, 'CronJob', None, None, ((s.get('jobTemplate') or {}).get('spec') or {}).get('template'), extra)

for h in load('horizontalpodautoscalers'):
    if not isapp(h): continue
    s = h.get('spec') or {}; ref = s.get('scaleTargetRef') or {}
    key = (h['metadata']['namespace'], ref.get('kind'), ref.get('name'))
    if key in WL:
        WL[key]['hpa'] = '%s-%s' % (s.get('minReplicas', 1), s.get('maxReplicas', '?'))

# ---------- pod ----------
FAILS = {'CrashLoopBackOff', 'ImagePullBackOff', 'ErrImagePull', 'Error', 'CreateContainerConfigError',
         'CreateContainerError', 'InvalidImageName', 'RunContainerError', 'OOMKilled', 'ContainerCannotRun'}

def cres(c):
    r = c.get('resources') or {}
    rq = r.get('requests') or {}; lm = r.get('limits') or {}
    return cpu(rq.get('cpu')), cpu(lm.get('cpu')), mem(rq.get('memory')), mem(lm.get('memory'))

def podres(spec):
    vals = [cres(c) for c in spec.get('containers') or []]
    out = {}
    for i, k in enumerate(('cr', 'cl', 'mr', 'ml')):
        xs = [v[i] for v in vals]
        out[k + '_raw'] = sum(x or 0 for x in xs)
        if not xs or all(x is None for x in xs) or (k in ('cl', 'ml') and any(x is None for x in xs)):
            out[k] = None   # limit dianggap None jika ada container tanpa limit
        else:
            out[k] = sum(x or 0 for x in xs)
    return out

def pod_status(p):
    st = p.get('status') or {}
    if p['metadata'].get('deletionTimestamp'):
        return 'Terminating'
    for c in st.get('initContainerStatuses') or []:
        s = c.get('state') or {}
        if s.get('waiting') and s['waiting'].get('reason') not in (None, 'PodInitializing'):
            return 'Init:' + s['waiting']['reason']
        if s.get('terminated') and s['terminated'].get('exitCode', 0) != 0:
            return 'Init:' + (s['terminated'].get('reason') or 'Error')
    for c in st.get('containerStatuses') or []:
        s = c.get('state') or {}
        if s.get('waiting') and s['waiting'].get('reason'):
            return s['waiting']['reason']
        if s.get('terminated') and st.get('phase') == 'Running':
            return s['terminated'].get('reason') or 'Terminated'
    return st.get('reason') or st.get('phase', 'Unknown')

PODS = []
PODS_NS = defaultdict(list)
for p in load('pods'):
    md = p['metadata']; ns = md['namespace']
    spec = p.get('spec') or {}; st = p.get('status') or {}
    phase = st.get('phase', 'Unknown'); node = spec.get('nodeName')
    active = phase not in ('Succeeded', 'Failed')
    r = podres(spec)
    nd = NODES.get(node) if active else None
    if nd:
        nd['pods'] += 1
        for k in ('cr', 'cl', 'mr', 'ml'):
            nd[k] += r[k + '_raw']
    if ns not in APP:
        continue

    status = pod_status(p)
    cs = st.get('containerStatuses') or []
    total = len(spec.get('containers') or [])
    ready = sum(1 for c in cs if c.get('ready'))
    ready_ok = phase == 'Running' and total > 0 and ready == total
    restarts = sum(c.get('restartCount', 0) for c in cs)
    lastterm = sorted({((c.get('lastState') or {}).get('terminated') or {}).get('reason') for c in cs} - {None})

    ref = ctrl(md)
    if not ref:
        wk = ('Pod', md['name'])
    else:
        k, n = ref['kind'], ref['name']
        if k == 'ReplicaSet':
            # nama RS = <deployment>-<pod-template-hash>
            h = (md.get('labels') or {}).get('pod-template-hash')
            if h and n.endswith('-' + h) and (ns, 'Deployment', n[:-len(h) - 1]) in WL:
                k, n = 'Deployment', n[:-len(h) - 1]
        elif k == 'ReplicationController':
            lab = md.get('labels') or {}
            dc = lab.get('deploymentconfig') or lab.get('openshift.io/deployment-config.name')
            if dc: k, n = 'DeploymentConfig', dc
        elif k == 'Job':
            # nama Job dari CronJob = <cronjob>-<angka jadwal>
            cj = re.sub(r'-\d+$', '', n)
            if cj != n and (ns, 'CronJob', cj) in WL:
                k, n = 'CronJob', cj
        wk = (k, n)
    key = (ns,) + wk
    if key not in WL:
        if active:
            WL[key] = dict(ns=ns, kind=wk[0], name=wk[1], desired=None, ready=None,
                           labels=md.get('labels') or {}, tlabels={}, spec=spec, extra='', pods=[], hpa='', dyn=True)
        else:
            key = None

    cu, mu = PU.get((ns, md['name']), (None, None))
    base = status.split(':')[-1]
    tags, sev = [], None
    if phase == 'Succeeded':
        pass
    elif base == 'Evicted':
        tags.append('EVICTED'); sev = 'WARN'
    elif phase == 'Failed':
        # pod sudah selesai dengan status gagal (sisa job/build), bukan aplikasi yang sedang down
        tags.append('FAILED_OLD'); sev = 'WARN'
    elif base in FAILS:
        tags.append(status); sev = 'FAIL'
    elif not ready_ok:
        tags.append('NOT_READY' if status == 'Running' else status); sev = 'WARN'
    if restarts >= T_RST:
        tags.append('RESTART_%d' % restarts); sev = sev or 'WARN'
    if 'OOMKilled' in lastterm:
        tags.append('OOM_HISTORY'); sev = sev or 'WARN'
    cpl, mpl = pct(cu, r['cl']), pct(mu, r['ml'])
    util = []
    if cpl is not None and cpl > T_POD: util.append('HIGH_CPU')
    if mpl is not None and mpl > T_POD: util.append('HIGH_MEM')

    pod = dict(ns=ns, name=md['name'], node=node, phase=phase, status=status, active=active,
               ready='%d/%d' % (ready, total), ready_ok=ready_ok, restarts=restarts,
               lastterm=','.join(lastterm), wl=key, spec=spec, labels=md.get('labels') or {},
               age=age(st.get('startTime') or md.get('creationTimestamp')),
               cu=cu, mu=mu, cpl=cpl, mpl=mpl, tags=tags, util=util, sev=sev, **r)
    PODS.append(pod)
    PODS_NS[ns].append(pod)
    if key:
        WL[key]['pods'].append(pod)
    if nd:
        nd['app_pods'] += 1
        nd['app_cr'] += r['cr_raw']; nd['app_mr'] += r['mr_raw']
        nd['app_cu'] += cu or 0; nd['app_mu'] += mu or 0
        nd['ns'][ns] += 1

for w in WL.values():
    w['act'] = [p for p in w['pods'] if p['active']]
    if w['dyn']:
        w['desired'] = len(w['act'])
        w['ready'] = sum(1 for p in w['act'] if p['ready_ok'])
    w['nodes'] = Counter(short(p['node']) for p in w['act'] if p['node'])
    # spec representatif: dari pod aktif (sudah termasuk default LimitRange), fallback ke template
    w['rspec'] = w['act'][0]['spec'] if w['act'] else w['spec']
    w['pdb'] = ''

def purpose(w):
    l = dict(w['tlabels']); l.update(w['labels'])
    parts = []
    for k in ('app.kubernetes.io/part-of', 'app.kubernetes.io/component', 'component', 'tier'):
        v = l.get(k)
        if v and v not in parts: parts.append(v)
    if not parts:
        v = l.get('app.kubernetes.io/name') or l.get('app')
        if v: parts.append(v)
    return '/'.join(parts)

def image(spec):
    imgs = []
    for c in spec.get('containers') or []:
        i = (c.get('image') or '').split('/')[-1]
        if '@sha256:' in i:
            n, d = i.split('@sha256:', 1); i = n + '@' + d[:12]
        imgs.append(i)
    if not imgs: return ''
    return imgs[0] + (' +%d' % (len(imgs) - 1) if len(imgs) > 1 else '')

HA_KINDS = ('Deployment', 'StatefulSet', 'DeploymentConfig')

def spread(spec):
    s = []
    if (spec.get('affinity') or {}).get('podAntiAffinity'): s.append('AA')
    if spec.get('topologySpreadConstraints'): s.append('TSC')
    return '+'.join(s)

def latest(spec):
    out = []
    for c in spec.get('containers') or []:
        last = (c.get('image') or '').split('/')[-1]
        if last.endswith(':latest') or (':' not in last and '@' not in last):
            out.append(c.get('name'))
    return out

def wl_tags(w):
    t = []; k = w['kind']
    if k == 'CronJob':
        if 'SUSPENDED' in w['extra']: t.append('SUSPENDED')
    else:
        if k == 'Pod': t.append('BARE_POD')
        d, r = w['desired'], w['ready']
        if d == 0: t.append('SCALED_0')
        elif r == 0: t.append('DOWN')
        elif r < d: t.append('DEGRADED')
    if k not in ('DaemonSet', 'CronJob', 'Job') and len(w['act']) > 1 and len(w['nodes']) == 1:
        t.append('SAME_NODE')
    if k in HA_KINDS and w['desired'] == 1:
        t.append('SINGLE_REPLICA')
    if k in HA_KINDS and (w['desired'] or 0) > 1 and not spread(w['rspec']):
        t.append('NO_SPREAD')
    if latest(w['spec'] or w['rspec']):
        t.append('LATEST_TAG')
    return t

WLS = sorted(WL.values(), key=lambda w: (w['ns'], w['kind'], w['name']))
for w in WLS:
    w['tags'] = wl_tags(w)

# ---------- service & route ----------
SVC = {}
for s in load('services'):
    if not isapp(s): continue
    ns, name = s['metadata']['namespace'], s['metadata']['name']
    sel = (s.get('spec') or {}).get('selector') or {}
    wls = set()
    if sel:
        for p in PODS_NS[ns]:
            if p['active'] and p['wl'] and all(p['labels'].get(k) == v for k, v in sel.items()):
                wls.add(p['wl'][2])
    SVC[(ns, name)] = wls

ROUTE_ROWS = []; ROUTE_CNT = Counter(); route_notls = []; route_http = []; route_dom = []
for r in load('routes'):
    if not isapp(r): continue
    ns = r['metadata']['namespace']; sp = r.get('spec') or {}; rname = r['metadata']['name']
    to = (sp.get('to') or {}).get('name', '')
    tls = sp.get('tls') or {}; host = sp.get('host') or ''
    t = []
    if not tls:
        t.append('NO_TLS'); route_notls.append('%s/%s' % (ns, rname))
    elif tls.get('insecureEdgeTerminationPolicy') == 'Allow':
        t.append('HTTP_ALLOWED'); route_http.append('%s/%s' % (ns, rname))
    if APPS_DOMAIN and '.apps.' in host and not host.endswith('.' + APPS_DOMAIN):
        t.append('OTHER_CLUSTER_DOMAIN'); route_dom.append(host)
    ROUTE_CNT[ns] += 1
    ROUTE_ROWS.append([ns, rname, host, sp.get('path') or '/', to, tls.get('termination', 'none'),
                       tls.get('insecureEdgeTerminationPolicy', '-') if tls else '-',
                       ','.join(sorted(SVC.get((ns, to), []))), ','.join(t) or 'OK'])

# ---------- pdb ----------
PDB_ROWS = []; pdb_block = []
for b in load('poddisruptionbudgets'):
    if not isapp(b): continue
    ns, name = b['metadata']['namespace'], b['metadata']['name']
    sp = b.get('spec') or {}; st = b.get('status') or {}
    sel = (sp.get('selector') or {}).get('matchLabels') or {}
    wls = set()
    if sel:
        for p in PODS_NS[ns]:
            if p['active'] and p['wl'] and all(p['labels'].get(k) == v for k, v in sel.items()):
                wls.add(p['wl'])
    exp, allowed = st.get('expectedPods', 0), st.get('disruptionsAllowed', 0)
    tag = 'OK'
    if exp > 0 and allowed == 0:
        tag = 'BLOCK_DRAIN'; pdb_block.append('%s/%s' % (ns, name))
    elif exp == 0:
        tag = 'NO_MATCH_POD'
    for k in wls:
        WL[k]['pdb'] = name + ('(BLOCK)' if tag == 'BLOCK_DRAIN' else '')
    PDB_ROWS.append([ns, name, sp.get('minAvailable', '-'), sp.get('maxUnavailable', '-'), exp,
                     st.get('currentHealthy', 0), allowed, ','.join(sorted(k[2] for k in wls)), tag])

# ---------- usage pvc (prometheus) ----------
def prom(name):
    try:
        with open(os.path.join(D, name + '.json')) as f:
            res = json.load(f)['data']['result']
        return {(r['metric'].get('namespace'), r['metric'].get('persistentvolumeclaim')): float(r['value'][1]) for r in res}
    except Exception:
        return None
P_USED, P_CAP, P_USED7 = prom('pvc_used'), prom('pvc_cap'), prom('pvc_used_7d')
HAS_PVC_METRIC = bool(P_USED)

# ---------- pvc ----------
PVC_USERS = defaultdict(set); PVC_DONE = Counter()
for p in PODS:
    for v in p['spec'].get('volumes') or []:
        c = (v.get('persistentVolumeClaim') or {}).get('claimName')
        if not c: continue
        if p['active']: PVC_USERS[(p['ns'], c)].add(p['wl'][2] if p['wl'] else p['name'])
        else: PVC_DONE[(p['ns'], c)] += 1

PVC_ROWS = []; PVC_CNT = Counter(); PVC_SIZE = defaultdict(float); PVC_USEDNS = defaultdict(float); pvc_bad = []; pvc_unused = 0; pvc_high = []
for c in load('persistentvolumeclaims'):
    if not isapp(c): continue
    ns, name = c['metadata']['namespace'], c['metadata']['name']
    sp = c.get('spec') or {}; st = c.get('status') or {}
    size = (st.get('capacity') or {}).get('storage') or ((sp.get('resources') or {}).get('requests') or {}).get('storage')
    phase = st.get('phase', 'Unknown')
    users = sorted(PVC_USERS.get((ns, name), []))
    tag = 'OK'
    if phase != 'Bound':
        tag = 'NOT_BOUND'; pvc_bad.append('%s/%s' % (ns, name))
    elif not users and PVC_DONE[(ns, name)]:
        tag = 'USED_BY_COMPLETED'; users = ['%d pod completed' % PVC_DONE[(ns, name)]]
    elif not users:
        tag = 'UNUSED'; pvc_unused += 1
    PVC_CNT[ns] += 1; PVC_SIZE[ns] += mem(size) or 0
    used = (P_USED or {}).get((ns, name)); cap = (P_CAP or {}).get((ns, name)) or mem(size)
    used7 = (P_USED7 or {}).get((ns, name))
    up = pct(used, cap)
    growth = (used - used7) / 7 if used is not None and used7 is not None else None
    full = '-'
    if growth is not None and growth > 0 and cap and used is not None:
        full = '%d hari' % ((cap - used) / growth)
    elif growth is not None:
        full = 'tidak naik'
    if used is not None: PVC_USEDNS[ns] += used
    if up is not None and up > T_PVC:
        pvc_high.append('%s/%s(%s)' % (ns, name, fp(up)))
        tag = 'HIGH_USAGE' if tag == 'OK' else tag + ',HIGH_USAGE'
    gtxt = '-' if growth is None else ('%s%s/hari' % ('+' if growth >= 0 else '-', fm(abs(growth))))
    PVC_ROWS.append([ns, name, phase, size, fm(used), fp(up), gtxt, full, sp.get('storageClassName'),
                     ','.join(sp.get('accessModes') or []), sp.get('volumeMode', 'Filesystem'), ','.join(users), tag])

# ---------- quota & limitrange ----------
def qval(res, v):
    if 'cpu' in res: return cpu(v)
    if 'memory' in res or 'storage' in res: return mem(v)
    try: return float(v)
    except (TypeError, ValueError): return mem(v)

QUOTA_ROWS = []; QUOTA_NS = set(); quota_warn = []
for q in load('resourcequotas'):
    if not isapp(q): continue
    ns, name = q['metadata']['namespace'], q['metadata']['name']
    QUOTA_NS.add(ns)
    st = q.get('status') or {}; hard = st.get('hard') or {}; used = st.get('used') or {}
    for res in sorted(hard):
        p = pct(qval(res, used.get(res, '0')), qval(res, hard[res]))
        tag = 'OK'
        if p is not None and p > T_QUOTA:
            tag = 'HIGH'; quota_warn.append('%s/%s(%s %s)' % (ns, name, res, fp(p)))
        QUOTA_ROWS.append([ns, name, res, used.get(res, '0'), hard[res], fp(p), tag])

LR_ROWS = []; LR_NS = set()
for l in load('limitranges'):
    if not isapp(l): continue
    ns = l['metadata']['namespace']; LR_NS.add(ns)
    for it in (l.get('spec') or {}).get('limits') or []:
        dr = it.get('defaultRequest') or {}; df = it.get('default') or {}; mx = it.get('max') or {}
        LR_ROWS.append([ns, l['metadata']['name'], it.get('type'), dr.get('cpu'), dr.get('memory'),
                        df.get('cpu'), df.get('memory'), mx.get('cpu'), mx.get('memory')])

# ============================================================
# 1. INVENTORY NAMESPACE
# ============================================================
rows = []; T = Counter()
for ns in sorted(APP):
    pods = PODS_NS[ns]
    c = Counter(w['kind'] for w in WLS if w['ns'] == ns)
    other = sum(v for k, v in c.items() if k not in ('Deployment', 'StatefulSet', 'DaemonSet', 'DeploymentConfig', 'CronJob'))
    v = dict(pods=len(pods), run=sum(1 for p in pods if p['phase'] == 'Running'),
             done=sum(1 for p in pods if p['phase'] == 'Succeeded'),
             notok=sum(1 for p in pods if p['phase'] != 'Succeeded' and not p['ready_ok']),
             dep=c['Deployment'], sts=c['StatefulSet'], ds=c['DaemonSet'], dc=c['DeploymentConfig'], cj=c['CronJob'], oth=other,
             hpa=sum(1 for w in WLS if w['ns'] == ns and w['hpa']), route=ROUTE_CNT[ns], pvc=PVC_CNT[ns])
    T.update(v)
    rows.append([ns] + [v[k] for k in ('pods', 'run', 'done', 'notok', 'dep', 'sts', 'ds', 'dc', 'cj', 'oth', 'hpa', 'route', 'pvc')]
                + ['Y' if ns in QUOTA_NS else 'N', 'Y' if ns in LR_NS else 'N', APP[ns]['requester'], APP[ns]['created'], APP[ns]['desc'][:40]])
if rows:
    rows.append(['TOTAL'] + [T[k] for k in ('pods', 'run', 'done', 'notok', 'dep', 'sts', 'ds', 'dc', 'cj', 'oth', 'hpa', 'route', 'pvc')]
                + [len(QUOTA_NS), len(LR_NS), '', '', ''])
table('namespace', ['NAMESPACE', 'PODS', 'RUNNING', 'COMPLETED', 'NOT_OK', 'DEPLOY', 'STS', 'DS', 'DC', 'CRONJOB', 'OTHER',
                    'HPA', 'ROUTE', 'PVC', 'QUOTA', 'LIMITRANGE', 'REQUESTER', 'CREATED', 'DESCRIPTION'], rows)

rows = []; hk_warn = []
for ns in sorted(APP):
    done = [p for p in PODS_NS[ns] if not p['active']]
    if not done: continue
    c = Counter('EVICTED' if 'EVICTED' in p['tags'] else p['phase'] for p in done)
    ages = [p['age'] for p in done if p['age'] is not None]
    tag = 'OK'
    if len(done) > T_HK:
        tag = 'CLEANUP'; hk_warn.append('%s(%d pod)' % (ns, len(done)))
    rows.append([ns, c['Succeeded'], c['Failed'], c['EVICTED'], len(done),
                 '%d hari' % max(ages) if ages else '-', tag])
table('housekeeping', ['NAMESPACE', 'COMPLETED', 'FAILED', 'EVICTED', 'TOTAL', 'TERTUA', 'RESULT'], rows)
if not APP:
    result('Check Housekeeping', 'SKIP', 'Tidak ada namespace aplikasi')
elif hk_warn:
    result('Check Housekeeping', 'WARN', 'Pod selesai > %d per namespace: %s' % (T_HK, lst(hk_warn, 3)))
else:
    result('Check Housekeeping', 'PASS', '%d pod Completed/Failed, di bawah %d per namespace' % (sum(r[4] for r in rows), T_HK))

# ============================================================
# 2. WORKLOAD & PERUNTUKKAN
# ============================================================
rows = []
for w in WLS:
    rd = '-' if w['kind'] == 'CronJob' else '%s/%s' % (w['ready'], w['desired'])
    dist = ','.join('%s:%d' % kv for kv in sorted(w['nodes'].items()))
    ha = w['kind'] in HA_KINDS
    rows.append([w['ns'], w['kind'], w['name'], rd, w['hpa'], w['pdb'] if ha else '', spread(w['rspec']) if ha else '',
                 purpose(w), image(w['spec'] or w['rspec']), dist, ','.join(w['tags']) or 'OK', w['extra']])
table('workload', ['NAMESPACE', 'KIND', 'NAME', 'READY', 'HPA', 'PDB', 'SPREAD', 'APP_LABEL', 'IMAGE', 'NODE_DISTRIBUTION', 'RESULT', 'NOTE'], rows)
table('route', ['NAMESPACE', 'ROUTE', 'HOST', 'PATH', 'SERVICE', 'TLS', 'INSECURE_POLICY', 'WORKLOAD', 'RESULT'], sorted(ROUTE_ROWS))
table('pdb', ['NAMESPACE', 'PDB', 'MIN_AVAILABLE', 'MAX_UNAVAILABLE', 'EXPECTED', 'HEALTHY', 'ALLOWED_DISRUPTION', 'WORKLOAD', 'RESULT'], sorted(PDB_ROWS))

no_pdb = ['%s/%s' % (w['ns'], w['name']) for w in WLS if w['kind'] in HA_KINDS and (w['desired'] or 0) > 1 and not w['pdb']]
if not APP:
    result('Check PDB', 'SKIP', 'Tidak ada namespace aplikasi')
elif pdb_block or no_pdb:
    d = []
    if pdb_block: d.append('%d PDB blok drain (allowed 0): %s' % (len(pdb_block), lst(pdb_block, 3)))
    if no_pdb: d.append('%d workload multi replica tanpa PDB' % len(no_pdb))
    result('Check PDB', 'WARN', '; '.join(d))
else:
    result('Check PDB', 'PASS', '%d PDB, tidak ada yang blok drain' % len(PDB_ROWS))

# best practice: image tag & route tls
lt = ['%s/%s' % (w['ns'], w['name']) for w in WLS if 'LATEST_TAG' in w['tags']]
if not APP:
    result('Check Image Tag', 'SKIP', 'Tidak ada namespace aplikasi')
elif lt:
    result('Check Image Tag', 'WARN', '%d workload pakai :latest/tanpa tag: %s' % (len(lt), lst(lt, 3)))
else:
    result('Check Image Tag', 'PASS', 'Semua image pakai tag versi/digest')
if not APP:
    result('Check Route TLS', 'SKIP', 'Tidak ada namespace aplikasi')
elif route_notls or route_http or route_dom:
    d = []
    if route_notls: d.append('%d route tanpa TLS: %s' % (len(route_notls), lst(route_notls, 3)))
    if route_http: d.append('%d route izinkan HTTP' % len(route_http))
    if route_dom: d.append('%d host domain cluster lain: %s' % (len(route_dom), lst(route_dom, 2)))
    result('Check Route TLS', 'WARN', '; '.join(d))
else:
    result('Check Route TLS', 'PASS', '%d route pakai TLS' % len(ROUTE_ROWS))

wl_down = ['%s/%s' % (w['ns'], w['name']) for w in WLS if 'DOWN' in w['tags']]
wl_deg = ['%s/%s' % (w['ns'], w['name']) for w in WLS if 'DEGRADED' in w['tags']]
wl_zero = sum(1 for w in WLS if 'SCALED_0' in w['tags'])
wl_cnt = sum(1 for w in WLS if w['kind'] != 'CronJob')
if not APP:
    result('Check Workload Replica', 'SKIP', 'Tidak ada namespace aplikasi')
elif wl_down:
    result('Check Workload Replica', 'FAIL', '%d down: %s' % (len(wl_down), lst(wl_down)) + ('; %d degraded' % len(wl_deg) if wl_deg else ''))
elif wl_deg:
    result('Check Workload Replica', 'WARN', '%d degraded: %s' % (len(wl_deg), lst(wl_deg)))
else:
    result('Check Workload Replica', 'PASS', '%d workload ready' % wl_cnt + (', %d scaled 0' % wl_zero if wl_zero else ''))

# ============================================================
# 3. DISTRIBUSI POD PER NODE
# ============================================================
rows = []
for name in sorted(NODES):
    n = NODES[name]
    top = ', '.join('%s(%d)' % kv for kv in n['ns'].most_common(3))
    rows.append([short(name), n['roles'], n['status'], n['app_pods'], n['pods'], n['podcap'] or '-',
                 fc(n['app_cr']), fm(n['app_mr']), fc(n['app_cu']) if HAS_METRICS else '-', fm(n['app_mu']) if HAS_METRICS else '-', top])
table('distribution', ['NODE', 'ROLE', 'STATUS', 'APP_PODS', 'ALL_PODS', 'POD_CAP', 'APP_CPU_REQ', 'APP_MEM_REQ',
                       'APP_CPU_USE', 'APP_MEM_USE', 'TOP_NAMESPACE'], rows)

rows = []
for w in WLS:
    iss = [t for t in w['tags'] if t in ('SAME_NODE', 'BARE_POD', 'SINGLE_REPLICA', 'NO_SPREAD')]
    if iss:
        rows.append([w['ns'], w['kind'], w['name'], len(w['act']), ','.join(sorted(w['nodes'])), ','.join(iss)])
table('distribution_issue', ['NAMESPACE', 'KIND', 'NAME', 'PODS', 'NODE', 'ISSUE'], rows)
same = [r[0] + '/' + r[2] for r in rows if 'SAME_NODE' in r[5]]
bare = [r[0] + '/' + r[2] for r in rows if 'BARE_POD' in r[5]]
single = [r[0] + '/' + r[2] for r in rows if 'SINGLE_REPLICA' in r[5]]
nospread = [r[0] + '/' + r[2] for r in rows if 'NO_SPREAD' in r[5]]
if not APP:
    result('Check Pod Distribution', 'SKIP', 'Tidak ada namespace aplikasi')
elif same or bare or single:
    d = []
    if same: d.append('%d workload semua replica di 1 node: %s' % (len(same), lst(same, 3)))
    if single: d.append('%d workload single replica: %s' % (len(single), lst(single, 3)))
    if bare: d.append('%d bare pod tanpa controller' % len(bare))
    if nospread: d.append('%d multi replica tanpa anti-affinity/TSC (info)' % len(nospread))
    result('Check Pod Distribution', 'WARN', '; '.join(d))
else:
    result('Check Pod Distribution', 'PASS', 'Replica tersebar di lebih dari 1 node' +
           (', %d tanpa anti-affinity/TSC (info)' % len(nospread) if nospread else ''))

# ============================================================
# 4. UTILISASI POD
# ============================================================
rows = []; TT = defaultdict(float)
for ns in sorted(APP):
    act = [p for p in PODS_NS[ns] if p['active']]
    v = dict(cr=ssum(p['cr'] for p in act), cl=ssum(p['cl_raw'] for p in act) or None, cu=ssum(p['cu'] for p in act),
             mr=ssum(p['mr'] for p in act), ml=ssum(p['ml_raw'] for p in act) or None, mu=ssum(p['mu'] for p in act))
    for k, x in v.items(): TT[k] += x or 0
    rows.append([ns, len(act), fc(v['cr']), fc(v['cl']), fc(v['cu']), fp(pct(v['cu'], v['cr'])),
                 fm(v['mr']), fm(v['ml']), fm(v['mu']), fp(pct(v['mu'], v['mr'])), fm(PVC_SIZE[ns]) if PVC_CNT[ns] else '-',
                 fm(PVC_USEDNS[ns]) if PVC_CNT[ns] and HAS_PVC_METRIC else '-'])
if rows:
    rows.append(['TOTAL', sum(r[1] for r in rows), fc(TT['cr']), fc(TT['cl']), fc(TT['cu']), fp(pct(TT['cu'], TT['cr'])),
                 fm(TT['mr']), fm(TT['ml']), fm(TT['mu']), fp(pct(TT['mu'], TT['mr'])), fm(sum(PVC_SIZE.values())),
                 fm(sum(PVC_USEDNS.values())) if HAS_PVC_METRIC else '-'])
table('ns_utilization', ['NAMESPACE', 'ACTIVE_PODS', 'CPU_REQ', 'CPU_LIM', 'CPU_USE', 'CPU%REQ',
                         'MEM_REQ', 'MEM_LIM', 'MEM_USE', 'MEM%REQ', 'PVC_SIZE', 'PVC_USED'], rows)

rows = []; high = []; over = []
for w in WLS:
    act = w['act']
    if not act: continue
    cr, cl = ssum(p['cr'] for p in act), ssum(p['cl'] for p in act)
    mr, ml = ssum(p['mr'] for p in act), ssum(p['ml'] for p in act)
    cu, mu = ssum(p['cu'] for p in act), ssum(p['mu'] for p in act)
    mcpl = max([p['cpl'] for p in act if p['cpl'] is not None] or [None]) if any(p['cpl'] is not None for p in act) else None
    mmpl = max(p['mpl'] for p in act if p['mpl'] is not None) if any(p['mpl'] is not None for p in act) else None
    rst = sum(p['restarts'] for p in act)
    t = []
    if cu is None and mu is None: t.append('NO_METRIC')
    if mcpl is not None and mcpl > T_POD: t.append('HIGH_CPU')
    if mmpl is not None and mmpl > T_POD: t.append('HIGH_MEM')
    pcr, pmr = pct(cu, cr), pct(mu, mr)
    if pcr is not None and pcr < T_LOW: t.append('OVERPROV_CPU')
    if pmr is not None and pmr < T_LOW: t.append('OVERPROV_MEM')
    if rst >= T_RST: t.append('RESTART')
    if 'HIGH_CPU' in t or 'HIGH_MEM' in t: high.append('%s/%s' % (w['ns'], w['name']))
    if 'OVERPROV_CPU' in t or 'OVERPROV_MEM' in t: over.append(w['name'])
    rows.append([w['ns'], w['kind'], w['name'], len(act), fc(cu), fc(cr), fc(cl), fp(pcr), fp(mcpl),
                 fm(mu), fm(mr), fm(ml), fp(pmr), fp(mmpl), rst, ','.join(t) or 'OK'])
table('workload_utilization', ['NAMESPACE', 'KIND', 'NAME', 'PODS', 'CPU_USE', 'CPU_REQ', 'CPU_LIM', 'CPU%REQ', 'MAX_CPU%LIM',
                               'MEM_USE', 'MEM_REQ', 'MEM_LIM', 'MEM%REQ', 'MAX_MEM%LIM', 'RESTARTS', 'RESULT'], rows)

rows = []
for p in sorted(PODS, key=lambda x: (x['ns'], x['name'])):
    iss = p['tags'] + p['util']
    if iss:
        rows.append([p['ns'], p['name'], short(p['node']), p['status'], p['ready'], p['restarts'], p['lastterm'],
                     fc(p['cu']), fp(p['cpl']), fm(p['mu']), fp(p['mpl']), ','.join(iss)])
table('pod_issue', ['NAMESPACE', 'POD', 'NODE', 'STATUS', 'READY', 'RESTARTS', 'LAST_TERMINATED',
                    'CPU_USE', 'CPU%LIM', 'MEM_USE', 'MEM%LIM', 'ISSUE'], rows)

# detail semua pod aplikasi, hanya CSV
table('pod_list', ['NAMESPACE', 'POD', 'WORKLOAD_KIND', 'WORKLOAD', 'NODE', 'PHASE', 'STATUS', 'READY', 'RESTARTS',
                   'CPU_REQ', 'CPU_LIM', 'CPU_USE', 'CPU%LIM', 'MEM_REQ', 'MEM_LIM', 'MEM_USE', 'MEM%LIM'],
      [[p['ns'], p['name'], p['wl'][1] if p['wl'] else '', p['wl'][2] if p['wl'] else '', p['node'], p['phase'], p['status'],
        p['ready'], p['restarts'], fc(p['cr']), fc(p['cl']), fc(p['cu']), fp(p['cpl']), fm(p['mr']), fm(p['ml']), fm(p['mu']), fp(p['mpl'])]
       for p in sorted(PODS, key=lambda x: (x['ns'], x['name']))], csv_only=True)

pod_fail = ['%s/%s' % (p['ns'], p['name']) for p in PODS if p['sev'] == 'FAIL']
pod_warn = ['%s/%s' % (p['ns'], p['name']) for p in PODS if p['sev'] == 'WARN']
n_act = sum(1 for p in PODS if p['active'])
if not APP:
    result('Check App Pods', 'SKIP', 'Tidak ada namespace aplikasi')
elif pod_fail:
    result('Check App Pods', 'FAIL', '%d pod aktif error: %s' % (len(pod_fail), lst(pod_fail, 3)) + ('; %d pod warning' % len(pod_warn) if pod_warn else ''))
elif pod_warn:
    result('Check App Pods', 'WARN', '%d pod not ready/restart/evicted/failed lama: %s' % (len(pod_warn), lst(pod_warn, 3)))
else:
    result('Check App Pods', 'PASS', '%d pod aktif Running dan Ready' % n_act)

if not APP:
    result('Check Pod Utilization', 'SKIP', 'Tidak ada namespace aplikasi')
elif not HAS_METRICS:
    result('Check Pod Utilization', 'SKIP', 'Metrics pod tidak tersedia (oc adm top pods)')
elif high:
    result('Check Pod Utilization', 'WARN', '%d workload > %d%% limit: %s' % (len(high), T_POD, lst(high, 3)))
else:
    result('Check Pod Utilization', 'PASS', 'Semua pod < %d%% limit' % T_POD + (', %d workload overprovision (info)' % len(over) if over else ''))

# ============================================================
# 5. RESOURCE CONFIG PER CONTAINER
# ============================================================
rows = []; noreq = 0; nolim = 0; ctot = 0; nordy = 0; noliv = 0; ptot = 0
for w in WLS:
    rep = w['desired'] if w['desired'] is not None else '-'
    for c in w['rspec'].get('containers') or []:
        cr, cl, mr, ml = cres(c)
        t = []
        if cr is None: t.append('NO_REQ_CPU')
        if mr is None: t.append('NO_REQ_MEM')
        if cl is None: t.append('NO_LIM_CPU')
        if ml is None: t.append('NO_LIM_MEM')
        ctot += 1
        if cr is None or mr is None: noreq += 1
        if cl is None or ml is None: nolim += 1
        probe = ''.join(x for x, k in (('R', 'readinessProbe'), ('L', 'livenessProbe'), ('S', 'startupProbe')) if c.get(k)) or '-'
        if w['kind'] not in ('CronJob', 'Job'):
            ptot += 1
            if not c.get('readinessProbe'): nordy += 1; t.append('NO_READINESS')
            if not c.get('livenessProbe'): noliv += 1; t.append('NO_LIVENESS')
        rows.append([w['ns'], w['kind'], w['name'], c.get('name'), rep, fc(cr), fc(cl), fm(mr), fm(ml), probe, ','.join(t) or 'OK'])
table('resource_config', ['NAMESPACE', 'KIND', 'NAME', 'CONTAINER', 'REPLICAS', 'CPU_REQ', 'CPU_LIM', 'MEM_REQ', 'MEM_LIM', 'PROBE', 'RESULT'], rows)
if not APP:
    result('Check Resource Limit', 'SKIP', 'Tidak ada namespace aplikasi')
elif noreq or nolim:
    result('Check Resource Limit', 'WARN', 'Dari %d container: %d tanpa request, %d tanpa limit' % (ctot, noreq, nolim))
else:
    result('Check Resource Limit', 'PASS', '%d container punya request dan limit' % ctot)
if not APP:
    result('Check Probe', 'SKIP', 'Tidak ada namespace aplikasi')
elif nordy or noliv:
    result('Check Probe', 'WARN', 'Dari %d container: %d tanpa readiness, %d tanpa liveness' % (ptot, nordy, noliv))
else:
    result('Check Probe', 'PASS', '%d container punya readiness dan liveness' % ptot)

# ============================================================
# 6. QUOTA & LIMITRANGE
# ============================================================
table('quota', ['NAMESPACE', 'QUOTA', 'RESOURCE', 'USED', 'HARD', 'USE%', 'RESULT'], QUOTA_ROWS)
table('limitrange', ['NAMESPACE', 'NAME', 'TYPE', 'DEF_REQ_CPU', 'DEF_REQ_MEM', 'DEF_LIM_CPU', 'DEF_LIM_MEM', 'MAX_CPU', 'MAX_MEM'], LR_ROWS)
if not APP:
    result('Check Quota', 'SKIP', 'Tidak ada namespace aplikasi')
elif quota_warn:
    result('Check Quota', 'WARN', 'Di atas %d%%: %s' % (T_QUOTA, lst(quota_warn, 3)))
elif QUOTA_NS:
    result('Check Quota', 'PASS', '%d/%d namespace pakai quota, semua < %d%%' % (len(QUOTA_NS), len(APP), T_QUOTA))
else:
    result('Check Quota', 'WARN', 'Tidak ada ResourceQuota/LimitRange, namespace bisa pakai resource tanpa batas' if not LR_NS
           else 'Tidak ada ResourceQuota di namespace aplikasi (info)')

# ============================================================
# 7. PVC
# ============================================================
table('pvc', ['NAMESPACE', 'PVC', 'STATUS', 'CAPACITY', 'USED', 'USE%', 'GROWTH_7D', 'EST_FULL', 'STORAGECLASS',
              'ACCESS', 'MODE', 'USED_BY', 'RESULT'], sorted(PVC_ROWS))
nometric = '' if HAS_PVC_METRIC else '; usage PVC tidak tersedia (Thanos tidak bisa diakses)'
if not APP:
    result('Check PVC', 'SKIP', 'Tidak ada namespace aplikasi')
elif pvc_bad or pvc_high:
    d = []
    if pvc_bad: d.append('%d PVC tidak Bound: %s' % (len(pvc_bad), lst(pvc_bad, 3)))
    if pvc_high: d.append('%d PVC usage > %d%%: %s' % (len(pvc_high), T_PVC, lst(pvc_high, 3)))
    result('Check PVC', 'WARN', '; '.join(d) + nometric)
elif not HAS_PVC_METRIC and PVC_ROWS:
    result('Check PVC', 'WARN', '%d PVC Bound' % len(PVC_ROWS) + nometric)
else:
    result('Check PVC', 'PASS', '%d PVC Bound, usage < %d%%' % (len(PVC_ROWS), T_PVC) + (', %d tidak dipakai pod manapun (info)' % pvc_unused if pvc_unused else ''))

# ============================================================
# 8. UTILISASI NODE
# ============================================================
rows = []; node_warn = []; node_fail = []; node_info = []; maxpods = Counter()
ROLE = defaultdict(lambda: defaultdict(float))
ROLE_MAXMEM = defaultdict(float)
for n in NODES.values():
    ROLE_MAXMEM[n['roles']] = max(ROLE_MAXMEM[n['roles']], n['mem'] or 0)
for name in sorted(NODES):
    n = NODES[name]
    cu_p, mu_p = pct(n['use_cpu'], n['cpu']), pct(n['use_mem'], n['mem'])
    cr_p, mr_p = pct(n['cr'], n['cpu']), pct(n['mr'], n['mem'])
    t = []
    if 'NotReady' in n['status']: t.append('NOT_READY')
    if cu_p is not None and cu_p > T_NODE: t.append('HIGH_CPU_USE')
    if mu_p is not None and mu_p > T_NODE: t.append('HIGH_MEM_USE')
    if cr_p is not None and cr_p > T_NODE: t.append('HIGH_CPU_REQ')
    if mr_p is not None and mr_p > T_NODE: t.append('HIGH_MEM_REQ')
    if 'NOT_READY' in t: node_fail.append(short(name))
    elif t: node_warn.append('%s(%s)' % (short(name), ','.join(t)))
    if n['podcap'] > T_MAXPODS:
        t.append('MAXPODS_%d' % n['podcap']); maxpods[n['podcap']] += 1
    # info, tidak dihitung WARN
    info = []
    ml_p = pct(n['ml'], n['mem'])
    if ml_p is not None and ml_p > 100: info.append('MEM_LIM_OVERCOMMIT')
    if n['mem'] and n['mem'] < 0.8 * ROLE_MAXMEM[n['roles']]: info.append('SMALLER_THAN_PEER')
    if 'SMALLER_THAN_PEER' in info: node_info.append('%s(%s vs %s)' % (short(name), fm(n['mem']), fm(ROLE_MAXMEM[n['roles']])))
    t += info
    rows.append([short(name), n['roles'], n['status'], fc(n['cpu']), fc(n['use_cpu']), fp(cu_p), fp(cr_p), fp(pct(n['cl'], n['cpu'])),
                 fm(n['mem']), fm(n['use_mem']), fp(mu_p), fp(mr_p), fp(pct(n['ml'], n['mem'])),
                 '%d/%s' % (n['pods'], n['podcap'] or '-'), ','.join(t) or 'OK'])
    g = ROLE[n['roles']]
    g['n'] += 1
    for k in ('cpu', 'mem', 'cr', 'mr', 'app_cr', 'app_mr'): g[k] += n[k] or 0
    g['ucpu'] += n['use_cpu'] or 0; g['umem'] += n['use_mem'] or 0
    g['metric'] += 1 if n['use_cpu'] is not None else 0
table('node_utilization', ['NODE', 'ROLE', 'STATUS', 'CPU_ALLOC', 'CPU_USE', 'CPU_USE%', 'CPU_REQ%', 'CPU_LIM%',
                           'MEM_ALLOC', 'MEM_USE', 'MEM_USE%', 'MEM_REQ%', 'MEM_LIM%', 'PODS', 'RESULT'], rows)

rows = []
for role in sorted(ROLE):
    g = ROLE[role]
    rows.append([role, int(g['n']), fc(g['cpu']), fp(pct(g['ucpu'], g['cpu']) if g['metric'] else None),
                 fp(pct(g['cr'], g['cpu'])), fc(g['cpu'] - g['cr']), fp(pct(g['app_cr'], g['cpu'])),
                 fm(g['mem']), fp(pct(g['umem'], g['mem']) if g['metric'] else None),
                 fp(pct(g['mr'], g['mem'])), fm(g['mem'] - g['mr']), fp(pct(g['app_mr'], g['mem']))])
table('role_capacity', ['ROLE', 'NODES', 'CPU_ALLOC', 'CPU_USE%', 'CPU_REQ%', 'CPU_FREE_REQ', 'APP_CPU_REQ%',
                        'MEM_ALLOC', 'MEM_USE%', 'MEM_REQ%', 'MEM_FREE_REQ', 'APP_MEM_REQ%'], rows)

if node_fail:
    result('Check Node Utilization', 'FAIL', 'NotReady: %s' % lst(node_fail))
elif node_warn or maxpods:
    d = []
    if node_warn: d.append('Di atas %d%%: %s' % (T_NODE, lst(node_warn, 3)))
    if maxpods: d.append('maxPods %s di %d node (batas %d)' % ('/'.join(str(k) for k in maxpods), sum(maxpods.values()), T_MAXPODS))
    if node_info: d.append('memory lebih kecil dari node se-role: %s' % lst(node_info, 3))
    result('Check Node Utilization', 'WARN', '; '.join(d))
elif not any(n['use_cpu'] is not None for n in NODES.values()):
    result('Check Node Utilization', 'WARN', 'Metrics node tidak tersedia, hanya request/limit')
else:
    result('Check Node Utilization', 'PASS', 'Usage dan request semua node < %d%%' % T_NODE)

# ---------- overview & result ----------
kinds = Counter(w['kind'] for w in WLS)
with open(os.path.join(D, 'overview.tsv'), 'w') as f:
    for k, v in (('Namespace aplikasi', len(APP)),
                 ('Workload', '%d (%s)' % (len(WLS), ', '.join('%s %d' % kv for kv in sorted(kinds.items())))),
                 ('Pod aktif', n_act),
                 ('Pod completed/failed', len(PODS) - n_act),
                 ('Container', ctot),
                 ('CPU request / usage', '%s / %s core' % (fc(TT['cr']), fc(TT['cu']) if HAS_METRICS else '-')),
                 ('Memory request / usage', '%s / %s' % (fm(TT['mr']), fm(TT['mu']) if HAS_METRICS else '-')),
                 ('Metrics pod/node', 'tersedia' if HAS_METRICS else 'TIDAK tersedia'),
                 ('Metrics PVC (Thanos)', 'tersedia' if HAS_PVC_METRIC else 'TIDAK tersedia')):
        f.write('%s\t: %s\n' % (k, clean(v)))
with open(os.path.join(D, 'results.tsv'), 'w') as f:
    for k, s, d in RESULTS:
        f.write('%s\t%s\t%s\n' % (k, s, d))
PYEOF

export PLATFORM_NS_REGEX INCLUDE_NS_REGEX RES_THRESHOLD POD_THRESHOLD LOW_USAGE QUOTA_THRESHOLD RESTART_THRESHOLD HOUSEKEEP_THRESHOLD MAX_PODS_WARN PVC_THRESHOLD APPS_DOMAIN
if ! "$PY" "$TMP/analyze.py" "$TMP" "$CSV_DIR"; then
  echo -e "${RED}Analisa data gagal, cek error python di atas.${NC}"
  exit 1
fi
while IFS=$'\t' read -r k s d; do set_result "$k" "$s" "$d"; done < "$TMP/results.tsv"

echo
column -t -s $'\t' < "$TMP/overview.tsv"

############################ 1. INVENTORY NAMESPACE ############################
section "1. INVENTORY NAMESPACE APLIKASI (jumlah pod & workload)"
echo "NOT_OK = pod aktif yang belum Running/Ready, OTHER = owner lain (Job, operator CR, VM, dll)"
echo
show namespace "Tidak ada namespace aplikasi (cek PLATFORM_NS_REGEX / INCLUDE_NS_REGEX)"
sub "Housekeeping pod Completed/Failed/Evicted (threshold ${HOUSEKEEP_THRESHOLD} per namespace)"
show housekeeping "Tidak ada"

############################ 2. WORKLOAD ############################
section "2. WORKLOAD & PERUNTUKKAN"
echo "APP_LABEL dari label part-of/component/app, NODE_DISTRIBUTION = node:jumlah_pod"
echo "PDB = nama PDB yang meng-cover workload, SPREAD: AA = podAntiAffinity, TSC = topologySpreadConstraints"
echo "RESULT: DOWN = 0 ready, DEGRADED = ready < desired, SAME_NODE = semua replica di 1 node, BARE_POD = pod tanpa controller,"
echo "        SINGLE_REPLICA = hanya 1 replica (SPOF), NO_SPREAD = multi replica tanpa aturan sebaran, LATEST_TAG = image :latest/tanpa tag"
echo
show workload
sub "Route aplikasi (NO_TLS = HTTP plain, HTTP_ALLOWED = edge izinkan HTTP, OTHER_CLUSTER_DOMAIN = host *.apps cluster lain)"
show route "Tidak ada route"

############################ 3. DISTRIBUSI POD ############################
section "3. DISTRIBUSI POD APLIKASI PER NODE & HIGH AVAILABILITY"
show distribution
sub "Workload dengan risiko distribusi (SPOF)"
show distribution_issue "Tidak ada"
sub "PodDisruptionBudget (BLOCK_DRAIN = allowed disruption 0, menghambat drain saat upgrade/MCP rollout)"
show pdb "Tidak ada PDB di namespace aplikasi"

############################ 4. UTILISASI POD ############################
section "4. UTILISASI POD (threshold ${POD_THRESHOLD}% dari limit)"
echo "Catatan: usage dari oc adm top (snapshot saat ini), capture juga Grafana > Kubernetes / Compute Resources / Namespace (Workloads), last 30 days"
sub "Per namespace"
show ns_utilization
sub "Per workload (OVERPROV_CPU/MEM = usage < ${LOW_USAGE}% dari request, validasi dengan Grafana sebelum right-sizing)"
show workload_utilization
sub "Pod bermasalah (status, restart >= ${RESTART_THRESHOLD}, OOMKilled, usage > ${POD_THRESHOLD}% limit)"
show pod_issue "Tidak ada"

############################ 5. RESOURCE CONFIG ############################
section "5. RESOURCE REQUEST & LIMIT PER CONTAINER"
echo "Nilai diambil dari pod aktif (sudah termasuk default LimitRange), fallback ke template jika tidak ada pod"
echo "PROBE: R = readiness, L = liveness, S = startup"
echo
show resource_config

############################ 6. QUOTA ############################
section "6. RESOURCEQUOTA & LIMITRANGE (threshold ${QUOTA_THRESHOLD}%)"
sub "ResourceQuota"
show quota "Tidak ada ResourceQuota"
sub "LimitRange"
show limitrange "Tidak ada LimitRange"

############################ 7. PVC ############################
section "7. PVC APLIKASI (threshold ${PVC_THRESHOLD}%)"
echo "USED dari kubelet_volume_stats (Thanos), GROWTH_7D = rata rata kenaikan per hari 7 hari terakhir, EST_FULL = estimasi sisa hari sampai penuh"
echo "Catatan: PVC block mode (volumeMode Block) dan PVC yang tidak sedang di-mount pod tidak punya data usage"
echo
show pvc "Tidak ada PVC"

############################ 8. UTILISASI NODE ############################
section "8. UTILISASI NODE (threshold ${RES_THRESHOLD}%)"
echo "USE = usage aktual (oc adm top), REQ/LIM = total request/limit semua pod di node vs allocatable"
echo "MAXPODS_x = maxPods di atas ${MAX_PODS_WARN}, MEM_LIM_OVERCOMMIT dan SMALLER_THAN_PEER = info"
echo
show node_utilization
sub "Kapasitas per role (FREE_REQ = sisa allocatable yang belum di-request)"
show role_capacity

############################ SUMMARY ############################
section "SUMMARY"
echo "Environment : ${ENV_NAME}"
echo "API         : ${API_URL}"
echo "Version     : ${CLUSTER_VERSION}"
echo "Date        : $(date '+%Y-%m-%d %H:%M:%S %Z')"
[ -n "$FETCH_FAILED" ] && echo -e "${YELLOW}Data gagal diambil: ${FETCH_FAILED} (hasil terkait tidak lengkap)${NC}"
echo
column -t -s $'\t' < "$TMP/overview.tsv"

print_rows() {
  for k in "$@"; do
    printf "  * %-26s %b  %s\n" "$k" "$(colorize "${RES[$k]}")" "${DET[$k]}"
  done
}

echo
echo -e "${BOLD}INVENTORY & HEALTH${NC}"
print_rows "${INVENTORY_KEYS[@]}"
echo
echo -e "${BOLD}CAPACITY & RESOURCE${NC}"
print_rows "${CAPACITY_KEYS[@]}"
echo
echo -e "${BOLD}BEST PRACTICE${NC}"
print_rows "${PRACTICE_KEYS[@]}"

n_fail=0; n_warn=0; n_pass=0
for k in "${INVENTORY_KEYS[@]}" "${CAPACITY_KEYS[@]}" "${PRACTICE_KEYS[@]}"; do
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
echo "CSV      : ${CSV_DIR}/"
sleep 1
