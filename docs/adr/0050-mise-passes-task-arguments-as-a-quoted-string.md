# 0050. mise passes task arguments as one quoted string, not as positionals

Date: 2026-09-08

## Status

Accepted.

## Context

`mise.toml` declares arguments for four tasks with a `usage` block:

```toml
[tasks.up]
usage = '''
arg "<vars>" var=#true help="WINDOW_ID=<n> WINDOW_HOURS=<h>"
'''
run = "scripts/window-up.sh"
```

The obvious assumption is that `mise run up WINDOW_ID=0 WINDOW_HOURS=3` reaches
`scripts/window-up.sh` as `$1` and `$2`. It does not. I found this out by printing `$#` from inside a
task and getting `0`.

What actually happens is that mise sets an environment variable named after the declared argument
and puts the values in it as a single shell-quoted string:

```text
usage_vars='WINDOW_ID=0' 'WINDOW_HOURS=3'
```

The quoting is real quoting, so a value containing a space survives it, but the script receives one
string rather than a list.

This matters more here than it would elsewhere. `mise run up` is the command that opens a cloud
window, and its two arguments are copied verbatim from an approval message. A script that silently
saw no arguments at all would either refuse to run, which is merely annoying, or fall back to a
default, which would be a window opened without approval.

## Decision

Every script that takes arguments handles both forms. Where there are no positional parameters and
the matching `usage_<name>` variable is set, the variable is re-expanded:

```bash
if [ "$#" -eq 0 ]; then
  _usage_vars="$(mise_usage_arg vars)"
  if [ -n "$_usage_vars" ]; then
    eval "set -- $_usage_vars"
  fi
fi
```

`mise_usage_arg` lives in `scripts/lib/common.sh` and is a one-line indirect expansion. The `eval` is
guarded by the `$# -eq 0` check so that a direct invocation with real arguments always wins.

## Consequences

`eval` in a shell script is normally a smell. Here it is the correct tool: the string is
shell-quoted by mise precisely so that a shell can re-expand it, and any other way of splitting it
would get the quoting wrong. The guard means it never runs when the script is called directly.

Every script stays directly invokable: `scripts/window-up.sh WINDOW_ID=0 WINDOW_HOURS=3` works
exactly as `mise run up WINDOW_ID=0 WINDOW_HOURS=3` does. That is what makes them testable without
mise in the loop.

The variable name follows the argument name, not the task name, so `arg "<role>"` becomes
`usage_role` and `arg "<args>"` becomes `usage_args`. Renaming an argument in `mise.toml` without
renaming it in the script breaks the task silently, in the direction of "no arguments given". Every
script that takes arguments therefore fails loudly on an empty argument list rather than defaulting.

## Sources

- Established experimentally in this workspace on 2026-09-08 by printing `$#` and `env | grep usage_`
  from inside a task body. Recorded here rather than in a comment because it is the kind of thing
  that gets re-discovered once a year otherwise.
- mise task argument documentation, which describes the `usage` spec syntax but not the mechanism by
  which values reach the script: <https://mise.jdx.dev/tasks/task-configuration.html>
