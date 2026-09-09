# vhs tape for the README demo.
#
# Deliberately boring: it records the local checks and the task list, and nothing
# that touches AWS. A demo GIF that shows a cloud command either fails on a machine
# with no credentials, or works on a machine with them and puts an account id in a
# picture that ends up in a public README.
#
# https://github.com/charmbracelet/vhs

Output docs/demo.gif

Require mise

Set Shell bash
Set FontSize 16
Set Width 1200
Set Height 700
Set Padding 20
Set TypingSpeed 40ms

Hide
Type "cd $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
Enter
Type "clear"
Enter
Show

Type "# every entry point this project has"
Enter
Sleep 800ms

Type "mise tasks"
Enter
Sleep 6s

Type "clear"
Enter

Type "# and every check that runs without cloud credentials"
Enter
Sleep 800ms

Type "mise run lint"
Enter
Sleep 60s
