#!/usr/bin/env bash
set -euo pipefail

agent="${1:-claude}"
shift || true
case "$agent" in
  claude | codex) ;;
  *) echo "unknown agent: $agent (use claude or codex)" >&2; exit 1 ;;
esac

image="devcontainer:latest"
image_config="$HOME/.devcontainer"
ports="3000 4173 5173 8000 8080"
root_name="Developer"

term_args=(
  -e TERM="${TERM:-xterm-256color}"
  -e COLORTERM="${COLORTERM:-truecolor}"
)

find_root() {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    if [ "$(basename "$d")" = "$root_name" ]; then
      printf '%s' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

if ! workspace="$(find_root)"; then
  b=$'\033[1m'; d=$'\033[2m'; r=$'\033[0m'
  y=$'\033[38;2;229;192;123m'; c=$'\033[38;2;97;175;239m'
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

workspace_target="/workspaces/$(basename "$workspace")"
rel="${PWD#"$workspace"}"
rel="${rel#/}"
workdir="$workspace_target"
if [ -n "$rel" ]; then
  workdir="$workspace_target/$rel"
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
  -v "$workspace:$workspace_target"
  -v "$HOME/.claude:/home/vscode/.claude"
  -v devcontainer-npm:/home/vscode/.npm
  -v devcontainer-cache:/home/vscode/.cache
  -v devcontainer-pnpm-store:"$workspace_target/.pnpm-store"
)

chown_dirs=("$workspace_target/.pnpm-store")

project_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
project_rel=""
if [ -n "$project_root" ] && [ "${project_root#"$workspace"}" != "$project_root" ]; then
  project_rel="${project_root#"$workspace"}"
  project_rel="${project_rel#/}"
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue
    pkg_dir="$(dirname "$pj")"
    nm_rel="${pkg_dir#"$workspace"}"
    nm_rel="${nm_rel#/}"
    nm_target="$workspace_target/$nm_rel/node_modules"
    nm_name="devcontainer-nm-$(printf '%s' "$workspace|$nm_rel" | shasum -a 256 | cut -c1-16)"
    mount_args+=(-v "$nm_name:$nm_target")
    chown_dirs+=("$nm_target")
  done < <(find "$project_root" -maxdepth 3 -name package.json -not -path "*/node_modules/*" 2>/dev/null)
fi

if [ -S /var/run/docker.sock ]; then
  mount_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi
if [ -d "$HOME/.codex" ]; then
  mount_args+=(-v "$HOME/.codex:/home/vscode/.codex")
fi
if [ -f "$HOME/.gitconfig" ]; then
  mount_args+=(-v "$HOME/.gitconfig:/home/vscode/.gitconfig:ro")
fi

run_opts=(--rm -i)
if [ -t 0 ]; then
  run_opts+=(-t)
fi

exec docker run "${run_opts[@]}" \
  --name "$agent-$(basename "${PWD}")-$$" \
  -u vscode \
  -w "$workdir" \
  -e CLAUDE_CONFIG_DIR=/home/vscode/.claude \
  -e GIT_ALLOW_PROTOCOL=file \
  -e DC_CHOWN_DIRS="$(printf '%s\n' ${chown_dirs[@]+"${chown_dirs[@]}"})" \
  -e DC_PROJECT_DIR="${project_root:+$workspace_target/$project_rel}" \
  -e DC_AGENT="$agent" \
  "${term_args[@]}" \
  "${mount_args[@]}" \
  ${port_args[@]+"${port_args[@]}"} \
  "$image" \
  bash -lc '
    sudo chown root:docker /var/run/docker.sock 2>/dev/null || true
    printf "%s\n" "$DC_CHOWN_DIRS" | while IFS= read -r d; do
      [ -n "$d" ] && sudo mkdir -p "$d" && sudo chown "$(id -u):$(id -g)" "$d" 2>/dev/null
    done
    if [ -n "$DC_PROJECT_DIR" ] && [ -f "$DC_PROJECT_DIR/package.json" ] &&
       [ -z "$(ls -A "$DC_PROJECT_DIR/node_modules" 2>/dev/null)" ]; then
      do_install=""
      if [ -t 0 ]; then
        b=$(printf "\033[1m"); dim=$(printf "\033[2m"); rst=$(printf "\033[0m")
        yel=$(printf "\033[38;2;229;192;123m"); cya=$(printf "\033[38;2;97;175;239m")
        printf "\n  %s%s⬢  node_modules is empty%s\n\n" "$b" "$yel" "$rst"
        printf "  %sProject%s  %s\n" "$dim" "$rst" "${DC_PROJECT_DIR#/workspaces/}"
        printf "  The container keeps a %snode_modules%s separate from the Mac one.\n\n" "$cya" "$rst"
        printf "  Run %spnpm install%s now? %s[Y/n]%s " "$cya" "$rst" "$dim" "$rst"
        read -r ans
        case "$ans" in
          [nN]*) printf "\n  %sskipped%s\n\n" "$dim" "$rst" ;;
          *) do_install=1 ;;
        esac
      else
        printf "\033[38;2;229;192;123m>> node_modules is empty: run pnpm install\033[0m\n"
      fi
      if [ -n "$do_install" ]; then
        printf "\n"
        ( cd "$DC_PROJECT_DIR" && pnpm install ) || echo ">> pnpm install failed, continuing"
        printf "\n"
      fi
    fi
    exec "$DC_AGENT" "$@"
  ' _ "$@"
