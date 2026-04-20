#!/usr/bin/env bash

set -e

OUTPUT="$HOME/.config/opencode/opencode.json"

# ===== 参数 =====
while getopts "b:k:o:h" opt; do
  case $opt in
    b) BASE_URL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    h)
      echo "用法: $0 -b <BASE_URL> -k <API_KEY> [-o OUTPUT]"
      exit 0
      ;;
    *) exit 1 ;;
  esac
done

if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ]; then
  echo "❌ 必须提供 -b 和 -k"
  exit 1
fi

# 自动修复 /models
BASE_URL=$(echo "$BASE_URL" | sed 's|/models$||')

mkdir -p "$(dirname "$OUTPUT")"

echo "👉 拉取模型..."
MODELS_JSON=$(curl -s "$BASE_URL/models" \
  -H "Authorization: Bearer $API_KEY")

if ! echo "$MODELS_JSON" | jq -e '.data' >/dev/null 2>&1; then
  echo "❌ 拉取模型失败"
  echo "$MODELS_JSON"
  exit 1
fi

# ===== 分类逻辑 =====
CLASSIFIED=$(echo "$MODELS_JSON" | jq '
.data
| map(
    .vendor =
      (if (.id | startswith("gpt")) then "openai"
       elif (.id | contains("claude")) then "anthropic"
       elif (.id | contains("kimi")) then "moonshotai"
       else "other" end)
  )
')

VENDORS=$(echo "$CLASSIFIED" | jq -r '.[].vendor' | sort -u)

PROVIDERS="{}"

echo "👉 构建 provider..."

for V in $VENDORS; do
  echo "  - $V"

  MODELS=$(echo "$CLASSIFIED" | jq --arg v "$V" '
    map(select(.vendor == $v))
    | map(
        # 去掉日期后缀
        (.id | sub("-[0-9]{8}$"; "")) as $clean
        | { ($clean): { name: $clean } }
      )
    | add
  ')

  PROVIDERS=$(echo "$PROVIDERS" | jq \
    --arg v "$V" \
    --arg base "$BASE_URL" \
    --arg key "$API_KEY" \
    --argjson models "$MODELS" \
    '
    . + {
      ("ai/" + $v): {
        npm: "@ai-sdk/openai-compatible",
        name: (
          if $v == "openai" then "AI · OpenAI"
          elif $v == "anthropic" then "AI · Anthropic"
          elif $v == "moonshotai" then "AI · Moonshot"
          else "AI · " + $v
          end
        ),
        options: {
          baseURL: $base,
          apiKey: $key
        },
        models: $models
      }
    }
    ')
done

# ===== 默认模型 =====
DEFAULT_PROVIDER="ai/openai"
DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r '
  ."ai/openai".models | keys[0]
')

# fallback（如果没有 openai）
if [ "$DEFAULT_MODEL" = "null" ] || [ -z "$DEFAULT_MODEL" ]; then
  FIRST_VENDOR=$(echo "$VENDORS" | head -n1)
  DEFAULT_PROVIDER="ai/$FIRST_VENDOR"
  DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r --arg v "$DEFAULT_PROVIDER" '
    .[$v].models | keys[0]
  ')
fi

echo "👉 写入配置..."

jq -n \
  --argjson providers "$PROVIDERS" \
  --arg model "$DEFAULT_PROVIDER/$DEFAULT_MODEL" \
  '
  {
    "$schema": "https://opencode.ai/config.json",
    provider: $providers,
    model: $model
  }
  ' > "$OUTPUT"

echo "✅ 完成: $OUTPUT"
echo "👉 默认模型: $DEFAULT_PROVIDER/$DEFAULT_MODEL"

# ===== JSON 校验 =====
echo "👉 校验 JSON..."
jq . "$OUTPUT" >/dev/null && echo "✅ JSON 合法"
