#!/bin/bash
# Monitor VSP LDEVs for FMT (Format) operations and track overall progress
# Usage: ./monitor_fmt.sh [-i instance] [-c count] [-s start_ldev] [-p pause_seconds]

INSTANCE="H598"
COUNT=107
START=57344
PAUSE=60

while getopts "i:c:s:p:" opt; do
  case $opt in
    i) INSTANCE="$OPTARG" ;;
    c) COUNT="$OPTARG" ;;
    s) START="$OPTARG" ;;
    p) PAUSE="$OPTARG" ;;
    *) echo "Usage: $0 [-i instance] [-c count] [-s start_ldev] [-p pause_seconds]"; exit 1 ;;
  esac
done

# Colors
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
RESET='\033[0m'

TOTAL_TRACKED=0
TRACKING_FILE="/tmp/monitor_fmt_tracked_$$"
PREV_PCT_FILE="/tmp/monitor_fmt_prev_$$"
trap "rm -f $TRACKING_FILE $PREV_PCT_FILE" EXIT

draw_header() {
  echo -e "${CYAN}+$(printf '=%.0s' $(seq 1 62))+"
  echo -e "| ${WHITE} VSP LDEV Format Monitor (${INSTANCE})$(printf ' %.0s' $(seq 1 $((33 - ${#INSTANCE}))))${CYAN}|"
  echo -e "+$(printf '=%.0s' $(seq 1 62))+${RESET}"
  echo ""
}

# Convert seconds to human-readable "Xh Ym Zs"
fmt_duration() {
  local secs=$1
  if [ "$secs" -le 0 ]; then echo "—"; return; fi
  local h=$((secs / 3600))
  local m=$(( (secs % 3600) / 60 ))
  local s=$((secs % 60))
  if [ "$h" -gt 0 ]; then
    printf "%dh %02dm" "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf "%dm %02ds" "$m" "$s"
  else
    printf "%ds" "$s"
  fi
}

clear
draw_header

echo -e "${GRAY}Scanning LDEV range ${START} to $((START + COUNT - 1))...${RESET}"
echo -e "${GRAY}Identifying LDEVs with FMT operations...${RESET}"
echo ""

# ── Initial discovery scan ──────────────────────────────────────────
raidcom get ldev -ldev_id $START -cnt $COUNT -I$INSTANCE 2>/dev/null | \
awk '
  /^LDEV :/     { ldev = $NF }
  /^OPE_TYPE :/ { ope = $NF }
  /^LDEV_NAMING :/ {
    name = $0; sub(/^LDEV_NAMING : /, "", name)
    if (ope == "FMT") print ldev, name
  }
' > "$TRACKING_FILE"

TOTAL_TRACKED=$(wc -l < "$TRACKING_FILE")

if [ "$TOTAL_TRACKED" -eq 0 ]; then
  echo -e "${GREEN}No LDEVs with active FMT operations found.${RESET}"
  rm -f "$TRACKING_FILE"
  exit 0
fi

# Initialize empty previous-percentage file
> "$PREV_PCT_FILE"

echo -e "${WHITE}Tracking ${YELLOW}${TOTAL_TRACKED}${WHITE} LDEVs with FMT operations${RESET}"
echo -e "${GRAY}Refresh: Every ${PAUSE}s  |  Press Ctrl+C to stop${RESET}"
echo ""

SCAN_NUM=0

# ── Monitoring loop ─────────────────────────────────────────────────
while true; do
  SCAN_NUM=$((SCAN_NUM + 1))
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  NOW_EPOCH=$(date '+%s')

  fmt_count=0
  done_count=0
  max_eta=0
  idx=0

  # Temp file for this scan's percentages (becomes prev for next scan)
  NEW_PCT_FILE="/tmp/monitor_fmt_newpct_$$"
  > "$NEW_PCT_FILE"

  # ── Redraw header before scanning ──
  clear
  draw_header
  echo -e "${CYAN}* SCANNING   [$(date '+%H:%M:%S')]${RESET}  Querying ${TOTAL_TRACKED} LDEVs..."
  # Progress bar line (will be overwritten)
  echo -e "  Progress: ${YELLOW}[$(printf ' %.0s' $(seq 1 50))]${RESET} ${WHITE}  0%${RESET} (0/${TOTAL_TRACKED} completed)"
  # ETA line (will be overwritten)
  echo -e "  ${GRAY}ETA: calculating...${RESET}"
  # Ticker line placeholder
  echo -ne "  "

  while read -r ldev_id ldev_name; do
    idx=$((idx + 1))

    info=$(raidcom get ldev -ldev_id "$ldev_id" -I$INSTANCE 2>/dev/null | \
      awk '
        /^OPE_TYPE :/ { ope = $NF }
        /^OPE_RATE :/ { rate = $NF }
        END { print ope, rate }
      ')
    ope=$(echo "$info" | awk '{print $1}')
    rate=$(echo "$info" | awk '{print $2}')

    ldev_eta=0

    if [ "$ope" = "FMT" ]; then
      pct=${rate%%%}   # strip trailing %
      pct=${pct:-0}
      fmt_count=$((fmt_count + 1))
      status="FMT ${pct}%"
      scolor="$YELLOW"

      # Save current pct for next scan comparison
      echo "${ldev_id} ${pct}" >> "$NEW_PCT_FILE"

      # Calculate per-LDEV ETA using delta from previous scan
      if [ "$SCAN_NUM" -gt 1 ]; then
        prev_pct=$(awk -v id="$ldev_id" '$1 == id { print $2 }' "$PREV_PCT_FILE")
        prev_pct=${prev_pct:-$pct}
        delta=$((pct - prev_pct))
        if [ "$delta" -gt 0 ]; then
          remaining=$((100 - pct))
          ldev_eta=$(( remaining * PAUSE / delta ))
        elif [ "$pct" -lt 100 ]; then
          ldev_eta=999999   # no progress this interval, unknown
        fi
      fi

      # Track max ETA (ignore unknowns for display unless all are unknown)
      if [ "$ldev_eta" -gt 0 ] && [ "$ldev_eta" -lt 999999 ] && [ "$ldev_eta" -gt "$max_eta" ]; then
        max_eta=$ldev_eta
      fi
    else
      done_count=$((done_count + 1))
      status="DONE"
      scolor="$GREEN"
    fi

    # Overall % = completed LDEVs / total
    overall_pct=$((done_count * 100 / TOTAL_TRACKED))

    # Build progress bar
    bar_filled=$((overall_pct * 50 / 100))
    bar_empty=$((50 - bar_filled))
    bar=""
    for ((j=0; j<bar_filled; j++)); do bar+="#"; done
    for ((j=0; j<bar_empty; j++)); do bar+=" "; done
    if [ "$overall_pct" -ge 50 ]; then bcolor="$GREEN"; else bcolor="$YELLOW"; fi

    # ETA display string
    if [ "$SCAN_NUM" -le 1 ]; then
      eta_str="calculating (need 2 scans)..."
    elif [ "$max_eta" -gt 0 ]; then
      eta_ts=$(date -d "@$((NOW_EPOCH + max_eta))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
               date -r $((NOW_EPOCH + max_eta)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
      eta_str="~$(fmt_duration $max_eta) remaining  →  ${eta_ts}"
    else
      eta_str="calculating..."
    fi

    # Move cursor up 3 lines, redraw progress + ETA + ticker
    echo -ne "\033[3A"
    printf "\r  Progress: ${bcolor}[${bar}]${RESET} ${WHITE}%3d%%${RESET} (${done_count}/${TOTAL_TRACKED} completed)                    \n" "$overall_pct"
    printf "\r  ${WHITE}ETA: ${CYAN}%-60s${RESET}\n" "$eta_str"
    printf "\r  ${GRAY}[%3d/%d]${RESET} LDEV ${WHITE}%-6s${RESET} ${GRAY}%-28s${RESET} ${scolor}%-10s${RESET}         " "$idx" "$TOTAL_TRACKED" "$ldev_id" "$ldev_name" "$status"
    echo -ne "\n"

  done < "$TRACKING_FILE"

  # Final overall percentage
  overall_pct=$((done_count * 100 / TOTAL_TRACKED))

  # Final progress bar
  bar_filled=$((overall_pct * 50 / 100))
  bar_empty=$((50 - bar_filled))
  bar=""
  for ((j=0; j<bar_filled; j++)); do bar+="#"; done
  for ((j=0; j<bar_empty; j++)); do bar+=" "; done
  if [ "$overall_pct" -eq 100 ]; then bcolor="$GREEN"; elif [ "$overall_pct" -ge 50 ]; then bcolor="$GREEN"; else bcolor="$YELLOW"; fi

  # Final ETA string
  if [ "$SCAN_NUM" -le 1 ]; then
    eta_str="calculating (need 2 scans)..."
  elif [ "$max_eta" -gt 0 ]; then
    eta_ts=$(date -d "@$((NOW_EPOCH + max_eta))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
             date -r $((NOW_EPOCH + max_eta)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    eta_str="~$(fmt_duration $max_eta) remaining  →  ${eta_ts}"
  elif [ "$done_count" -eq "$TOTAL_TRACKED" ]; then
    eta_str="Complete!"
  else
    eta_str="no change detected, waiting for next interval..."
  fi

  # Final redraw
  echo -ne "\033[3A"
  printf "\r  Progress: ${bcolor}[${bar}]${RESET} ${WHITE}%3d%%${RESET} (${done_count}/${TOTAL_TRACKED} completed)                    \n" "$overall_pct"
  printf "\r  ${WHITE}ETA: ${CYAN}%-60s${RESET}\n" "$eta_str"

  if [ "$done_count" -eq "$TOTAL_TRACKED" ]; then
    printf "\r  ${GREEN}*** All ${TOTAL_TRACKED} LDEVs have completed formatting! ***${RESET}          \n"
    echo ""
    exit 0
  fi

  printf "\r  ${GRAY}Scan #${SCAN_NUM} complete at ${TIMESTAMP}  |  ${YELLOW}${fmt_count} formatting${GRAY}  |  Next in ${PAUSE}s${RESET}          \n"
  echo ""

  # Rotate: current percentages become previous for next scan
  mv "$NEW_PCT_FILE" "$PREV_PCT_FILE"

  sleep $PAUSE
done
