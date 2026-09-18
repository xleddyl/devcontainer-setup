#!/usr/bin/env bash
set -euo pipefail

isolated=0
allow_list=""
while [ $# -gt 0 ]; do
  case "$1" in
    --isolated) isolated=1; shift ;;
    --allow)
      [ $# -ge 2 ] || { echo "--allow needs a rule name" >&2; exit 1; }
      allow_list="$allow_list $2"; shift 2 ;;
    *) break ;;
  esac
done

agent="${1:-claude}"
shift || true
case "$agent" in
  claude | codex) agent_bin="$agent" ;;
  shell) agent_bin="bash" ;;
  *) echo "unknown agent: $agent (use claude or codex)" >&2; exit 1 ;;
esac

image="devcontainer:latest"
image_config="$HOME/.devcontainer"
ports="3000 4173 5173 8000 8080"
root_name="Developer"
rules_file_name=".dc-firewall"

b=$'\033[1m'; d=$'\033[2m'; r=$'\033[0m'
y=$'\033[38;2;229;192;123m'; c=$'\033[38;2;97;175;239m'; g=$'\033[38;2;152;195;121m'

term_args=(
  -e TERM="${TERM:-xterm-256color}"
  -e COLORTERM="${COLORTERM:-truecolor}"
)

find_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ "$(basename "$dir")" = "$root_name" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [ "$isolated" = "1" ]; then
  workspace="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
elif ! workspace="$(find_root)"; then
  printf '\n  %s%s⬢  Not in %s%s\n\n' "$b" "$y" "$root_name" "$r"
  printf '  The dev container mounts the %s%s%s folder.\n' "$c" "$root_name" "$r"
  printf '  This folder is not inside any %s%s%s folder.\n\n' "$c" "$root_name" "$r"
  printf '  %sCurrent folder%s\n    %s%s%s\n\n' "$d" "$r" "$d" "$PWD" "$r"
  printf '  %sWhat you can do%s\n' "$d" "$r"
  printf '    %s%-20s%s go to a project\n' "$c" "cd ~/$root_name/..." "$r"
  printf '    %s%-20s%s run %s on the Mac\n\n' "$c" "$agent" "$r" "$agent"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running: start Docker Desktop" >&2
  exit 1
fi

rule_files=()
if [ -f "$image_config/firewall.rules" ]; then
  rule_files+=("$image_config/firewall.rules")
fi
project_rule_files=()
if [ "$isolated" = "1" ]; then
  if [ -f "$workspace/$rules_file_name" ]; then
    project_rule_files+=("$workspace/$rules_file_name")
  fi
else
  while IFS= read -r f; do
    [ -n "$f" ] && project_rule_files+=("$f")
  done < <(find "$workspace" -maxdepth 4 \( -name node_modules -o -name .git \) -prune -o -name "$rules_file_name" -type f -print 2>/dev/null)
fi
rule_files+=(${project_rule_files[@]+"${project_rule_files[@]}"})

rule_names=""
rule_lines=""
for file in ${rule_files[@]+"${rule_files[@]}"}; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$line" in "" | "#"*) continue ;; esac
    read -r name kind value extra <<< "$line"
    ok=1
    [ -n "${name:-}" ] && [ -n "${value:-}" ] && [ -z "${extra:-}" ] || ok=0
    case "${kind:-}" in
      port) [[ "$value" =~ ^[0-9]+$ ]] || ok=0 ;;
      host) [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || ok=0 ;;
      addr) [[ "$value" =~ ^[A-Za-z0-9.:/-]+$ ]] || ok=0 ;;
      *) ok=0 ;;
    esac
    if [ "$ok" = "0" ]; then
      echo "invalid firewall rule at $file:$n: $line" >&2
      echo "expected: <name> <port|host|addr> <value>" >&2
      exit 1
    fi
    case " $rule_names " in *" $name "*) ;; *) rule_names="$rule_names $name" ;; esac
    rule_lines="$rule_lines$name $kind $value"$'\n'
  done < "$file"
done

is_allowed() {
  case " $allow_list " in *" $1 "* | *" all "*) return 0 ;; esac
  return 1
}

for a in $allow_list; do
  [ "$a" = "all" ] && continue
  case " $rule_names " in
    *" $a "*) ;;
    *) printf '%s>> no firewall rule named %s%s\n' "$y" "$a" "$r" >&2 ;;
  esac
done

firewall=""
if [ -n "$rule_names" ]; then
  printf '\n  %s%s⬢  firewall%s\n\n' "$b" "$y" "$r"
  for name in $rule_names; do
    targets="$(printf '%s' "$rule_lines" | awk -v n="$name" '$1 == n { if ($2 == "port") v = "port " $3; else v = $3; out = out (out ? ", " : "") v } END { print out }')"
    if is_allowed "$name"; then
      printf '    %s%-8s%s %s%-9s%s %sthis session%s\n' "$c" "$name" "$r" "$g" "allowed" "$r" "$d" "$r"
    else
      printf '    %s%-8s%s %s%-9s%s %s%s%s\n' "$c" "$name" "$r" "$y" "blocked" "$r" "$d" "$targets" "$r"
      firewall="$firewall$(printf '%s' "$rule_lines" | awk -v n="$name" '$1 == n { print $2 " " $3 }')"$'\n'
    fi
  done
  printf '\n'
fi

template_file="$image_config/devcontainer.json"
config_file="$image_config/.resolved.json"
hash_file="$image_config/.build-hash"

host_version() {
  command "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

claude_version="$(host_version claude)"
codex_version="$(host_version codex)"
if [ -z "$claude_version" ] || [ -z "$codex_version" ]; then
  echo "cannot read the claude or codex version on the Mac" >&2
  exit 1
fi

sed -e "s/__CLAUDE_VERSION__/$claude_version/" \
    -e "s/__CODEX_VERSION__/$codex_version/" \
    "$template_file" > "$config_file"

config_hash="$(shasum -a 256 "$config_file" | cut -d" " -f1)"

needs_build=0
if ! docker image inspect "$image" >/dev/null 2>&1; then
  needs_build=1
  echo ">> image $image is missing"
elif [ ! -f "$hash_file" ] || [ "$(cat "$hash_file")" != "$config_hash" ]; then
  needs_build=1
  echo ">> configuration or versions changed: claude $claude_version, codex $codex_version"
fi

if [ "$needs_build" = "1" ]; then
  echo ">> building image $image"
  devcontainer build --workspace-folder "$image_config" --config "$config_file" --image-name "$image"
  printf '%s' "$config_hash" > "$hash_file"
fi

host_config="$HOME/.claude.json"
container_config="$HOME/.claude/.claude.json"
if [ -f "$host_config" ] && ! grep -q '"oauthAccount"' "$container_config" 2>/dev/null; then
  cp "$host_config" "$container_config"
  echo ">> copied ~/.claude.json settings into the container"
fi

busy="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $9}' | sed 's/.*://' | sort -u)"
port_args=()
for p in $ports; do
  if ! printf '%s\n' "$busy" | grep -qx "$p"; then
    port_args+=(-p "127.0.0.1:$p:$p")
  fi
done

mount_args=(
  -v "$workspace:$workspace"
  -v "$image_config/entrypoint.sh:/opt/dc/entrypoint.sh:ro"
  -v "$HOME/.claude:/home/vscode/.claude"
  -v devcontainer-npm:/home/vscode/.npm
  -v devcontainer-cache:/home/vscode/.cache
  -v devcontainer-pnpm-store:"$workspace/.pnpm-store"
)

for f in ${project_rule_files[@]+"${project_rule_files[@]}"}; do
  mount_args+=(-v "$f:$f:ro")
done

chown_dirs=("$workspace/.pnpm-store")

project_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$project_root" ] && [ "${project_root#"$workspace"}" != "$project_root" ]; then
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue
    pkg_dir="$(dirname "$pj")"
    nm_target="$pkg_dir/node_modules"
    nm_name="devcontainer-nm-$(printf '%s' "$pkg_dir" | shasum -a 256 | cut -c1-16)"
    mount_args+=(-v "$nm_name:$nm_target")
    chown_dirs+=("$nm_target")
  done < <(find "$project_root" -maxdepth 3 -name package.json -not -path "*/node_modules/*" 2>/dev/null)
fi

if [ -d "$HOME/.codex" ]; then
  mount_args+=(-v "$HOME/.codex:/home/vscode/.codex")
fi

readonly_claude=(settings.json settings.local.json statusline-command.sh fetch-usage.sh plugins skills output-styles)
for item in ${readonly_claude[@]+"${readonly_claude[@]}"}; do
  if [ -e "$HOME/.claude/$item" ]; then
    mount_args+=(-v "$HOME/.claude/$item:/home/vscode/.claude/$item:ro")
  fi
done

readonly_codex=(config.toml plugins skills)
for item in ${readonly_codex[@]+"${readonly_codex[@]}"}; do
  if [ -e "$HOME/.codex/$item" ]; then
    mount_args+=(-v "$HOME/.codex/$item:/home/vscode/.codex/$item:ro")
  fi
done

if [ -f "$HOME/.gitconfig" ]; then
  mount_args+=(-v "$HOME/.gitconfig:/home/vscode/.gitconfig:ro")
fi

run_opts=(--rm -i)
if [ -t 0 ]; then
  run_opts+=(-t)
fi

exec docker run "${run_opts[@]}" \
  --name "$agent-$(basename "$PWD")-$$" \
  --label "devcontainer.isolated=$isolated" \
  -u root \
  --cap-add NET_ADMIN \
  -w "$PWD" \
  -e CLAUDE_CONFIG_DIR=/home/vscode/.claude \
  -e DC_AGENT="$agent_bin" \
  -e DC_FIREWALL="$firewall" \
  -e DC_CHOWN_DIRS="$(printf '%s\n' ${chown_dirs[@]+"${chown_dirs[@]}"})" \
  -e DC_PROJECT_DIR="${project_root:-}" \
  -e DC_PROJECT_LABEL="${project_root#"$HOME"/}" \
  "${term_args[@]}" \
  "${mount_args[@]}" \
  ${port_args[@]+"${port_args[@]}"} \
  "$image" \
  /opt/dc/entrypoint.sh "$@"
