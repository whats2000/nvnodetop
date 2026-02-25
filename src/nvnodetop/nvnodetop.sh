#!/bin/bash
# GPU Monitor — nvtop-inspired cluster view with background per-node caching

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
MAGENTA='\033[0;35m'

# ── Config ─────────────────────────────────────────────────────────────────────
FETCH_INTERVAL=${1:-3}       # seconds between GPU polls per node  (arg 1)
DISPLAY_INTERVAL=${2:-1}     # UI refresh rate in seconds          (arg 2)
NODE_REFRESH_INTERVAL=30     # seconds between squeue calls
HISTORY_LEN=20               # samples kept per GPU for sparkline

# Spark block characters (8 levels, stored as array for safe multi-byte indexing)
SPARK=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')

# ── Cache dir ─────────────────────────────────────────────────────────────────
CACHE_DIR=$(mktemp -d /tmp/gpu_mon_XXXXXX)
declare -A FETCHER_PIDS

# ── Helpers ───────────────────────────────────────────────────────────────────
get_color() {
    local p=$1
    (( p >= 85 )) && printf '%s' "$RED"    && return
    (( p >= 60 )) && printf '%s' "$YELLOW" && return
    printf '%s' "$GREEN"
}

# draw_bar <pct> <width>
draw_bar() {
    local pct=$1 width=$2
    (( pct < 0   )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local c; c=$(get_color "$pct")
    printf '%s' "$c"
    (( filled > 0 )) && printf '█%.0s' $(seq 1 "$filled")
    printf '%s' "$RESET$DIM"
    (( empty  > 0 )) && printf '░%.0s' $(seq 1 "$empty")
    printf '%s' "$RESET"
}

# Compute bar width dynamically from terminal columns
#   Layout per row (non-bar chars): ~74 fixed + 2 bars
get_bar_width() {
    local cols; cols=$(tput cols 2>/dev/null || echo 120)
    local avail=$(( (cols - 74) / 2 ))
    (( avail < 8  )) && avail=8
    (( avail > 24 )) && avail=24
    printf '%s' "$avail"
}

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

cache_file() { printf '%s/%s'      "$CACHE_DIR" "${1//\//_}"; }
age_file()   { printf '%s/%s.age'  "$CACHE_DIR" "${1//\//_}"; }
hist_file()  { printf '%s/%s.h%s'  "$CACHE_DIR" "${1//\//_}" "$2"; }  # node, gpu_idx

# ── Sparkline history ─────────────────────────────────────────────────────────
# Called from main loop (not inside subshell) so writes persist.
update_history() {
    local node=$1
    local cf; cf=$(cache_file "$node")
    [[ ! -f "$cf" ]] && return
    local content; content=$(cat "$cf")
    local raw_gpu="${content%%---PROCS---*}"
    raw_gpu="${raw_gpu%$'\n'}"
    [[ -z "$raw_gpu" ]] && return

    while IFS=',' read -r idx _ util _rest; do
        idx=$(trim "$idx"); util=$(trim "$util")
        [[ -z "$idx" || "$idx" == "index" ]] && continue
        [[ "$util" =~ ^[0-9]+$ ]] || continue
        local hf; hf=$(hist_file "$node" "$idx")
        local -a history=()
        [[ -f "$hf" ]] && read -ra history < "$hf"
        history+=("$util")
        local len=${#history[@]}
        (( len > HISTORY_LEN )) && history=("${history[@]:$(( len - HISTORY_LEN ))}")
        printf '%s\n' "${history[*]}" > "$hf"
    done <<< "$raw_gpu"
}

render_sparkline() {
    local node=$1 idx=$2
    local hf; hf=$(hist_file "$node" "$idx")
    if [[ ! -f "$hf" ]]; then
        printf '%s' "${DIM}··${RESET}"
        return
    fi
    local -a vals; read -ra vals < "$hf"
    local out=''
    for v in "${vals[@]}"; do
        local lvl=$(( v * 7 / 100 ))
        (( lvl > 7 )) && lvl=7
        local c; c=$(get_color "$v")
        out+="${c}${SPARK[$lvl]}${RESET}"
    done
    printf '%b' "$out"
}

# ── SLURM ─────────────────────────────────────────────────────────────────────
expand_nodelist() {
    command -v scontrol &>/dev/null \
        && scontrol show hostnames "$1" 2>/dev/null \
        || echo "$1"
}

declare -a JOB_IDS=()
declare -A JOB_NAMES=() JOB_NODES=() JOB_NODE_IDX=()

refresh_jobs() {
    local raw
    raw=$(squeue --me --noheader --states=R --format="%i %j %N" 2>/dev/null)
    [[ -z "$raw" ]] && { JOB_IDS=(); last_node_refresh=$(date +%s); return; }

    local new_ids=()
    declare -A new_names new_nodes
    while read -r jid jname nl; do
        [[ -z "$jid" ]] && continue
        local expanded; expanded=$(expand_nodelist "$nl")
        new_ids+=("$jid")
        new_names[$jid]="$jname"
        new_nodes[$jid]="$expanded"
        while IFS= read -r n; do [[ -n "$n" ]] && start_fetcher "$n"; done <<< "$expanded"
        [[ -z "${JOB_NODE_IDX[$jid]+x}" ]] && JOB_NODE_IDX[$jid]=0
    done <<< "$raw"

    JOB_IDS=("${new_ids[@]}")
    for k in "${!new_names[@]}"; do JOB_NAMES[$k]="${new_names[$k]}"; done
    for k in "${!new_nodes[@]}"; do JOB_NODES[$k]="${new_nodes[$k]}"; done
    last_node_refresh=$(date +%s)
    local njobs=${#JOB_IDS[@]}
    (( njobs > 0 && job_idx >= njobs )) && job_idx=$(( njobs - 1 ))
    (( job_idx < 0 )) && job_idx=0
}

# ── Background fetcher ────────────────────────────────────────────────────────
_node_fetcher_loop() {
    local node=$1
    local cf; cf=$(cache_file "$node")
    local af; af=$(age_file   "$node")
    local tmp="${cf}.tmp"
    while true; do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            "$node" '
nvidia-smi \
  --query-gpu=index,name,utilization.gpu,memory.used,memory.total,\
temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,\
clocks_throttle_reasons.hw_thermal_slowdown,\
clocks_throttle_reasons.hw_power_brake_slowdown,\
ecc.errors.uncorrected.volatile.total \
  --format=csv,noheader,nounits 2>/dev/null
echo "---PROCS---"
python3 -c "
import subprocess, pwd, os
umap={}
for l in subprocess.check_output([\"nvidia-smi\",\"--query-gpu=index,gpu_uuid\",\"--format=csv,noheader,nounits\"]).decode().strip().splitlines():
    i,u=l.split(\", \",1); umap[u.strip()]=i.strip()
out=subprocess.check_output([\"nvidia-smi\",\"--query-compute-apps=gpu_uuid,pid,used_gpu_memory,process_name\",\"--format=csv,noheader,nounits\"]).decode().strip()
if not out: exit()
for l in out.splitlines():
    parts=[p.strip() for p in l.split(\",\",3)]
    if len(parts)<4: continue
    uuid,pid,mem,pname=parts
    idx=umap.get(uuid,\"?\")
    try: user=pwd.getpwuid(os.stat(f\"/proc/{pid}\").st_uid).pw_name
    except: user=\"?\"
    print(f\"{idx},{pid},{mem},{user},{pname}\")
" 2>/dev/null
' >"$tmp" 2>/dev/null \
        && mv -f "$tmp" "$cf" \
        && date +%s > "$af"
        sleep "$FETCH_INTERVAL"
    done
}

start_fetcher() {
    local node=$1
    [[ -n "${FETCHER_PIDS[$node]}" ]] && return
    _node_fetcher_loop "$node" &
    FETCHER_PIDS[$node]=$!
}

stop_all_fetchers() {
    for node in "${!FETCHER_PIDS[@]}"; do kill "${FETCHER_PIDS[$node]}" 2>/dev/null; done
    FETCHER_PIDS=()
}

# ── State ─────────────────────────────────────────────────────────────────────
last_node_refresh=0
SHOW_PROCS=0

# ── Rendering ─────────────────────────────────────────────────────────────────
render_gpu_section() {
    local raw_gpu=$1 node=$2
    local bw; bw=$(get_bar_width)

    if [[ -z "$raw_gpu" ]]; then
        printf "  ${DIM}Waiting for first data…${RESET}\n\n"
        printf "  ${DIM}%-${HISTORY_LEN}s${RESET}\n" "(no summary yet)"
        return
    fi

    # Column header
    printf "  ${BOLD}%-3s  %-18s  %5s  %-${bw}s %-4s  %-${bw}s %-12s  %-9s  %-10s  %-${HISTORY_LEN}s  %s${RESET}\n" \
           "GPU" "Name" "Temp" "Utilization" "%" "Memory" "Used/Tot MiB" "Power" "SM/MemMHz" "Util History" "Flags"

    # Accumulators for summary
    local sum_util=0 sum_mem_used=0 sum_mem_total=0
    local sum_pwr=0  sum_pwr_limit=0 gpu_count=0

    while IFS=',' read -r idx name util mem_used mem_total temp \
                            pwr_draw pwr_limit clk_sm clk_mem \
                            thr_therm thr_pwr ecc_unc; do
        idx=$(trim "$idx");       name=$(trim "$name")
        util=$(trim "$util");     mem_used=$(trim "$mem_used")
        mem_total=$(trim "$mem_total"); temp=$(trim "$temp")
        pwr_draw=$(trim "$pwr_draw");   pwr_limit=$(trim "$pwr_limit")
        clk_sm=$(trim "$clk_sm");       clk_mem=$(trim "$clk_mem")
        thr_therm=$(trim "$thr_therm"); thr_pwr=$(trim "$thr_pwr")
        ecc_unc=$(trim "$ecc_unc")
        pwr_draw=${pwr_draw%%.*}; pwr_limit=${pwr_limit%%.*}

        [[ "$util" =~ ^[0-9]+$ ]] || continue

        local mem_pct=0 pwr_pct=0
        (( mem_total > 0 )) && mem_pct=$(( mem_used * 100 / mem_total ))
        (( pwr_limit > 0 )) && pwr_pct=$(( pwr_draw  * 100 / pwr_limit ))

        local uc mc pc
        uc=$(get_color "$util"); mc=$(get_color "$mem_pct"); pc=$(get_color "$pwr_pct")

        local flags=''
        [[ "$thr_therm" == *Active* && "$thr_therm" != *Not* ]] && flags+="${RED}!THERM${RESET} "
        [[ "$thr_pwr"   == *Active* && "$thr_pwr"   != *Not* ]] && flags+="${YELLOW}!PWR${RESET} "
        [[ -n "$ecc_unc" && "$ecc_unc" != "0" && "$ecc_unc" != "N/A" ]] \
            && flags+="${MAGENTA}ECC:${ecc_unc}${RESET}"

        printf "  ${BOLD}%3s${RESET}  %-18.18s  ${CYAN}%3s°C${RESET}  " "$idx" "$name" "$temp"
        draw_bar "$util" "$bw";    printf " ${uc}%3d%%${RESET}  " "$util"
        draw_bar "$mem_pct" "$bw"; printf " ${mc}%5d${RESET}/%-5d  " "$mem_used" "$mem_total"
        printf "${pc}%3d${RESET}/%-3dW  " "$pwr_draw" "$pwr_limit"
        printf "${DIM}%4d/%-4d${RESET}  " "$clk_sm" "$clk_mem"
        render_sparkline "$node" "$idx"
        printf "  %b\n" "$flags"

        # Accumulate for summary
        (( sum_util      += util      ))
        (( sum_mem_used  += mem_used  ))
        (( sum_mem_total += mem_total ))
        (( sum_pwr       += pwr_draw  ))
        (( sum_pwr_limit += pwr_limit ))
        (( gpu_count++ ))
    done <<< "$raw_gpu"

    # ── Summary line ──────────────────────────────────────────────────────────
    if (( gpu_count > 0 )); then
        local avg_util=$(( sum_util / gpu_count ))
        local total_mem_pct=0
        (( sum_mem_total > 0 )) && total_mem_pct=$(( sum_mem_used * 100 / sum_mem_total ))
        local total_pwr_pct=0
        (( sum_pwr_limit > 0 )) && total_pwr_pct=$(( sum_pwr * 100 / sum_pwr_limit ))

        local uc mc pc
        uc=$(get_color "$avg_util"); mc=$(get_color "$total_mem_pct"); pc=$(get_color "$total_pwr_pct")

        printf "  ${DIM}%s${RESET}\n" "$(printf '╌%.0s' $(seq 1 78))"
        printf "  ${DIM}SUM${RESET}  %-18s  ${DIM}%5s${RESET}  " "($gpu_count GPUs)" ""
        draw_bar "$avg_util" "$bw";       printf " ${uc}%3d%%${RESET}  " "$avg_util"
        draw_bar "$total_mem_pct" "$bw";  printf " ${mc}%5d${RESET}/%-5d  " "$sum_mem_used" "$sum_mem_total"
        printf "${pc}%3d${RESET}/%-3dW\n" "$sum_pwr" "$sum_pwr_limit"
    fi
}

render_proc_section() {
    local raw_procs=$1
    printf "  ${DIM}%s${RESET}\n" "$(printf '·%.0s' $(seq 1 78))"
    printf "  ${BOLD}%-3s  %-7s  %-12s  %-30s  %s${RESET}\n" \
           "GPU" "PID" "User" "Command" "GPU Mem MiB"
    if [[ -z "$raw_procs" ]]; then
        printf "  ${DIM}  (no compute processes)${RESET}\n"
        return
    fi
    while IFS=',' read -r idx pid mem user pname; do
        idx=$(trim "$idx"); pid=$(trim "$pid"); mem=$(trim "$mem")
        user=$(trim "$user"); pname=$(trim "$pname")
        pname="${pname##*/}"
        printf "  ${BOLD}%3s${RESET}  %-7s  %-12.12s  %-30.30s  ${CYAN}%s${RESET}\n" \
               "$idx" "$pid" "$user" "$pname" "$mem"
    done <<< "$raw_procs"
}

render_node() {
    local node=$1 node_cur=$2 node_total=$3 job_cur=$4 job_total=$5 jid=$6 jname=$7
    local now; now=$(date '+%H:%M:%S')

    local cf; cf=$(cache_file "$node")
    local raw_gpu='' raw_procs=''
    if [[ -f "$cf" ]]; then
        local content; content=$(cat "$cf")
        raw_gpu="${content%%---PROCS---*}"
        raw_procs="${content#*---PROCS---}"
        raw_procs="${raw_procs#$'\n'}"
        raw_gpu="${raw_gpu%$'\n'}"
    fi

    # Staleness
    local age_label=''
    local af; af=$(age_file "$node")
    if [[ -f "$af" ]]; then
        local ts now_ts age
        ts=$(cat "$af"); now_ts=$(date +%s); age=$(( now_ts - ts ))
        (( age > FETCH_INTERVAL * 3 )) && age_label="${YELLOW} [stale ${age}s]${RESET}"
    fi

    local proc_hint="${DIM}p procs${RESET}"
    (( SHOW_PROCS )) && proc_hint="${BOLD}[p procs]${RESET}"

    printf "${DIM}  Job ${RESET}${BOLD}%-8s${RESET} ${DIM}%-18s${RESET}" "$jid" "$jname"
    printf "  ${DIM}job [%d/%d] ↑↓jobs  node [%d/%d] <>nodes  %b  q quit  poll:%ss disp:%ss${RESET}\n" \
           "$job_cur" "$job_total" "$node_cur" "$node_total" "$proc_hint" "$FETCH_INTERVAL" "$DISPLAY_INTERVAL"
    printf "${BOLD}${CYAN}  %-30s${RESET}%b\n" "$node" "$age_label"
    printf "${DIM}%s${RESET}\n" "$(printf '─%.0s' $(seq 1 78))"

    render_gpu_section "$raw_gpu" "$node"
    (( SHOW_PROCS )) && render_proc_section "$raw_procs"
}

# ── Terminal setup ────────────────────────────────────────────────────────────
cleanup() {
    stop_all_fetchers
    rm -rf "$CACHE_DIR"
    tput cnorm; tput rmcup; stty echo
    exit 0
}
trap cleanup INT TERM EXIT
tput smcup; tput civis; stty -echo

read_key() {
    local k
    IFS= read -r -s -n1 -t "$DISPLAY_INTERVAL" k
    if [[ $k == $'\x1b' ]]; then
        local seq; IFS= read -r -s -n2 -t 0.1 seq
        k="${k}${seq}"
    fi
    printf '%s' "$k"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
job_idx=0
refresh_jobs

while true; do
    now_ts=$(date +%s)
    (( now_ts - last_node_refresh >= NODE_REFRESH_INTERVAL )) && refresh_jobs

    njobs=${#JOB_IDS[@]}

    if (( njobs == 0 )); then
        tput cup 0 0
        printf "\n  ${YELLOW}No running SLURM jobs found.${RESET}  (retrying…)\n"
        tput ed
    else
        (( job_idx >= njobs )) && job_idx=$(( njobs - 1 ))
        jid="${JOB_IDS[$job_idx]}"
        jname="${JOB_NAMES[$jid]}"

        mapfile -t cur_nodes <<< "${JOB_NODES[$jid]}"
        cur_nodes=($(printf '%s\n' "${cur_nodes[@]}" | grep -v '^[[:space:]]*$'))
        ncount=${#cur_nodes[@]}

        nidx=${JOB_NODE_IDX[$jid]:-0}
        (( nidx >= ncount )) && nidx=$(( ncount - 1 ))
        (( nidx < 0 )) && nidx=0
        JOB_NODE_IDX[$jid]=$nidx

        node="${cur_nodes[$nidx]}"

        # Update sparkline history from latest cache (must run outside subshell)
        update_history "$node"

        frame=$(render_node "$node" \
                $(( nidx+1 )) "$ncount" $(( job_idx+1 )) "$njobs" "$jid" "$jname")
        tput cup 0 0
        printf '%b' "$frame"
        tput ed
    fi

    key=$(read_key)
    case "$key" in
        $'\x1b[C'|'>'|'.' )
            if (( njobs > 0 )); then
                jid="${JOB_IDS[$job_idx]}"
                mapfile -t _nn <<< "${JOB_NODES[$jid]}"
                _nn=($(printf '%s\n' "${_nn[@]}" | grep -v '^[[:space:]]*$'))
                nc=${#_nn[@]}
                JOB_NODE_IDX[$jid]=$(( (${JOB_NODE_IDX[$jid]:-0} + 1) % nc ))
            fi ;;
        $'\x1b[D'|'<'|',' )
            if (( njobs > 0 )); then
                jid="${JOB_IDS[$job_idx]}"
                mapfile -t _nn <<< "${JOB_NODES[$jid]}"
                _nn=($(printf '%s\n' "${_nn[@]}" | grep -v '^[[:space:]]*$'))
                nc=${#_nn[@]}
                JOB_NODE_IDX[$jid]=$(( (${JOB_NODE_IDX[$jid]:-0} - 1 + nc) % nc ))
            fi ;;
        $'\x1b[A'|'k'|'K' )   (( njobs > 0 )) && job_idx=$(( (job_idx - 1 + njobs) % njobs )) ;;
        $'\x1b[B'|'j'|'J' )   (( njobs > 0 )) && job_idx=$(( (job_idx + 1) % njobs )) ;;
        'p'|'P' )              (( SHOW_PROCS = !SHOW_PROCS )) ;;
        'q'|'Q' )              cleanup ;;
    esac
done
