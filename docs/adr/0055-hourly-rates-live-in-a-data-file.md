# 0055. Hourly rates live in one data file and start empty

Date: 2026-09-08

## Status

Accepted.

## Context

The window protocol requires stating the estimated cost per hour, with and without the GPU node,
before applying anything. `mise run up` prints that estimate immediately before it starts spending
money, which makes it the most consequential number this project displays.

There are three ways to produce it. Hardcode the prices in the script, which puts a figure with a
shelf life inside a file nobody re-reads. Query the Price List API at window time, which is a live
dependency on the critical path and cannot be reviewed before the window opens. Or keep the figures
in a data file that a human fills in and can be read at review time.

The rates are also the clearest case for the project's rule that no number is written from memory. A
price that is wrong by a factor of ten and looks plausible is worse than no price at all, because it
will be believed.

## Decision

`scripts/rates.json` is the single place an hourly price lives. Nothing else in `scripts/` or
`docs/` carries one.

Every `usd_per_hour` ships as `null`, with `source_url` and `sourced_on` beside it. `mise run up`
refuses to open a window while any of them is null, and names the ones that are missing. It also
refuses if the file is absent.

Line items are marked `gpu_only`, which is what lets one file produce both required figures: the sum
over the items that are not GPU-only, and the sum over everything.

The GPU line is a Spot price and is therefore an estimate with a shelf life. The file says so, and
points at `ec2 describe-spot-price-history`, a read-only call and so allowed outside a window, as the
authoritative reading for a specific hour and Availability Zone.

## Consequences

Until someone does the pricing work, `mise run up` cannot open a window. That is the intended
failure: the protocol says to state the cost, and a script that made one up would satisfy the letter
of the protocol while defeating it.

The file is reviewable. Before a window, the figures and their sources can be read in a diff instead
of extracted from a script.

Per-unit charges are deliberately absent. Data transfer, NAT gateway data processing, S3 requests
and load balancer capacity units are not hourly and are recorded after the fact in
`materials/costs/windows.md` from Cost Explorer, not estimated here. `mise run up` says so in the
same breath as the estimate, so nobody reads the hourly figure as a total.
