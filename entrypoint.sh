#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--as-user" ]; then
  shift
  if [ -n "${DC_PROJECT_DIR:-}" ] && [ -f "$DC_PROJECT_DIR/package.json" ] &&
     [ -z "$(ls -A "$DC_PROJECT_DIR/node_modules" 2>/dev/null)" ]; then
    b=$'\033[1m'; dim=$'\033[2m'; rst=$'\033[0m'
    yel=$'\033[38;2;229;192;123m'; cya=$'\033[38;2;97;175;239m'
    do_install=""
    if [ -t 0 ]; then
      printf '\n  %s%s⬢  node_modules is empty%s\n\n' "$b" "$yel" "$rst"
      printf '  %sProject%s  %s\n' "$dim" "$rst" "${DC_PROJECT_LABEL:-}"
      printf '  The container keeps a %snode_modules%s separate from the Mac one.\n\n' "$cya" "$rst"
      printf '  Run %spnpm install%s now? %s[Y/n]%s ' "$cya" "$rst" "$dim" "$rst"
      read -r ans
      case "$ans" in
        [nN]*) printf '\n  %sskipped%s\n\n' "$dim" "$rst" ;;
        *) do_install=1 ;;
      esac
    else
      printf '%s>> node_modules is empty: run pnpm install%s\n' "$yel" "$rst"
    fi
    if [ -n "$do_install" ]; then
      printf '\n'
      ( cd "$DC_PROJECT_DIR" && pnpm install ) || echo ">> pnpm install failed, continuing"
      printf '\n'
    fi
  fi
  exec "$DC_AGENT" "$@"
fi

trap 'echo "firewall setup failed: the session did not start" >&2' ERR

printf '%s\n' "${DC_CHOWN_DIRS:-}" | while IFS= read -r d; do
  if [ -n "$d" ]; then
    mkdir -p "$d"
    chown vscode:vscode "$d"
  fi
done

v6() {
  ip6tables "$@" 2>/dev/null || true
}

block_port() {
  iptables -A OUTPUT -p tcp --dport "$1" -j REJECT --reject-with tcp-reset
  v6 -A OUTPUT -p tcp --dport "$1" -j REJECT --reject-with tcp-reset
}

block_host() {
  iptables -A OUTPUT -p tcp -m string --string "$1" --algo bm -j REJECT --reject-with tcp-reset
  v6 -A OUTPUT -p tcp -m string --string "$1" --algo bm -j REJECT --reject-with tcp-reset
}

block_addr() {
  local target="$1" ips ip
  if [[ "$target" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]] || [[ "$target" == *:* ]]; then
    ips="$target"
  else
    ips="$(getent ahosts "$target" | awk '{print $1}' | sort -u || true)"
  fi
  if [ -z "$ips" ]; then
    return 0
  fi
  for ip in $ips; do
    if [[ "$ip" == *:* ]]; then
      v6 -A OUTPUT -d "$ip" -j REJECT
    else
      iptables -A OUTPUT -d "$ip" -j REJECT
    fi
  done
}

host_rules=0
while IFS=' ' read -r kind value; do
  [ -n "${kind:-}" ] || continue
  case "$kind" in
    port) block_port "$value" ;;
    host) block_host "$value"; host_rules=1 ;;
    addr) block_addr "$value" ;;
    *) echo "firewall: unknown rule kind $kind" >&2; exit 1 ;;
  esac
done <<< "${DC_FIREWALL:-}"

if [ "$host_rules" = "1" ]; then
  iptables -A OUTPUT -p udp --dport 443 -j REJECT
  v6 -A OUTPUT -p udp --dport 443 -j REJECT
  block_host cloudflare-ech.com
fi

trap - ERR

exec setpriv --reuid=vscode --regid=vscode --init-groups \
  --no-new-privs --bounding-set=-net_admin,-net_raw --inh-caps=-all \
  env HOME=/home/vscode USER=vscode LOGNAME=vscode \
  bash -l "$0" --as-user "$@"
