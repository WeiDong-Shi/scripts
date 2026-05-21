#!/usr/bin/env bash

set -euo pipefail

OUTPUT="${HOME}/.config/opencode/opencode.json"
INSTALL_DEFAULT_SKILLS=0
# 自动按模型名称识别官方支持的 reasoning/thinking variants：
#   OpenAI:    none / minimal / low / medium / high / xhigh
#   Anthropic: high / max
#   Google:    low / high
# 其他未识别/未支持的模型不添加 variants。
SKILLS_LIST_URL="https://raw.githubusercontent.com/WeiDong-Shi/scripts/main/skills.txt"
SKILLS_ROOT="${HOME}/.config/opencode/skills"

usage() {
  cat <<EOF
用法: $0 -b <BASE_URL> -k <API_KEY> [-o OUTPUT] [-s]

参数:
  -b <BASE_URL>   模型服务基础地址
  -k <API_KEY>    API Key
  -o <OUTPUT>     输出配置文件路径，默认: ${OUTPUT}
  -s              从 skills.txt 安装默认 skills（每行一个 SKILL.md 的 raw URL）
  -h              显示帮助

说明:
  脚本会自动按模型名称识别并添加官方支持的推理等级 variants：
    OpenAI:    none / minimal / low / medium / high / xhigh
    Anthropic: high / max
    Google:    low / high
  其他模型不会添加 variants。
EOF
}

require_linux_apt() {
  if [ "$(uname -s)" != "Linux" ]; then
    echo "❌ 当前脚本只支持 Linux"
    exit 1
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "❌ 当前系统未找到 apt-get，脚本仅支持 Debian/Ubuntu 系列"
    exit 1
  fi
}

install_dependencies() {
  echo "👉 更新 apt 索引..."
  sudo apt-get update

  echo "👉 安装依赖..."
  sudo apt-get install -y --no-upgrade curl jq git ca-certificates
}

source_shell_config() {
  if [ -f "${HOME}/.bashrc" ]; then
    echo "👉 source ~/.bashrc"
    # shellcheck disable=SC1090
    . "${HOME}/.bashrc" || true
    return
  fi

  if [ -f "${HOME}/.bash_profile" ]; then
    echo "👉 source ~/.bash_profile"
    # shellcheck disable=SC1090
    . "${HOME}/.bash_profile" || true
  fi
}

install_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    echo "✅ opencode 已安装: $(command -v opencode)"
    return
  fi

  echo "👉 安装 opencode..."
  curl -fsSL https://opencode.ai/install | bash

  if command -v opencode >/dev/null 2>&1; then
    echo "✅ opencode 安装成功: $(command -v opencode)"
    return
  fi

  source_shell_config

  if command -v opencode >/dev/null 2>&1; then
    echo "✅ opencode 安装成功: $(command -v opencode)"
    return
  fi

  echo "❌ opencode 安装后仍未找到命令，请检查安装输出"
  exit 1
}

validate_tools() {
  for cmd in curl jq git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "❌ 缺少依赖: $cmd"
      exit 1
    fi
  done
}

normalize_base_url() {
  BASE_URL="${BASE_URL%/}"
  BASE_URL="${BASE_URL%/models}"
}

fetch_models() {
  echo "👉 拉取模型..."
  MODELS_JSON=$(curl -fsS "${BASE_URL}/models" \
    -H "Authorization: Bearer ${API_KEY}")
}


validate_models_json() {
  if ! echo "$MODELS_JSON" | jq -e '.data and (.data | type == "array")' >/dev/null 2>&1; then
    echo "❌ 拉取模型失败或返回格式不正确"
    echo "$MODELS_JSON"
    exit 1
  fi
}

build_classified_models() {
  CLASSIFIED=$(echo "$MODELS_JSON" | jq '
    .data
    | map(
        .vendor =
          ((.id | ascii_downcase) as $id
           | if ($id | startswith("gpt") or startswith("o") or contains("openai")) then "openai"
             elif ($id | contains("claude")) then "anthropic"
             elif ($id | contains("gemini") or contains("google")) then "google"
             elif ($id | contains("kimi") or contains("moonshot")) then "moonshotai"
             else "other" end)
      )
  ')
}

build_providers() {
  VENDORS=$(echo "$CLASSIFIED" | jq -r '.[].vendor' | sort -u)
  PROVIDERS='{}'

  echo "👉 构建 provider..."

  for V in $VENDORS; do
    echo "  - $V"

    MODELS=$(echo "$CLASSIFIED" | jq \
      --arg v "$V" \
      '
      # OpenCode 官方 OpenAI variants：none / minimal / low / medium / high / xhigh
      def openai_reasoning_variants:
        {
          variants: {
            none: {
              reasoningEffort: "none",
              textVerbosity: "low",
              reasoningSummary: "auto"
            },
            minimal: {
              reasoningEffort: "minimal",
              textVerbosity: "low",
              reasoningSummary: "auto"
            },
            low: {
              reasoningEffort: "low",
              textVerbosity: "low",
              reasoningSummary: "auto"
            },
            medium: {
              reasoningEffort: "medium",
              textVerbosity: "low",
              reasoningSummary: "auto"
            },
            high: {
              reasoningEffort: "high",
              textVerbosity: "low",
              reasoningSummary: "auto"
            },
            xhigh: {
              reasoningEffort: "xhigh",
              textVerbosity: "low",
              reasoningSummary: "auto"
            }
          }
        };

      # OpenCode 官方 Anthropic variants：high / max
      # 注意：本脚本所有 provider 默认都使用 @ai-sdk/openai-compatible。
      # Claude thinking 是 Anthropic 原生参数；只有你的中转明确支持透传/转换时才会真正生效。
      def anthropic_thinking_variants:
        {
          variants: {
            high: {
              thinking: {
                type: "enabled",
                budgetTokens: 16000
              }
            },
            max: {
              thinking: {
                type: "enabled",
                budgetTokens: 32000
              }
            }
          }
        };



      # OpenCode 官方 Google variants：low / high
      # Google Gemini 3 使用 thinkingLevel；Gemini 2.5 使用 thinkingBudget。
      # 这里按官方 variant 名称走 thinkingLevel，是否生效取决于 provider/中转是否支持 providerOptions.google。
      def google_thinking_variants:
        {
          variants: {
            low: {
              providerOptions: {
                google: {
                  thinkingConfig: {
                    thinkingLevel: "low"
                  }
                }
              }
            },
            high: {
              providerOptions: {
                google: {
                  thinkingConfig: {
                    thinkingLevel: "high"
                  }
                }
              }
            }
          }
        };

      def model_extra($vendor):
        if $vendor == "openai" then openai_reasoning_variants
        elif $vendor == "anthropic" then anthropic_thinking_variants
        elif $vendor == "google" then google_thinking_variants
        else {} end;

      map(select(.vendor == $v))
      | map(
          (.id | sub("-[0-9]{8}$"; "")) as $clean
          | { ($clean): ({ name: $clean } + model_extra($v)) }
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
            elif $v == "google" then "AI · Google"
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
}

select_default_model() {
  DEFAULT_PROVIDER='ai/openai'
  DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r '."ai/openai".models? // {} | keys[0] // empty')

  if [ "$DEFAULT_MODEL" = "null" ] || [ -z "$DEFAULT_MODEL" ]; then
    FIRST_VENDOR=$(echo "$VENDORS" | head -n1)
    DEFAULT_PROVIDER="ai/${FIRST_VENDOR}"
    DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r --arg v "$DEFAULT_PROVIDER" '.[$v].models? // {} | keys[0] // empty')
  fi

  if [ "$DEFAULT_MODEL" = "null" ] || [ -z "$DEFAULT_MODEL" ]; then
    echo "❌ 未找到可用模型，无法设置默认模型"
    exit 1
  fi
}

write_config() {
  mkdir -p "$(dirname "$OUTPUT")"

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
  echo "👉 推理等级 variants: 自动识别 OpenAI / Anthropic / Google；其他模型不添加"
}

validate_output_json() {
  echo "👉 校验 JSON..."
  jq . "$OUTPUT" >/dev/null
  echo "✅ JSON 合法"
}

sanitize_skill_dir() {
  printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|-|g'
}

skill_name_from_url() {
  local url="$1"
  local base
  base=$(basename "$(dirname "$url")")

  if [ -z "$base" ] || [ "$base" = "." ] || [ "$base" = "/" ]; then
    base="skill"
  fi

  sanitize_skill_dir "$base"
}

install_default_skills() {
  if [ "$INSTALL_DEFAULT_SKILLS" -ne 1 ]; then
    return
  fi

  echo "👉 下载默认 skills 列表..."
  SKILLS_CONTENT=$(curl -fsSL "$SKILLS_LIST_URL")

  if [ -z "$SKILLS_CONTENT" ]; then
    echo "⚠️ skills 列表为空，跳过"
    return
  fi

  mkdir -p "$SKILLS_ROOT"

  local success_count=0
  local fail_count=0
  local skill_url
  local skill_name
  local skill_dir

  echo "👉 安装默认 skills..."

  while IFS= read -r skill_url; do
    skill_url=$(printf '%s' "$skill_url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [ -z "$skill_url" ] || [[ "$skill_url" = \#* ]]; then
      continue
    fi

    if [[ "$skill_url" != http://* && "$skill_url" != https://* ]]; then
      echo "  - $skill_url"
      echo "    ⚠️ 这一行不是合法的 raw URL，已跳过"
      fail_count=$((fail_count + 1))
      continue
    fi

    skill_name=$(skill_name_from_url "$skill_url")
    skill_dir="${SKILLS_ROOT}/${skill_name}"
    mkdir -p "$skill_dir"

    echo "  - ${skill_name}"

    if curl -fsSL "$skill_url" -o "${skill_dir}/SKILL.md"; then
      success_count=$((success_count + 1))
    else
      echo "    ⚠️ 下载失败: ${skill_url}"
      rm -f "${skill_dir}/SKILL.md"
      rmdir "$skill_dir" 2>/dev/null || true
      fail_count=$((fail_count + 1))
    fi
  done <<< "$SKILLS_CONTENT"

  echo "✅ skills 安装完成，成功: ${success_count}，失败: ${fail_count}"
  echo "👉 skills 安装目录: ${SKILLS_ROOT}"
}

while getopts "b:k:o:sh" opt; do
  case "$opt" in
    b) BASE_URL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    o) OUTPUT="$OPTARG" ;;
    s) INSTALL_DEFAULT_SKILLS=1 ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [ -z "${BASE_URL:-}" ] || [ -z "${API_KEY:-}" ]; then
  echo "❌ 必须提供 -b 和 -k"
  usage
  exit 1
fi

require_linux_apt
install_dependencies
validate_tools
install_opencode
source_shell_config
normalize_base_url
fetch_models
validate_models_json
build_classified_models
build_providers
select_default_model
write_config
validate_output_json
install_default_skills

echo "✅ 脚本执行完成"
echo "👉 如果当前终端仍然识别不到 opencode，请手动执行: source ~/.bashrc"
echo "👉 默认 skills 已安装到 ~/.config/opencode/skills，可供 opencode 使用"
