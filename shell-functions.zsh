_dc_run() {
  local session_suffix="$1"
  shift

  local use_tmux=0
  local -a dc_args
  dc_args=()
  local a
  for a in "$@"; do
    case "$a" in
      -t) use_tmux=1 ;;
      *) dc_args+=("$a") ;;
    esac
  done

  local runner="$HOME/.devcontainer/run.sh"

  if [ "$use_tmux" = "0" ]; then
    "$runner" "${dc_args[@]}"
    return
  fi

  local session
  session="$(basename "$PWD" | tr '.:' '__')"
  if [ -n "$session_suffix" ]; then
    session="$session-$session_suffix"
  fi

  if tmux has-session -t "=$session" 2>/dev/null; then
    if [ -n "$TMUX" ]; then
      tmux switch-client -t "=$session"
    else
      tmux attach-session -t "=$session"
    fi
    return
  fi

  local cmd="${(q)runner} ${(q)dc_args}"
  if [ -n "$TMUX" ]; then
    tmux new-session -d -s "$session" -c "$PWD" "$cmd"
    tmux switch-client -t "=$session"
  else
    tmux new-session -s "$session" -c "$PWD" "$cmd"
  fi
}

cc() {
  _dc_run "" claude "$@"
}

cr() {
  local -a args
  args=(rc)
  [[ "$*" == *--spawn* ]] || args+=(--spawn=same-dir)
  _dc_run "rc" claude "${args[@]}" "$@"
}

cdx() {
  _dc_run "cdx" codex "$@"
}

cdxr() {
  _dc_run "cdxr" codex remote-control start "$@"
}
