# 0005. Task arguments are declared in the usage spec, not in template functions

Date: 2026-09-08

## Status

Accepted.

## Context

Four tasks in `mise.toml` take arguments: `auth`, `up`, `bench` and `screenshot`. mise offers two ways to
declare them, and they are not equivalent.

The older form embeds Tera template functions in the `run` string: `{{arg(name="file")}}`,
`{{option(...)}}`, `{{flag(...)}}`. It reads well and it is what most examples on the internet still show.

The newer form is a `usage` block that describes the arguments as a specification, separate from the command:

```toml
[tasks.up]
usage = '''
arg "<vars>" var=#true help="WINDOW_ID=<n> WINDOW_HOURS=<h>, taken verbatim from the approval message"
'''
run = "scripts/window-up.sh"
```

mise's own documentation now marks the template functions deprecated, with removal scheduled for mise
2027.5.0 and a deprecation warning emitted by every version from 2026.5.0 onwards. The reasons it gives are
worth repeating because they are all reasons this project would have hit: the functions return empty
strings during spec collection, shell escaping rules are unpredictable, and the behaviour differs between
TOML tasks and file tasks. Silently returning an empty string is a bad failure mode anywhere. In a task
whose two arguments are the window number and the window duration, copied verbatim from an approval
message, it is the worst one available.

The mechanism the `usage` form uses is not obvious, and it was established experimentally rather than read
out of the documentation: values do not arrive as positional parameters. mise exports each one as an
environment variable named `usage_<name>`, holding a shell-quoted string. ADR 0050 records that in full,
along with what the scripts do about it.

## Decision

Every task argument is declared with a `usage` block. No Tera template function appears in any `run` string
in `mise.toml`, and I am not reintroducing the deprecated form the next time an example turns up that uses
it.

Arguments are declared once, in `mise.toml`, and consumed by the script through the matching `usage_<name>`
variable. A script never re-declares or re-parses the specification.

## Consequences

`mise run up --help` prints real help, generated from the specification, and shell completion works, which
the template form could not offer. Constraints declared in the spec are checked by mise before the script
starts, so a `choices` list added to `auth` would reject a bad role at the argument parser rather than
three lines into a shell script that has already assumed something.

The variable name follows the argument name rather than the task name, so renaming an argument in
`mise.toml` without renaming it in the script breaks the task in the direction of "no argument was given".
Every script that takes arguments therefore fails loudly on an empty argument list instead of defaulting.
That is the rule ADR 0050 exists to enforce.

Removal in mise 2027.5.0 does not affect this repository, because it uses nothing that is being removed.
The deprecation date is recorded here so that a future reader who finds `{{arg()}}` in an example
understands why it is absent from this repository rather than assuming it was an oversight.

## Sources

- mise task arguments, on the `usage` field being the recommended form and on values arriving as
  environment variables prefixed with `usage_`: <https://mise.jdx.dev/tasks/task-arguments.html>
- mise TOML tasks, "Tera Template Functions deprecated": "Deprecated - Removal in 2027.5.0. Using Tera
  template functions (`arg()`, `option()`, `flag()`) in run scripts is deprecated and will be removed in
  mise 2027.5.0. Versions >= 2026.5.0 will show a deprecation warning."
  <https://mise.jdx.dev/tasks/toml-tasks.html>
- ADR 0050, for the mechanism by which a declared argument reaches a script, established experimentally.
