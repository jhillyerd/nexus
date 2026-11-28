# TTFT Prefix-Cache Audit Tool

`audit/ttft` is a standalone operator harness for measuring warm vs. cold
time-to-first-token (TTFT) against a live OpenAI-compatible endpoint. It
is decoupled from the server's configuration and intended for manual
benchmarks, not CI.

## Usage

```sh
export NEXUS_AUDIT_BASE_URL=http://127.0.0.1:11434/v1
export NEXUS_AUDIT_MODEL=qwen3:8b

gleam run -m audit/ttft

# Print CSV header and rows after progress lines:
gleam run -m audit/ttft -- --csv
```

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `NEXUS_AUDIT_BASE_URL` | — | **Required.** OpenAI-compatible base URL including `/v1`. |
| `NEXUS_AUDIT_MODEL` | — | **Required.** Model alias to benchmark. |
| `NEXUS_AUDIT_API_KEY` | unset | Optional bearer API key (omit for keyless local endpoints). |
| `NEXUS_AUDIT_TURNS` | `20` | Turns per measured thread (`>= 20`; turn 1 is the cold sample). |
| `NEXUS_AUDIT_REPEATS` | `5` | Number of fresh cold-start thread repeats (`>= 1`). |
| `NEXUS_AUDIT_SSE_FIRST_RESPONSE_TIMEOUT_MS` | `30000` | SSE initial response timeout in ms. |
| `NEXUS_AUDIT_STREAM_IDLE_TIMEOUT_MS` | `120000` | Receive timeout between SSE events in ms. |
