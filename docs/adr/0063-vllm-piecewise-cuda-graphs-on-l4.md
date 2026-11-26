# 0063. vLLM captures piecewise CUDA graphs only

Date: 2026-11-26

## Status

Accepted, unproven. The next window with a GPU node tests it.

## Context

In window 1, attempt 3, vLLM 0.28.0 started on a Spot `g6.2xlarge` (one L4) and never served a request.
Each start went the same way:

- weights loaded: 14.29 GiB in 75.45 s;
- KV cache: 5.17 GiB, 96,768 tokens, 11.81 concurrent requests at 8,192 tokens;
- `torch.compile` loaded from its cache in 0.35 s;
- `Capturing CUDA graphs (PIECEWISE)`: 19 of 19 in about 1 s;
- `Capturing CUDA graphs (FULL)`: 0 of 11, and no further output.

The startup probe allows 90 checks 10 s apart. Each time it ran out the kubelet killed the container,
exit code 137, and by teardown it had restarted six times. Memory was not the cause: the reason was
`Error`, not `OOMKilled`, and the KV cache had already been sized.

vLLM's V1 default `cudagraph_mode` is `FULL_AND_PIECEWISE`: piecewise graphs for prefill and mixed
batches, then full graphs for decode. The hang is in the second half. I do not know why. The
documentation warns that full graphs need the attention backend to support them.

## Decision

The inference chart gains `model.cudagraphMode`, default `PIECEWISE`, passed as
`--compilation-config '{"cudagraph_mode": "PIECEWISE"}'`. An empty value leaves vLLM's default.

I checked the flag and the value against the v0.28.0 source, not only the current documentation:
`--compilation-config` is defined in `vllm/engine/arg_utils.py`, and `CompilationConfig` parses
`cudagraph_mode` from a string with `CUDAGraphMode[value.upper()]`, where `PIECEWISE` is a member.

`PIECEWISE` keeps the part of the capture that finished and skips the part that hung. `--enforce-eager`
would skip both and give up the graphs that worked.

## Consequences

Decode runs without full CUDA graphs. That costs some decode speed against the default; how much is a
benchmark question for a later window, and it is cheaper than a server that never starts.

If vLLM still hangs with `PIECEWISE`, the cause is elsewhere, and the next step is `NONE` (no capture at
all) with the vLLM debug log on, inside the same window.

## Sources

- CUDA graphs design, modes and the CLI form.
  https://docs.vllm.ai/en/stable/design/cuda_graphs/
- `CompilationConfig.cudagraph_mode`.
  https://docs.vllm.ai/en/stable/api/vllm/config/compilation/
- vLLM v0.28.0 source: `vllm/config/compilation.py`, `vllm/engine/arg_utils.py`.
  https://github.com/vllm-project/vllm/tree/v0.28.0
- Evidence in the working notes: `materials/measurements/w1c-vllm-crash-log.txt`.
