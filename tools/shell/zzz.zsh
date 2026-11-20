# zzz.notch long-command notifier for zsh. Source from ~/.zshrc:
#   source /path/to/zzz.notch/tools/shell/zzz.zsh
#
# After any command that ran at least ZZZ_LONG_CMD_SECONDS (default 20), push
# its result to the notch: green on exit 0, red otherwise. Interactive
# programs listed in ZZZ_LONG_CMD_IGNORE are skipped. Clicking the event
# activates this terminal.

zmodload zsh/datetime
autoload -Uz add-zsh-hook

typeset -g ZZZ_BIN=${ZZZ_BIN:-${${(%):-%x}:A:h:h}/zzz}
typeset -g ZZZ_LONG_CMD_SECONDS=${ZZZ_LONG_CMD_SECONDS:-20}
typeset -g ZZZ_LONG_CMD_IGNORE=${ZZZ_LONG_CMD_IGNORE:-"vim nvim vi nano less more man top htop btop ssh mosh tmux zellij claude omp codex lazygit fzf watch"}
typeset -g _zzz_cmd= _zzz_start=

_zzz_preexec() {
  _zzz_cmd=$1
  _zzz_start=$EPOCHREALTIME
}

_zzz_precmd() {
  local code=$?
  [[ -n $_zzz_start ]] || return 0
  local -i elapsed=$(( EPOCHREALTIME - _zzz_start ))
  local cmd=$_zzz_cmd
  _zzz_start=

  (( elapsed >= ZZZ_LONG_CMD_SECONDS )) || return 0
  local first=${${(z)cmd}[1]}
  local -a ignore=(${(z)ZZZ_LONG_CMD_IGNORE})
  (( ${ignore[(Ie)${first:t}]} )) && return 0

  local took
  if (( elapsed >= 3600 )); then took="$(( elapsed / 3600 ))h$(( elapsed % 3600 / 60 ))m"
  elif (( elapsed >= 60 )); then took="$(( elapsed / 60 ))m$(( elapsed % 60 ))s"
  else took="${elapsed}s"; fi

  local state=ok
  (( code == 0 )) || state=fail
  "$ZZZ_BIN" notify "${cmd[1,60]}" "exit $code · $took" \
    --source "${PWD:t}" --status $state --symbol terminal \
    --app "${__CFBundleIdentifier:-}" --id "cmd-$$" >/dev/null 2>&1 &!
}

add-zsh-hook preexec _zzz_preexec
add-zsh-hook precmd _zzz_precmd
