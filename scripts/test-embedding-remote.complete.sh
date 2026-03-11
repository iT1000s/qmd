#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${QMD_EMBED_TEST_PORT:-19191}"
WITH_LOCAL_FALLBACK=0
WITH_CLI_EMBED=0
EXTERNAL_REMOTE_URL=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/test-embedding-remote.sh [options]

Options:
  --port <n>               Mock remote server port (default: 19191)
  --remote-url <url>       Use an existing remote endpoint instead of local mock
  --with-local-fallback    Also test "remote fails -> local fallback" (needs local model)
  --with-cli-embed         Also run end-to-end `qmd embed -f` (needs local model tokenizer)
  -h, --help               Show this help

Environment:
  QMD_EMBED_MODEL_ID
  QMD_EMBED_LOCAL_MODEL
  QMD_EMBED_REMOTE_MODEL
  QMD_EMBED_REMOTE_API_KEY
  QMD_EMBED_REMOTE_TIMEOUT_MS
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="$2"
      shift 2
      ;;
    --remote-url)
      EXTERNAL_REMOTE_URL="$2"
      shift 2
      ;;
    --with-local-fallback)
      WITH_LOCAL_FALLBACK=1
      shift
      ;;
    --with-cli-embed)
      WITH_CLI_EMBED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -x "./node_modules/.bin/tsx" ]]; then
  echo "Missing ./node_modules/.bin/tsx. Run: npm install" >&2
  exit 1
fi

TSX="./node_modules/.bin/tsx"

if ! node --input-type=module -e "await import('better-sqlite3')" >/dev/null 2>&1; then
  echo "Missing better-sqlite3. Run: npm install" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qmd-embed-test.XXXXXX")"
MOCK_PID=""
HITS_FILE="$TMP_DIR/remote_hits.log"
DOCS_DIR=""

cleanup() {
  if [[ -n "${MOCK_PID}" ]]; then
    kill "${MOCK_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

log() {
  printf "==> %s\n" "$*"
}

run_qmd() {
  "${TSX}" src/qmd.ts "$@"
}

read_hit_count() {
  if [[ ! -f "${HITS_FILE}" ]]; then
    echo 0
    return
  fi
  wc -l < "${HITS_FILE}" | tr -d ' '
}

assert_hits_unchanged() {
  local before="$1"
  local after
  after="$(read_hit_count)"
  if [[ "${after}" != "${before}" ]]; then
    echo "Expected remote hits to stay unchanged, but ${before} -> ${after}" >&2
    [[ -f "$TMP_DIR/mock.log" ]] && cat "$TMP_DIR/mock.log" >&2 || true
    exit 1
  fi
  echo "hits_unchanged count=${after}"
}

assert_hits_increased() {
  local before="$1"
  local after
  after="$(read_hit_count)"
  if (( after <= before )); then
    echo "Expected remote hits to increase, but ${before} -> ${after}" >&2
    [[ -f "$TMP_DIR/mock.log" ]] && cat "$TMP_DIR/mock.log" >&2 || true
    exit 1
  fi
  echo "hits_increased before=${before} after=${after}"
}

start_mock_server() {
  local fail_mode="$1"
  cat >"$TMP_DIR/mock-embed-server.mjs" <<'JS'
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const port = Number(process.env.MOCK_PORT || "19191");
const fail = process.env.MOCK_FAIL === "1";
const expectedApiKey = process.env.MOCK_API_KEY || "";
const hitsFile = process.env.MOCK_HITS_FILE || "";
const dims = 8;

function vectorFromText(text) {
  let seed = 0;
  for (let i = 0; i < text.length; i++) {
    seed = (seed * 31 + text.charCodeAt(i)) % 2147483647;
  }
  const out = [];
  for (let i = 0; i < dims; i++) {
    seed = (seed * 48271) % 2147483647;
    out.push((seed % 1000) / 1000);
  }
  return out;
}

const server = createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  if (req.method !== "POST" || req.url !== "/v1/embeddings") {
    res.writeHead(404);
    res.end("not found");
    return;
  }

  if (expectedApiKey && req.headers.authorization !== `Bearer ${expectedApiKey}`) {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  if (fail) {
    res.writeHead(503, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "forced failure" }));
    return;
  }

  let raw = "";
  for await (const chunk of req) raw += chunk;

  let payload;
  try {
    payload = JSON.parse(raw || "{}");
  } catch {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "invalid json" }));
    return;
  }

  const model = String(payload.model || "unknown-model");
  const input = payload.input;
  const inputs = Array.isArray(input) ? input : [input];
  if (!inputs.length || inputs.some(v => typeof v !== "string")) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "input must be string or string[]" }));
    return;
  }

  if (hitsFile) {
    appendFileSync(hitsFile, `${Date.now()}\n`, "utf-8");
  }

  const data = inputs.map((text, index) => ({
    object: "embedding",
    index,
    embedding: vectorFromText(text),
  }));

  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ object: "list", model, data }));
});

server.listen(port, "127.0.0.1");
JS

  : >"${HITS_FILE}"
  MOCK_PORT="${PORT}" \
  MOCK_FAIL="${fail_mode}" \
  MOCK_API_KEY="${QMD_EMBED_REMOTE_API_KEY}" \
  MOCK_HITS_FILE="${HITS_FILE}" \
  node "$TMP_DIR/mock-embed-server.mjs" >"$TMP_DIR/mock.log" 2>&1 &
  MOCK_PID=$!

  for _ in $(seq 1 60); do
    if node -e "fetch('http://127.0.0.1:${PORT}/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "Mock server did not start in time" >&2
  cat "$TMP_DIR/mock.log" >&2 || true
  exit 1
}

restart_mock_server() {
  local fail_mode="$1"
  if [[ -n "${MOCK_PID}" ]]; then
    kill "${MOCK_PID}" >/dev/null 2>&1 || true
    MOCK_PID=""
  fi
  start_mock_server "${fail_mode}"
}

run_llm_embed_once() {
  "${TSX}" - <<'TS'
import { LlamaCpp } from "./src/llm.ts";

const llm = new LlamaCpp({
  embedModelId: process.env.QMD_EMBED_MODEL_ID,
  embedModel: process.env.QMD_EMBED_LOCAL_MODEL,
  remoteEmbed: {
    url: process.env.QMD_EMBED_REMOTE_URL,
    model: process.env.QMD_EMBED_REMOTE_MODEL,
    apiKey: process.env.QMD_EMBED_REMOTE_API_KEY,
    timeoutMs: Number(process.env.QMD_EMBED_REMOTE_TIMEOUT_MS || "5000"),
  },
  allowEmbedModelMismatch: process.env.QMD_EMBED_ALLOW_MODEL_MISMATCH === "1",
});

try {
  const result = await llm.embed("这是一个真实 embedding 测试。", { model: process.env.QMD_EMBED_MODEL_ID });
  if (!result || !result.embedding.length) {
    throw new Error("Embedding call returned no vector");
  }
  if (result.model !== process.env.QMD_EMBED_MODEL_ID) {
    throw new Error(`Unexpected model id: ${result.model}`);
  }
  console.log(`embedding_ok dims=${result.embedding.length} model=${result.model}`);
} finally {
  await llm.dispose();
}
TS
}

verify_vector_models_in_db() {
  node --input-type=module <<'TS'
import Database from "better-sqlite3";

const db = new Database(process.env.INDEX_PATH);
const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='content_vectors'").get();
if (!table) {
  throw new Error("content_vectors table does not exist");
}
const total = db.prepare("SELECT COUNT(*) AS c FROM content_vectors").get().c;
if (total < 1) {
  throw new Error("No vectors found in content_vectors");
}
const mismatched = db.prepare("SELECT COUNT(*) AS c FROM content_vectors WHERE model <> ?").get(process.env.QMD_EMBED_MODEL_ID).c;
if (mismatched > 0) {
  throw new Error(`Found ${mismatched} vectors with mismatched model id`);
}
console.log(`db_ok vectors=${total} model=${process.env.QMD_EMBED_MODEL_ID}`);
TS
}

prepare_test_collection() {
  if [[ -n "${DOCS_DIR}" && -d "${DOCS_DIR}" ]]; then
    return
  fi

  DOCS_DIR="$TMP_DIR/docs"
  mkdir -p "$DOCS_DIR"
  cat >"$DOCS_DIR/test.md" <<'MD'
# 测试文档

这是一个用于验证 qmd 搜索行为的真实测试文档。
它包含远程 embedding、向量搜索、BM25、query expansion 等关键词。
OpenClaw memory backend currently shells out to qmd.
MD

  run_qmd collection add "$DOCS_DIR" --name docs >"$TMP_DIR/collection.out" 2>&1
  run_qmd update >"$TMP_DIR/update.out" 2>&1
}

export QMD_CONFIG_DIR="$TMP_DIR/config"
export XDG_CACHE_HOME="$TMP_DIR/cache"
export INDEX_PATH="$TMP_DIR/index.sqlite"
mkdir -p "$QMD_CONFIG_DIR" "$XDG_CACHE_HOME"

export QMD_EMBED_MODEL_ID="${QMD_EMBED_MODEL_ID:-embeddinggemma}"
export QMD_EMBED_LOCAL_MODEL="${QMD_EMBED_LOCAL_MODEL:-hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf}"
export QMD_EMBED_REMOTE_API_KEY="${QMD_EMBED_REMOTE_API_KEY:-test-key}"
export QMD_EMBED_REMOTE_TIMEOUT_MS="${QMD_EMBED_REMOTE_TIMEOUT_MS:-5000}"
unset QMD_EMBED_ALLOW_MODEL_MISMATCH || true

if [[ -n "${EXTERNAL_REMOTE_URL}" ]]; then
  export QMD_EMBED_REMOTE_URL="${EXTERNAL_REMOTE_URL}"
  export QMD_EMBED_REMOTE_MODEL="${QMD_EMBED_REMOTE_MODEL:-$QMD_EMBED_MODEL_ID}"
  log "Using external remote endpoint: ${QMD_EMBED_REMOTE_URL}"
else
  export QMD_EMBED_REMOTE_URL="http://127.0.0.1:${PORT}/v1"
  export QMD_EMBED_REMOTE_MODEL="${QMD_EMBED_REMOTE_MODEL:-$QMD_EMBED_MODEL_ID}"
  log "Starting local mock remote endpoint on port ${PORT}"
  start_mock_server "0"
fi

log "Test 1/7: mismatch is rejected by default"
if QMD_EMBED_REMOTE_MODEL="definitely-mismatch-model" run_qmd status >"$TMP_DIR/mismatch.out" 2>&1; then
  echo "Expected mismatch to fail, but command succeeded." >&2
  cat "$TMP_DIR/mismatch.out" >&2
  exit 1
fi
if ! grep -qi "model IDs differ" "$TMP_DIR/mismatch.out"; then
  echo "Mismatch error message not found." >&2
  cat "$TMP_DIR/mismatch.out" >&2
  exit 1
fi

log "Test 2/7: --force-model-mismatch bypasses the guard"
if ! QMD_EMBED_REMOTE_MODEL="definitely-mismatch-model" run_qmd --force-model-mismatch status >"$TMP_DIR/force.out" 2>&1; then
  echo "Force override test failed unexpectedly." >&2
  cat "$TMP_DIR/force.out" >&2
  exit 1
fi

log "Test 3/7: remote embedding works and returns configured model id"
run_llm_embed_once >"$TMP_DIR/remote-embed.out" 2>&1
cat "$TMP_DIR/remote-embed.out"

if [[ -z "${EXTERNAL_REMOTE_URL}" ]]; then
  if [[ ! -s "${HITS_FILE}" ]]; then
    echo "Remote endpoint was not hit (mock hits file is empty)." >&2
    cat "$TMP_DIR/mock.log" >&2 || true
    exit 1
  fi
fi

log "Test 4/7: qmd search does not hit remote embeddings"
prepare_test_collection
before_hits="$(read_hit_count)"
run_qmd search "远程 embedding" --json >"$TMP_DIR/search.out" 2>&1
cat "$TMP_DIR/search.out"
assert_hits_unchanged "${before_hits}"

log "Test 5/7: qmd vsearch hits remote embeddings"
run_qmd embed -f >"$TMP_DIR/embed-for-vsearch.out" 2>&1
before_hits="$(read_hit_count)"
run_qmd vsearch "远程 embedding" --json >"$TMP_DIR/vsearch.out" 2>&1
cat "$TMP_DIR/vsearch.out"
assert_hits_increased "${before_hits}"

log "Test 6/7: qmd query hits remote embeddings"
before_hits="$(read_hit_count)"
run_qmd query "远程 embedding" --json >"$TMP_DIR/query.out" 2>&1
cat "$TMP_DIR/query.out"
assert_hits_increased "${before_hits}"

if [[ "${WITH_LOCAL_FALLBACK}" -eq 1 ]]; then
  log "Test 7/7: remote failure falls back to local embedding model"
  if [[ -z "${EXTERNAL_REMOTE_URL}" ]]; then
    restart_mock_server "1"
    if ! run_llm_embed_once >"$TMP_DIR/fallback.out" 2>&1; then
      echo "Fallback test failed. Local model may be missing." >&2
      cat "$TMP_DIR/fallback.out" >&2
      exit 1
    fi
  else
    if ! QMD_EMBED_REMOTE_URL="http://127.0.0.1:9/v1" run_llm_embed_once >"$TMP_DIR/fallback.out" 2>&1; then
      echo "Fallback test failed. Local model may be missing." >&2
      cat "$TMP_DIR/fallback.out" >&2
      exit 1
    fi
  fi
  cat "$TMP_DIR/fallback.out"
else
  log "Skipping fallback-to-local test (use --with-local-fallback to enable)"
fi

if [[ "${WITH_CLI_EMBED}" -eq 1 ]]; then
  log "Running end-to-end CLI embed test"
  if [[ -z "${EXTERNAL_REMOTE_URL}" ]]; then
    restart_mock_server "0"
  fi
  run_qmd embed -f >"$TMP_DIR/embed.out" 2>&1
  verify_vector_models_in_db >"$TMP_DIR/db-check.out" 2>&1
  cat "$TMP_DIR/db-check.out"
else
  log "Skipping end-to-end CLI embed test (use --with-cli-embed to enable)"
fi

log "All selected embedding tests passed."
