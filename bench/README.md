# bench

k6 load profiles for the inference endpoint, at concurrency 1, 8 and 32.

```sh
export BENCH_BASE_URL=http://localhost:8000
export BENCH_MODEL=<the id /v1/models reports>
export BENCH_OUT_DIR=../materials/measurements/$(date -u +%Y-%m-%d)

mise run bench            # all three, in order
mise run bench 8          # just one
```

## The three profiles

`concurrency-1.js`, `concurrency-8.js` and `concurrency-32.js` differ in one number and nothing
else. Everything they measure lives in `lib.js`, so a change to what is measured cannot apply to one
level and not the others.

Each uses the `constant-vus` executor rather than a ramp. The question these answer is what the
system does at a steady concurrency, not where it breaks; a ramp measures the ramp.

One prompt, fixed, for every profile and every run. A benchmark whose input varies between runs
measures the input as much as the system.

## What is measured

`http_req_duration` on its own says almost nothing about an LLM endpoint: the cost of a request is
set by how many tokens come back. So `lib.js` records four custom metrics alongside k6's own:

| metric | meaning |
| --- | --- |
| `llm_completion_duration` | wall-clock per completion, trend |
| `llm_output_tokens` | total completion tokens, from `usage.completion_tokens` |
| `llm_output_tokens_per_second` | per-request output rate, trend |
| `llm_completion_failures` | rate of requests that were not a 200 with at least one choice |

The request is a `POST /v1/completions` against vLLM's OpenAI-compatible server, with
`temperature: 0` and `stream: false`.

## Thresholds

The only threshold that ships is a correctness one: fewer than 1% of requests may fail. There is
deliberately no latency or throughput threshold, because this system has not been measured yet and a
number invented here would end up quoted as if it had been.

Once `materials/measurements/` holds real figures, set `BENCH_P95_MS` and `BENCH_MIN_TPS` and
`lib.js` will add the corresponding thresholds.

## Where the results go

Each run writes its full k6 result set as JSON, named `bench-c<n>-<timestamp>.json`, into
`BENCH_OUT_DIR`. If `BENCH_OUT_DIR` is not set the results go to a temporary directory and
`bench.sh` says loudly that they will not survive.

That is not fussiness. Every number in the README, the wiki or a blog draft has to trace to a file
under `materials/`, and a benchmark whose output was only ever on a terminal cannot be cited by
anything.

## Environment

| variable | required | default |
| --- | --- | --- |
| `BENCH_BASE_URL` | yes | — |
| `BENCH_MODEL` | yes | — |
| `BENCH_OUT_DIR` | no | a temporary directory, with a warning |
| `BENCH_DURATION` | no | `2m` |
| `BENCH_MAX_TOKENS` | no | `128` |
| `BENCH_TIMEOUT` | no | `120s` |
| `BENCH_P95_MS` | no | no latency threshold |
| `BENCH_MIN_TPS` | no | no throughput threshold |

`bench.sh` checks `/v1/models` answers before starting, so a wrong URL costs a second rather than
two minutes.
