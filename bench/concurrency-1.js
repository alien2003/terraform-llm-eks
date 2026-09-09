// Load profile: 1 concurrent request(s) against the inference endpoint.
//
// The three profiles in this directory differ in this number and nothing else.
// Everything they measure lives in lib.js. Run them with:
//
//     mise run bench 1
//
// which sets BENCH_BASE_URL, BENCH_MODEL and BENCH_OUT for you and refuses to run
// without the first two.

import { completion, scenario, setupChecks, summary, thresholds } from './lib.js';

export const options = {
  scenarios: {
    concurrency_1: scenario(1),
  },
  thresholds: thresholds(),
  // Response bodies are parsed for the token counts, so they cannot be discarded.
  discardResponseBodies: false,
};

export function setup() {
  return setupChecks('concurrency-1');
}

export default function () {
  completion();
}

export function handleSummary(data) {
  return summary(data);
}
