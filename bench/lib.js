// Shared code for the load profiles in this directory.
//
// The three profiles differ in exactly one number: how many virtual users hammer the
// endpoint at once. Everything else — the request, the checks, the metrics, the way
// the summary is written out — lives here, so that a change to what is measured
// cannot accidentally apply to one concurrency level and not the others.
//
// The endpoint is vLLM's OpenAI-compatible server. The route and the request body
// come from its documentation:
// https://docs.vllm.ai/en/stable/serving/online_serving/openai_compatible_server

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// A completion is not an HTTP request in any interesting sense. Its cost is set by
// how many tokens come back, so the metric that matters is tokens per second, and
// http_req_duration on its own says almost nothing.
export const outputTokens = new Counter('llm_output_tokens');
export const outputTokensPerSecond = new Trend('llm_output_tokens_per_second');
export const completionDuration = new Trend('llm_completion_duration', true);
export const completionFailures = new Rate('llm_completion_failures');

export const baseUrl = (__ENV.BENCH_BASE_URL || '').replace(/\/+$/, '');
export const model = __ENV.BENCH_MODEL || '';
export const maxTokens = parseInt(__ENV.BENCH_MAX_TOKENS || '128', 10);
export const duration = __ENV.BENCH_DURATION || '2m';

// One prompt, fixed, for every profile and every run. A benchmark whose input varies
// between runs measures the input as much as the system.
export const prompt =
  'Summarise, in one paragraph and without a preamble, why a permission boundary ' +
  'is not the same thing as an IAM policy.';

// Thresholds.
//
// The only threshold that ships is a correctness one: requests must not fail. There
// is deliberately no latency or throughput threshold, because the project has not
// measured this system yet and a number invented here would end up quoted as if it
// had been. Once materials/measurements/ holds real figures, set BENCH_P95_MS and
// BENCH_MIN_TPS from them and the thresholds below will pick them up.
export function thresholds() {
  const t = {
    llm_completion_failures: ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
  };
  if (__ENV.BENCH_P95_MS) {
    t.llm_completion_duration = [`p(95)<${__ENV.BENCH_P95_MS}`];
  }
  if (__ENV.BENCH_MIN_TPS) {
    t.llm_output_tokens_per_second = [`avg>${__ENV.BENCH_MIN_TPS}`];
  }
  return t;
}

// constant-vus, not ramping: the question these profiles answer is what the system
// does at a steady concurrency, not where it breaks.
// https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-vus
export function scenario(vus) {
  return {
    executor: 'constant-vus',
    vus: vus,
    duration: duration,
    gracefulStop: '30s',
    tags: { concurrency: String(vus) },
  };
}

export function completion() {
  const body = JSON.stringify({
    model: model,
    prompt: prompt,
    max_tokens: maxTokens,
    temperature: 0,
    stream: false,
  });

  const started = Date.now();
  const res = http.post(`${baseUrl}/v1/completions`, body, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'completion' },
    timeout: __ENV.BENCH_TIMEOUT || '120s',
  });
  const elapsedSeconds = (Date.now() - started) / 1000;

  const ok = check(res, {
    'status is 200': (r) => r.status === 200,
    'body has a choice': (r) => {
      if (r.status !== 200) return false;
      try {
        const parsed = r.json();
        return Array.isArray(parsed.choices) && parsed.choices.length > 0;
      } catch (e) {
        return false;
      }
    },
  });

  completionFailures.add(!ok);
  completionDuration.add(res.timings.duration);

  if (ok) {
    let completionTokens = 0;
    try {
      const parsed = res.json();
      completionTokens = (parsed.usage && parsed.usage.completion_tokens) || 0;
    } catch (e) {
      completionTokens = 0;
    }
    if (completionTokens > 0) {
      outputTokens.add(completionTokens);
      if (elapsedSeconds > 0) {
        outputTokensPerSecond.add(completionTokens / elapsedSeconds);
      }
    }
  }

  return res;
}

// Preconditions, checked once before any virtual user starts, so that a missing
// environment variable costs a second rather than the whole run.
export function setupChecks(label) {
  if (!baseUrl) {
    throw new Error('BENCH_BASE_URL is not set. mise run bench sets it; see bench/README.md.');
  }
  if (!model) {
    throw new Error('BENCH_MODEL is not set. It must match the model id the server is serving.');
  }

  const models = http.get(`${baseUrl}/v1/models`, { tags: { name: 'models' } });
  if (models.status !== 200) {
    throw new Error(`${baseUrl}/v1/models answered ${models.status}; the endpoint is not ready.`);
  }
  return { label: label, baseUrl: baseUrl, model: model };
}

// Every run writes its own JSON next to k6's own stdout summary, because Rule 5 says
// a number in the prose has to trace back to a file and a terminal scrollback is not
// a file. BENCH_OUT is set by scripts/bench.sh.
export function summary(data) {
  const out = {};
  out.stdout = textSummary(data);
  if (__ENV.BENCH_OUT) {
    out[__ENV.BENCH_OUT] = JSON.stringify(data, null, 2);
  }
  return out;
}

// A deliberately small text summary rather than k6's own, so the file and the
// terminal say the same few things and neither has to be read twice.
function textSummary(data) {
  const m = data.metrics || {};
  const line = (name, metric, field, unit) => {
    if (!metric || !metric.values || metric.values[field] === undefined) return '';
    return `  ${name.padEnd(34)} ${metric.values[field].toFixed(2)} ${unit}\n`;
  };

  let s = '\n';
  s += line('completion p95', m.llm_completion_duration, 'p(95)', 'ms');
  s += line('completion median', m.llm_completion_duration, 'med', 'ms');
  s += line('output tokens/s, mean', m.llm_output_tokens_per_second, 'avg', 'tok/s');
  s += line('output tokens, total', m.llm_output_tokens, 'count', 'tokens');
  s += line('completions', m.http_reqs, 'count', 'requests');
  s += line('failure rate', m.llm_completion_failures, 'rate', '');
  s += '\n';
  return s;
}
