_dc_usage() {
  local b=$'\033[1m' d=$'\033[2m' r=$'\033[0m'
  local y=$'\033[38;2;229;192;123m' c=$'\033[38;2;97;175;239m'
  printf '\n  %s%s⬢  dev container%s\n\n' "$b" "$y" "$r"
  printf '  %s%s%s\n\n' "$b" "dc [-t|--tmux] [-r|--remote] [-i|--isolated] <agent> [args...]" "$r"
  printf '  %sagents%s\n' "$d" "$r"
  printf '    %s%-18s%s Claude Code\n' "$c" "claude" "$r"
  printf '    %s%-18s%s Codex\n\n' "$c" "codex" "$r"
  printf '  %sflags%s\n' "$d" "$r"
  printf '    %s%-18s%s run inside a tmux session\n' "$c" "-t, --tmux" "$r"
  printf '    %s%-18s%s remote control mode\n' "$c" "-r, --remote" "$r"
  printf '    %s%-18s%s mount only the current project\n\n' "$c" "-i, --isolated" "$r"
  printf '  %sexamples%s\n' "$d" "$r"
  printf '    %s%-18s%s Claude Code in the dev container\n' "$c" "dc claude" "$r"
  printf '    %s%-18s%s Codex inside tmux\n' "$c" "dc -t codex" "$r"
  printf '    %s%-18s%s Claude Code remote control in tmux\n' "$c" "dc -t -r claude" "$r"
  printf '    %s%-18s%s only this project is visible\n\n' "$c" "dc -i claude" "$r"
  printf '  %sFlags go before the agent name. Everything after it goes to the agent.%s\n\n' "$d" "$r"
}

_dc_tmux() {
  local session="$1"
  shift
  if tmux has-session -t "=$session" 2>/dev/null; then
    if [ -n "$TMUX" ]; then
      tmux switch-client -t "=$session"
    else
      tmux attach-session -t "=$session"
    fi
    return
  fi

  local cmd="${(q)@}"
  if [ -n "$TMUX" ]; then
    tmux new-session -d -s "$session" -c "$PWD" "$cmd"
    tmux switch-client -t "=$session"
  else
    tmux new-session -s "$session" -c "$PWD" "$cmd"
  fi
}

dc() {
  local use_tmux=0
  local remote=0
  local isolated=0
  local agent=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -t | --tmux) use_tmux=1; shift ;;
      -r | --remote) remote=1; shift ;;
      -i | --isolated) isolated=1; shift ;;
      -tr | -rt) use_tmux=1; remote=1; shift ;;
      claude | codex) agent="$1"; shift; break ;;
      *) break ;;
    esac
  done

  if [ -z "$agent" ]; then
    _dc_usage
    return 1
  fi

  local -a agent_args
  agent_args=()
  local suffix=""

  if [ "$agent" = "claude" ]; then
    if [ "$remote" = "1" ]; then
      agent_args=(rc)
      [[ "$*" == *--spawn* ]] || agent_args+=(--spawn=same-dir)
      suffix="rc"
    fi
  else
    if [ "$remote" = "1" ]; then
      agent_args=(remote-control start)
      suffix="cdxr"
    else
      suffix="cdx"
    fi
  fi

  local runner="$HOME/.devcontainer/run.sh"
  local -a runner_args
  runner_args=()
  if [ "$isolated" = "1" ]; then
    runner_args=(--isolated)
    if [ -n "$suffix" ]; then
      suffix="iso-$suffix"
    else
      suffix="iso"
    fi
  fi

  if [ "$use_tmux" = "0" ]; then
    "$runner" "${runner_args[@]}" "$agent" "${agent_args[@]}" "$@"
    return
  fi

  local session
  session="$(basename "$PWD" | tr '.:' '__')"
  if [ -n "$suffix" ]; then
    session="$session-$suffix"
  fi

  _dc_tmux "$session" "$runner" "${runner_args[@]}" "$agent" "${agent_args[@]}" "$@"
}
