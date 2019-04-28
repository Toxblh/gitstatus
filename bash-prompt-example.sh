# This is an example of using gitstatus in bash prompt.
#
# Usage:
#
#   git clone https://github.com/romkatv/gitstatus.git ~/gitstatus
#   echo 'source ~/gitstatus/bash-prompt-example.sh' >> ~/.bashrc

[[ $- == *i* ]] || return  # non-interactive shell

# Starts gitstatusd in the background. Does nothing and succeeds if gitstatusd
# is already running.
#
# Usage: gitstatus_start [OPTION]...
#
#   -t FLOAT  Fail the self-check on initialization if not getting a response from
#             gitstatusd for this this many seconds. Defaults to 5.
#   -m INT    Report -1 unstaged and untracked if there are more than this many files
#             in the index. Negative value means infinity. Defaults to -1.
function gitstatus_start() {
  unset OPTIND
  local opt timeout=5 max_dirty=-1
  while getopts "t:m:" opt; do
    case "$opt" in
      t) timeout=$OPTARG;;
      m) max_dirty=$OPTARG;;
      *) return 1;;
    esac
  done

  (( OPTIND == $# + 1 )) || { echo "usage: gitstatus_start [OPTION]..." >&2; return 1; }

  [[ -z "${GITSTATUS_DAEMON_PID:-}" ]] || return 0  # already started

  local req_fifo resp_fifo

  function gitstatus_start_impl() {
    local daemon="${GITSTATUS_DAEMON:-}"
    if [[ -z "$daemon" ]]; then
      local os   &&   os=$(uname -s)                    || return
      local arch && arch=$(uname -m)                    || return
      local dir  &&  dir=$(dirname "${BASH_SOURCE[0]}") || return
      daemon="$dir/bin/gitstatusd-${os,,}-${arch,,}"
    fi

    local threads="${GITSTATUS_NUM_THREADS:-0}"
    if (( threads <= 0 )); then
      case "$(uname -s)" in
        FreeBSD) threads=$(sysctl -n hw.ncpu)         || return;;
        *)       threads=$(getconf _NPROCESSORS_ONLN) || return;;
      esac
      (( threads *=  2 ))
      (( threads >=  2 )) || threads=2
      (( threads <= 32 )) || threads=32
    fi

    req_fifo=$(mktemp -u "${TMPDIR:-/tmp}"/gitstatus.$$.pipe.req.XXXXXXXXXX)   || return
    resp_fifo=$(mktemp -u "${TMPDIR:-/tmp}"/gitstatus.$$.pipe.resp.XXXXXXXXXX) || return
    mkfifo "$req_fifo" "$resp_fifo"                                            || return
    exec {GITSTATUS_REQ_FD}<>"$req_fifo" {GITSTATUS_RESP_FD}<>"$resp_fifo"     || return
    command rm "$req_fifo" "$resp_fifo"                                        || return

    if [[ "${GITSTATUS_ENABLE_LOGGING:-0}" == 1 ]]; then
      GITSTATUS_DAEMON_LOG=$(mktemp "${TMPDIR:-/tmp}"/gitstatus.$$.log.XXXXXXXXXX) || return
    else
      GITSTATUS_DAEMON_LOG=/dev/null
    fi

    { <&$GITSTATUS_REQ_FD >&$GITSTATUS_RESP_FD 2>"$GITSTATUS_DAEMON_LOG" bash -c "
        trap 'kill %1 &>/dev/null' SIGINT SIGTERM EXIT
        ${daemon@Q}                             \
          --sigwinch-pid=$$                     \
          --num-threads=${threads@Q}            \
          --dirty-max-index-size=${max_dirty@Q} \
          0<&0 1>&1 2>&2 &
        wait
        echo -nE $'bye\x1f0\x1e'" & } 2>/dev/null
    disown
    GITSTATUS_DAEMON_PID=$!

    local reply
    echo -nE $'hello\x1f\x1e' >&$GITSTATUS_REQ_FD                     || return
    IFS='' read -rd $'\x1e' -u $GITSTATUS_RESP_FD -t "$timeout" reply || return
    [[ "$reply" == $'hello\x1f0' ]]                                   || return
  }

  if ! gitstatus_start_impl; then
    echo "gitstatus_start: failed to start gitstatusd" >&2
    [[ -z "${req_fifo:-}"  ]] || command rm -f "$req_fifo"
    [[ -z "${resp_fifo:-}" ]] || command rm -f "$resp_fifo"
    unset -f gitstatus_start_impl
    gitstatus_stop
    return 1
  fi

  unset -f gitstatus_start_impl

  if [[ "${GITSTATUS_STOP_ON_EXEC:-1}" == 1 ]]; then
    function _gitstatus_exec() {
      (( ! $# )) || gitstatus_stop
      local ret=0
      exec "$@" || ret=$?
      [[ -n "${GITSTATUS_DAEMON_PID:-}" ]] || gitstatus_start || true
      return $ret
    }
    alias exec=_gitstatus_exec

    function _gitstatus_builtin() {
      while [[ "${1:-}" == builtin ]]; do shift; done
      [[ "${1:-}" != exec ]] || set -- _gitstatus_exec "${@:2}"
      "$@"
    }
    alias builtin=_gitstatus_builtin

    _GITSTATUS_EXEC_HOOK=1
  else
    unset _GITSTATUS_EXEC_HOOK
  fi
}

# Stops gitstatusd if it's running.
function gitstatus_stop() {
  [[ -z "${GITSTATUS_REQ_FD:-}"     ]] || exec {GITSTATUS_REQ_FD}>&-               || true
  [[ -z "${GITSTATUS_RESP_FD:-}"    ]] || exec {GITSTATUS_RESP_FD}>&-              || true
  [[ -z "${GITSTATUS_DAEMON_PID:-}" ]] || kill "$GITSTATUS_DAEMON_PID" &>/dev/null || true
  [[ -z "${_GITSTATUS_EXEC_HOOK:-}" ]] || unalias exec builtin &>/dev/null         || true
  unset GITSTATUS_REQ_FD GITSTATUS_RESP_FD GITSTATUS_DAEMON_PID _GITSTATUS_EXEC_HOOK
  unset -f _gitstatus_exec _gitstatus_builtin
}

# Retrives status of a git repository from a directory under its working tree.
#
# Usage: gitstatus_query [OPTION]...
#
#   -d STR    Directory to query. Defaults to ${GIT_DIR:-$PWD}.
#   -t FLOAT  Timeout in seconds. Will block for at most this long. If no results
#             are available by then, will return error.
#
# On success sets VCS_STATUS_RESULT to one of the following values:
#
#   norepo-sync  The directory doesn't belong to a git repository.
#   ok-sync      The directory belongs to a git repository.
#
# If VCS_STATUS_RESULT is ok-sync, additional variables are set:
#
#   VCS_STATUS_WORKDIR         Git repository working directory. Not empty.
#   VCS_STATUS_COMMIT          Commit hash that HEAD is pointing to. Either 40 hex digits
#                              or empty if there is no HEAD (empty repository).
#   VCS_STATUS_LOCAL_BRANCH    Local branch name or empty if not on a branch.
#   VCS_STATUS_REMOTE_NAME     The remote name, e.g. "upstream" or "origin".
#   VCS_STATUS_REMOTE_BRANCH   Upstream branch name. Can be empty.
#   VCS_STATUS_REMOTE_URL      Remote URL. Can be empty.
#   VCS_STATUS_ACTION          Repository state, A.K.A. action. Can be empty.
#   VCS_STATUS_HAS_STAGED      1 if there are staged changes, 0 otherwise.
#   VCS_STATUS_HAS_UNSTAGED    1 if there are unstaged changes, 0 if there aren't, -1 if
#                              unknown.
#   VCS_STATUS_HAS_UNTRACKED   1 if there are untracked files, 0 if there aren't, -1 if
#                              unknown.
#   VCS_STATUS_COMMITS_AHEAD   Number of commits the current branch is ahead of upstream.
#                              Non-negative integer.
#   VCS_STATUS_COMMITS_BEHIND  Number of commits the current branch is behind upstream.
#                              Non-negative integer.
#   VCS_STATUS_STASHES         Number of stashes. Non-negative integer.
#   VCS_STATUS_TAG             The last tag (in lexicographical order) that points to the
#                              same commit as HEAD.
#
# The point of reporting -1 as unstaged and untracked is to allow the command to skip
# scanning files in large repos. See -m flag of gitstatus_start.
#
# gitstatus_query returns an error if gitstatus_start hasn't been called in the same
# shell or the call had failed.
function gitstatus_query() {
  unset OPTIND
  local opt dir="${GIT_DIR:-$PWD}" timeout=()
  while getopts "d:c:t:" opt "$@"; do
    case "$opt" in
      d) dir=$OPTARG;;
      t) timeout=(-t "$OPTARG");;
      *) return 1;;
    esac
  done
  (( OPTIND == $# + 1 )) || { echo "usage: gitstatus_query [OPTION]..." >&2; return 1; }

  [[ -n "$GITSTATUS_DAEMON_PID" ]] || return  # not started

  local req_id="$RANDOM.$RANDOM.$RANDOM.$RANDOM"
  [[ "$dir" == /* ]] || dir="$PWD/$dir"
  echo -nE "$req_id"$'\x1f'"$dir"$'\x1e' >&$GITSTATUS_REQ_FD || return

  local -a resp
  while true; do
    IFS=$'\x1f' read -rd $'\x1e' -a resp -u $GITSTATUS_RESP_FD "${timeout[@]}" || return
    [[ "${resp[0]}" == "$req_id" ]] && break
  done

  if [[ "${resp[1]}" == 1 ]]; then
    VCS_STATUS_RESULT=ok-sync
    VCS_STATUS_WORKDIR="${resp[2]}"
    VCS_STATUS_COMMIT="${resp[3]}"
    VCS_STATUS_LOCAL_BRANCH="${resp[4]}"
    VCS_STATUS_REMOTE_BRANCH="${resp[5]}"
    VCS_STATUS_REMOTE_NAME="${resp[6]}"
    VCS_STATUS_REMOTE_URL="${resp[7]}"
    VCS_STATUS_ACTION="${resp[8]}"
    VCS_STATUS_HAS_STAGED="${resp[9]}"
    VCS_STATUS_HAS_UNSTAGED="${resp[10]}"
    VCS_STATUS_HAS_UNTRACKED="${resp[11]}"
    VCS_STATUS_COMMITS_AHEAD="${resp[12]}"
    VCS_STATUS_COMMITS_BEHIND="${resp[13]}"
    VCS_STATUS_STASHES="${resp[14]}"
    VCS_STATUS_TAG="${resp[15]:-}"
  else
    VCS_STATUS_RESULT=norepo-sync
    unset VCS_STATUS_WORKDIR
    unset VCS_STATUS_COMMIT
    unset VCS_STATUS_LOCAL_BRANCH
    unset VCS_STATUS_REMOTE_BRANCH
    unset VCS_STATUS_REMOTE_NAME
    unset VCS_STATUS_REMOTE_URL
    unset VCS_STATUS_ACTION
    unset VCS_STATUS_HAS_STAGED
    unset VCS_STATUS_HAS_UNSTAGED
    unset VCS_STATUS_HAS_UNTRACKED
    unset VCS_STATUS_COMMITS_AHEAD
    unset VCS_STATUS_COMMITS_BEHIND
    unset VCS_STATUS_STASHES
    unset VCS_STATUS_TAG
  fi
}

# Sets GITSTATUS_PROMPT to reflect the state of the current git repository.
# The value is empty if not in a git repository. Forwards all arguments to
# gitstatus_query.
#
# Example value of GITSTATUS_PROMPT:
#
#   master+!? ⇡2 ⇣3 *4
#
# Meaning:
#
#   master   current branch
#   +        git repo has changes staged for commit
#   !        git repo has unstaged changes
#   ?        git repo has untracked files
#   ⇡2       local branch is ahead of origin by 2 commits
#   ⇣3       local branch is behind origin by 3 commits
#   *4       git repo has 4 stashes
function gitstatus_prompt_update() {
  GITSTATUS_PROMPT=""

  gitstatus_query "$@"                  || return 1  # error
  [[ "$VCS_STATUS_RESULT" == ok-sync ]] || return 0  # not a git repo

  local     reset=$'\e[0m'         # no color
  local     clean=$'\e[38;5;076m'  # green foreground
  local untracked=$'\e[38;5;014m'  # teal foreground
  local  modified=$'\e[38;5;011m'  # yellow foreground

  local p
  if (( VCS_STATUS_HAS_STAGED || VCS_STATUS_HAS_UNSTAGED )); then
    p+="$modified"
  elif (( VCS_STATUS_HAS_UNTRACKED )); then
    p+="$untracked"
  else
    p+="$clean"
  fi
  p+="${VCS_STATUS_LOCAL_BRANCH:-@${VCS_STATUS_COMMIT}}"

  [[ -n "$VCS_STATUS_TAG"               ]] && p+="#${VCS_STATUS_TAG}"
  [[ "$VCS_STATUS_HAS_STAGED"      == 1 ]] && p+="${modified}+"
  [[ "$VCS_STATUS_HAS_UNSTAGED"    == 1 ]] && p+="${modified}!"
  [[ "$VCS_STATUS_HAS_UNTRACKED"   == 1 ]] && p+="${untracked}?"
  [[ "$VCS_STATUS_COMMITS_AHEAD"  -gt 0 ]] && p+="${clean} ⇡${VCS_STATUS_COMMITS_AHEAD}"
  [[ "$VCS_STATUS_COMMITS_BEHIND" -gt 0 ]] && p+="${clean} ⇣${VCS_STATUS_COMMITS_BEHIND}"
  [[ "$VCS_STATUS_STASHES"        -gt 0 ]] && p+="${clean} *${VCS_STATUS_STASHES}"

  GITSTATUS_PROMPT="${reset}${p}${reset}"
}

# Start gitstatusd in the background.
gitstatus_stop && gitstatus_start

# On every prompt, fetch git status and set GITSTATUS_PROMPT.
PROMPT_COMMAND=gitstatus_prompt_update

# Customize prompt. Put $GITSTATUS_PROMPT in it reflect git status.
#
# Example:
#
#   user@host ~/projects/skynet master+!
#   $ █
PS1='\[\033[01;32m\]\u@\h\[\033[00m\] '           # green user@host
PS1+='\[\033[01;34m\]\w\[\033[00m\]'              # blue current working directory
PS1+='${GITSTATUS_PROMPT:+ }${GITSTATUS_PROMPT}'  # git status
PS1+='\n\[\033[01;$((31+!$?))m\]\$\[\033[00m\] '  # green/red (success/error) $/# (normal/root)
PS1+='\[\e]0;\u@\h: \w\a\]'                       # terminal title: user@host: dir