#!/usr/bin/env sh
# QMD embedding env: remote-first with local fallback.
# Source this file from ~/.zshrc:
#   source /Users/sunny/Documents/coding/qmd/scripts/qmd-env.sh

export QMD_EMBED_MODEL_ID="BAAI/bge-m3"
export QMD_EMBED_LOCAL_MODEL="$HOME/Documents/coding/qmd/dist/models/bge-m3-FP16.gguf"

export QMD_EMBED_REMOTE_URL="https://api.siliconflow.cn/v1"
export QMD_EMBED_REMOTE_MODEL="BAAI/bge-m3"
export QMD_EMBED_REMOTE_TIMEOUT_MS="10000"

# Keep your key in a private env var (recommended):
#   export SILICONFLOW_API_KEY="sk-..."
# or set QMD_EMBED_REMOTE_API_KEY directly before sourcing this file.
if [ -n "${SILICONFLOW_API_KEY:-}" ]; then
  export QMD_EMBED_REMOTE_API_KEY="${SILICONFLOW_API_KEY}"
fi
