#!/usr/bin/env bash

set -euo pipefail

OUTPUT="${HOME}/.config/opencode/opencode.json"
INSTALL_DEFAULT_SKILLS=0
SKILLS_LIST_URL="https://raw.githubusercontent.com/WeiDong-Shi/scripts/main/skills.txt"
SKILLS_ROOT="${HOME}/.config/opencode/skills"

usage() {
  cat <<EOF
用法: $0 -b <BASE_URL> -k <API_KEY> [-o OUTPUT] [-s]

参数:
  -b <BASE_URL>   模型服务基础地址
  -k <API_KEY>    API Key
  -o <OUTPUT>     输出配置文件路径，默认: ${OUTPUT}
  -s              从 skills.txt 安装默认 skills（每行一个 GitHub repo 地址，批量安装该仓库 skills/ 下所有技能）
  -h              显示帮助
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
  sudo apt-get install -y curl jq ca-certificates
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
          (if (.id | startswith("gpt")) then "openai"
           elif (.id | contains("claude")) then "anthropic"
           elif (.id | contains("kimi")) then "moonshotai"
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

    MODELS=$(echo "$CLASSIFIED" | jq --arg v "$V" '
      map(select(.vendor == $v))
      | map(
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
}

select_default_model() {
  DEFAULT_PROVIDER='ai/openai'
  DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r '."ai/openai".models | keys[0]')

  if [ "$DEFAULT_MODEL" = "null" ] || [ -z "$DEFAULT_MODEL" ]; then
    FIRST_VENDOR=$(echo "$VENDORS" | head -n1)
    DEFAULT_PROVIDER="ai/${FIRST_VENDOR}"
    DEFAULT_MODEL=$(echo "$PROVIDERS" | jq -r --arg v "$DEFAULT_PROVIDER" '.[$v].models | keys[0]')
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
}

validate_output_json() {
  echo "👉 校验 JSON..."
  jq . "$OUTPUT" >/dev/null
  echo "✅ JSON 合法"
}

sanitize_skill_dir() {
  printf '%s' "$1" | sed 's|[^A-Za-z0-9._-]|-|g'
}

extract_repo_slug() {
  local input="$1"

  input="${input#https://github.com/}"
  input="${input#http://github.com/}"
  input="${input#git@github.com:}"
  input="${input%.git}"
  input="${input%/}"

  if [[ "$input" == */tree/* ]]; then
    input="${input%%/tree/*}"
  fi

  printf '%s' "$input"
}

install_repo_skills() {
  local repo_slug="$1"
  local api_url="https://api.github.com/repos/${repo_slug}/contents/skills"
  local skill_names
  local skill_name
  local skill_dir
  local skill_url
  local installed_count=0

  skill_names=$(curl -fsSL "$api_url" | jq -r '.[] | select(.type == "dir") | .name') || return 1

  if [ -z "$skill_names" ]; then
    return 1
  fi

  while IFS= read -r skill_name; do
    [ -z "$skill_name" ] && continue

    skill_dir="${SKILLS_ROOT}/$(sanitize_skill_dir "$skill_name")"
    skill_url="https://raw.githubusercontent.com/${repo_slug}/main/skills/${skill_name}/SKILL.md"

    mkdir -p "$skill_dir"

    echo "    - $skill_name"

    if curl -fsSL "$skill_url" -o "${skill_dir}/SKILL.md"; then
      installed_count=$((installed_count + 1))
    else
      rm -f "${skill_dir}/SKILL.md"
      rmdir "$skill_dir" 2>/dev/null || true
      echo "      ⚠️ 下载失败: ${skill_url}"
    fi
  done <<< "$skill_names"

  [ "$installed_count" -gt 0 ]
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
  local repo_input
  local repo_slug

  echo "👉 安装默认 skills..."

  while IFS= read -r repo_input; do
    repo_input=$(printf '%s' "$repo_input" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [ -z "$repo_input" ] || [[ "$repo_input" = \#* ]]; then
      continue
    fi

    repo_slug=$(extract_repo_slug "$repo_input")

    if ! printf '%s' "$repo_slug" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
      echo "  - $repo_input"
      echo "    ⚠️ 这一行不是合法的 GitHub repo 地址，已跳过"
      fail_count=$((fail_count + 1))
      continue
    fi

    echo "  - ${repo_slug}"

    if install_repo_skills "$repo_slug"; then
      success_count=$((success_count + 1))
    else
      echo "    ⚠️ 未能从 ${repo_slug} 安装任何 skill，已跳过"
      fail_count=$((fail_count + 1))
    fi
  done <<< "$SKILLS_CONTENT"

  echo "✅ skills 安装完成，成功仓库: ${success_count}，失败仓库: ${fail_count}"
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
