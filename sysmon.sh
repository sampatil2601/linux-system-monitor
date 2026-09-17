#!/usr/bin/env bash

set -euo pipefail

readonly PROGRAM_NAME="sysmon"
readonly VERSION="1.0.0"

# Default configuration values
readonly DEFAULT_CPU_THRESHOLD=80
readonly DEFAULT_MEMORY_THRESHOLD=80
readonly DEFAULT_DISK_THRESHOLD=80
readonly DEFAULT_NETWORK_HOST="8.8.8.8"
readonly DEFAULT_LOG_FILE="./sysmon.log"
readonly DEFAULT_MAX_LOG_SIZE_KB=1024

readonly -a DEFAULT_SERVICES=("ssh" "cron")

CPU_THRESHOLD="$DEFAULT_CPU_THRESHOLD"
MEMORY_THRESHOLD="$DEFAULT_MEMORY_THRESHOLD"
DISK_THRESHOLD="$DEFAULT_DISK_THRESHOLD"
NETWORK_HOST="$DEFAULT_NETWORK_HOST"
LOG_FILE="$DEFAULT_LOG_FILE"
MAX_LOG_SIZE_KB="$DEFAULT_MAX_LOG_SIZE_KB"
SERVICES=("${DEFAULT_SERVICES[@]}")


print_version(){
       	printf '%s  version  %s\n' "$PROGRAM_NAME" "$VERSION"
}

print_help(){
	cat<<'EOF'
Linux System Health Monitor

Usage:
	./sysmon.sh [OPTIONS]

Options:
	--all			Show a complete system health report
	--cpu			Show CPU information and utilization
	--memory		Show memory usage
	--disk			Show filesystem/disk usage
	--processes		Show top processes by CPU/memory
	--network [HOST]	Show network information and connectivity
	--services		Show status of important systemd services
	--uptime		Show system uptime and load average

	--help			Display the help message
	--version		Display program version

Threshold options:
	--cpu-threshold N
	--memory-threshold N
	--disk-threshold N

Logging:
	--log			Enable logging
	--log-file FILE		Specify log file

Examples:

	./sysmon.sh --help
	./sysmon.sh --version
	./sysmon.sh --cpu
	./sysmon.sh --memory
	./sysmon.sh --all
	./sysmon.sh --network google.com

Exit codes:
	0	Success
	1	General error
	2	Invalid command-line usage
EOF
}

error(){
	printf 'Error: %s\n' "$*" >&2
}

get_cpu_model(){
	local model=""

	while IFS=: read -r key value; do
		if [[ "$key" == "model name" || "$key" == "Model" ]]; then
			value="${value#"${value%%[![:space: ]]*}"}"
			model="$value"
			break
		fi
	done < /proc/cpuinfo

	if [[ -z "$model" ]]; then
		printf 'Unknown\n'
		return 0;
	fi

	printf '%s\n' "$model"

}

get_logical_cpu_count(){
	local count=0

	while IFS= read -r line; do
		if [[ "$line" == processor* ]]; then
			((++count))
		fi
	done < /proc/cpuinfo

	if (( count == 0 )); then
		error "Unable to determine logical CPU count."
		return 1
	fi

	printf '%d\n' "$count"

}

read_cpu_counters(){
local line

if ! IFS= read -r line < /proc/stat; then
	error "Unable to read /proc/stat."
	return 1
fi

read -r cpu user nice system idle iowait irq softirq steal _ _ <<< "$line"

if [[ "$cpu" != "cpu" ]]; then
	error "Unexpected format in proc/stat."
	return 1
fi

if [[ -z "${steal:-}" ]]; then
	steal=0

fi

printf '%s %s %s %s %s %s %s %s %s\n' \
	"$user" \
	"$nice" \
	"$system" \
	"$idle" \
	"$iowait" \
	"$irq" \
	"$softirq" \
	"$steal"

}

calculate_cpu_utilization(){
	local user1="$1"
	local nice1="$2"
	local system1="$3"
	local idle1="$4"
	local iowait1="$5"
	local irq1="$6"
	local softirq1="$7"
	local steal1="$8"

	local user2="$9"
	local nice2="${10}"
	local system2="${11}"
	local idle2="${12}"
	local iowait2="${13}"
	local irq2="${14}"
	local softirq2="${15}"
	local steal2="${16}"

	local total1 total2
	local idle_total1 idle_total2
	local total_delta idle_delta busy_delta
	local utilization tenths

	total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
	total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))

	idle_total1=$((idle1 + iowait1))
	idle_total2=$((idle2 + iowait2))

	total_delta=$((total2 - total1))
	idle_delta=$((idle_total2 - idle_total1))
	busy_delta=$((total_delta - idle_delta))

	if (( total_delta <= 0 || busy_delta < 0 )); then
		error "Unable to calculate cpu utilization"
		return 1
	fi

	utilization_tenths=$((busy_delta * 1000 / total_delta))

	printf '%d.%d%%\n' \
	"$((utilization_tenths / 10))" \
	"$((utilization_tenths % 10))"
}


get_load_average(){

	local load1 load5 load15

	if ! read -r load1 load5 load15 _ < /proc/loadavg; then
		error "Unable to read /proc/loadavg."
		return 1
	fi

	printf '%s %s %s\n' "$load1" "$load5" "$load15"

}


show_cpu(){

	local model
	local logical_cpus
	local first
	local second
	local utilization
	local load1 load5 load15

	model=$(get_cpu_model)
	logical_cpus=$(get_logical_cpu_count)

	first=$(read_cpu_counters)

	sleep 1

	second=$(read_cpu_counters)

	#shellcheck disable=SC2086
	utilization=$(calculate_cpu_utilization $first $second)

	read -r load1 load5 load15 <<< "$(get_load_average)"

	printf '\nCPU Information\n'
	printf '%s\n' '----------------'
	printf 'Model			: %s\n' "$model"
	printf 'Logical CPUs		: %s\n' "$logical_cpus"
	local status

        status=$(check_threshold "$utilization" "$CPU_THRESHOLD")

        printf 'CPU Utilization         : %s [%s]\n' "$utilization" "$status"
	
	log_status "CPU utilization" "$utilization" "$status"

	printf 'Load Average		: %s %s %s\n' "$load1" "$load5" "$load15"

}


check_threshold() {
    local value="$1"
    local threshold="$2"

    if awk -v value="$value" -v threshold="$threshold" \
        'BEGIN { exit !(value >= threshold) }'; then
        printf 'WARNING\n'
    else
        printf 'OK\n'
    fi
}




get_memory_info() {
    local total_kb
    local available_kb
    local used_kb
    local usage_percent

    if [[ ! -r /proc/meminfo ]]; then
        error "Cannot read /proc/meminfo."
        return 1
    fi

    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

    if [[ -z "$total_kb" || -z "$available_kb" ]]; then
        error "Unable to read memory information."
        return 1
    fi

    used_kb=$((total_kb - available_kb))

    usage_percent=$(awk -v used="$used_kb" -v total="$total_kb" \
        'BEGIN { printf "%.1f", (used / total) * 100 }')

    printf '%s\n' "Memory Information"
    printf '%s\n' "------------------"
    printf 'Total Memory     : %.2f GB\n' "$(awk -v kb="$total_kb" 'BEGIN {printf "%.2f", kb/1024/1024}')"
    printf 'Used Memory      : %.2f GB\n' "$(awk -v kb="$used_kb" 'BEGIN {printf "%.2f", kb/1024/1024}')"
    printf 'Available Memory : %.2f GB\n' "$(awk -v kb="$available_kb" 'BEGIN {printf "%.2f", kb/1024/1024}')"
    local status

    status=$(check_threshold "$usage_percent" "$MEMORY_THRESHOLD")
    printf 'Memory Usage     : %s%% [%s]\n' "$usage_percent" "$status"
    log_status "Memory usage" "${usage_percent}%" "$status"
}


get_disk_info() {
    local filesystem
    local size
    local used
    local available
    local usage
    local mountpoint

    if ! df -P / >/dev/null 2>&1; then
        error "Unable to read disk information."
        return 1
    fi

    read -r filesystem size used available usage mountpoint < <(
        df -P / | awk 'NR==2'
    )

    if [[ -z "$filesystem" || -z "$mountpoint" ]]; then
        error "Unable to parse disk information."
        return 1
    fi

    printf '%s\n' "Disk Information"
    printf '%s\n' "----------------"
    printf 'Filesystem      : %s\n' "$filesystem"
    printf 'Size            : %s\n' "$size"
    printf 'Used            : %s\n' "$used"
    printf 'Available       : %s\n' "$available"
    local usage_value
    local status

    usage_value="${usage%\%}"
    status=$(check_threshold "$usage_value" "$DISK_THRESHOLD")

    printf 'Usage           : %s [%s]\n' "$usage" "$status"
    log_status "Disk usage" "$usage" "$status"
    printf 'Mount Point     : %s\n' "$mountpoint"

}


get_process_info() {
    printf '%s\n' "Process Information"
    printf '%s\n' "-------------------"
    printf '\n'

    printf '%s\n' "Top CPU Processes"
    printf '%s\n' "-----------------"

    ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -6

    printf '\n'

    printf '%s\n' "Top Memory Processes"
    printf '%s\n' "--------------------"

    ps -eo pid,pcpu,pmem,comm --sort=-pmem | head -6
}


get_network_info() {
    local host="${1:-8.8.8.8}"

    if [[ -z "$host" ]]; then
        error "Network host cannot be empty."
        return 2
    fi

    printf '%s\n' "Network Information"
    printf '%s\n' "-------------------"
    printf 'Target Host     : %s\n' "$host"

    if ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
        printf 'Connectivity    : Reachable\n'
	log_message "INFO" "Network connectivity to $host: reachable"
        return 0
    fi

    printf 'Connectivity    : Unreachable\n'
    log_message "WARNING" "Network connectivity to $host: unreachable"
    return 1
}


get_service_info() {
    local service
    local state
    local services=("ssh" "cron")

    printf '%s\n' "Service Information"
    printf '%s\n' "-------------------"

    if ! command -v systemctl >/dev/null 2>&1; then
        error "systemctl is not available on this system."
        return 1
    fi

    for service in "${SERVICES[@]}"; do
        state=$(systemctl is-active "$service" 2>/dev/null || true)

        if [[ -z "$state" ]]; then
            state="unknown"
        fi

        printf '%-10s: %s\n' "$service" "$state"
 
	if [[ "$state" == "active" ]]; then
        	log_message "INFO" "Service $service: active"
    	else
        	log_message "WARNING" "Service $service: $state"
    	fi
    done
}

load_config() {
    local config_file="${1:-sysmon.conf}"

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$key" == \#* ]] && continue

        value="${value%\"}"
        value="${value#\"}"

        case "$key" in
            CPU_THRESHOLD)
                CPU_THRESHOLD="$value"
                ;;
            MEMORY_THRESHOLD)
                MEMORY_THRESHOLD="$value"
                ;;
            DISK_THRESHOLD)
                DISK_THRESHOLD="$value"
                ;;
            NETWORK_HOST)
                NETWORK_HOST="$value"
                ;;
            SERVICES)
                read -r -a SERVICES <<< "$value"
                ;;
	    LOG_FILE)
    	        LOG_FILE="$value"
    	        ;;
	    MAX_LOG_SIZE_KB)
    		MAX_LOG_SIZE_KB="$value"
    		;;

        esac
    done < "$config_file"
}

check_log_size() {
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi

    local size_kb

    size_kb=$(du -k "$LOG_FILE" | awk '{print $1}')

    if (( size_kb >= MAX_LOG_SIZE_KB )); then
        : > "$LOG_FILE"
    fi
}


log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    check_log_size

    printf '%s [%s] %s\n' \
        "$timestamp" \
        "$level" \
        "$message" >> "$LOG_FILE"
}

log_status() {
    local component="$1"
    local value="$2"
    local status="$3"

    if [[ "$status" == "WARNING" ]]; then
        log_message "WARNING" "$component: $value [$status]"
    else
        log_message "INFO" "$component: $value [$status]"
    fi
}


main(){

	if [[ $# -eq 0 ]]; then
	   print_help
	   return 0
	fi

	case "$1" in
	    --help)
	    print_help
	    ;;

	    --version)
	    print_version
	    ;;

	    --cpu)
	    show_cpu
	    ;;

	    --memory)
	    get_memory_info
	    ;;

	    --disk)
	    get_disk_info
	    ;;

	    --processes)
	    get_process_info
	    ;;

	    --network)
	    get_network_info "${2:-$NETWORK_HOST}"
	    ;;

	    --services)
	    get_service_info
	    ;;


	    --all|--uptime)
	    error "The '$1' feature will be implemented in  a later stage."
	    return 0
	    ;;

	    *)
	     error "Unknown option: $1"
	     printf 'Use --help for usage information.\n' >&2
	     return 2
	     ;;

       	 esac
}

load_config

log_message "INFO" "System monitor started"


main "$@"
