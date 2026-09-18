cc() {
  "$HOME/.devcontainer/run.sh" claude "$@"
}

cr() {
  local -a args
  args=(rc)
  [[ "$*" == *--spawn* ]] || args+=(--spawn=same-dir)
  "$HOME/.devcontainer/run.sh" claude "${args[@]}" "$@"
}

cdx() {
  "$HOME/.devcontainer/run.sh" codex "$@"
}

cdxr() {
  "$HOME/.devcontainer/run.sh" codex remote-control start "$@"
}
