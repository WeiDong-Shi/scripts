#!/usr/bin/env bash

set -euo pipefail

MODEL=""
INSTALL_SKILLS=false
SKILLS_LIST_URL="https://raw.githubusercontent.com/WeiDong-Shi/scripts/main/skills.txt"

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"

if [[ "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
else
  SCRIPT_DIR="$(pwd)"
fi

show_help() {
  cat <<'EOF'
用法: install_codex_linux.sh -b BASE_URL -k API_KEY [-m MODEL] [-s] [-h]

  -b  OpenAI-compatible 中转地址，例如:
      https://api.example.com/v1

  -k  API Key

  -m  模型名，可选；
      不传则不写入 model，让 Codex 使用默认模型

  -s  安装默认 Codex skills
      从远程默认 skills.txt 读取 SKILL.md 地址并安装到 Codex 默认目录

  -h  显示帮助

示例:

  bash install_codex_linux.sh \
    -b https://api.example.com/v1 \
    -k sk-xxxxx

  curl -fsSL https://example.com/install.sh | bash -s -- \
    -b https://api.example.com/v1 \
    -k sk-xxxxx \
    -s
EOF
}

fail() {
  echo "$1" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少命令: $1"
  fi
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

detect_debian_like() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release

    case "${ID:-}:${ID_LIKE:-}" in
      debian:*|ubuntu:*|*:debian*|*:ubuntu*)
        return 0
        ;;
    esac
  fi

  return 1
}

ensure_dependencies() {
  echo "检查系统依赖..."

  detect_debian_like || fail "当前脚本仅支持 Ubuntu/Debian 自动安装依赖"

  if command -v curl >/dev/null 2>&1 &&
     command -v jq >/dev/null 2>&1 &&
     command -v tar >/dev/null 2>&1 &&
     command -v unzip >/dev/null 2>&1 &&
     command -v git >/dev/null 2>&1 &&
     command -v bwrap >/dev/null 2>&1; then
    echo "系统依赖已满足"
    return 0
  fi

  echo "安装缺失依赖: curl jq git ca-certificates tar unzip bubblewrap"

  if is_root; then
    apt-get update
    apt-get install -y --no-upgrade \
      curl \
      jq \
      git \
      ca-certificates \
      tar \
      unzip \
      bubblewrap
  else
    need_cmd sudo

    sudo apt-get update
    sudo apt-get install -y --no-upgrade \
      curl \
      jq \
      git \
      ca-certificates \
      tar \
      unzip \
      bubblewrap
  fi
}

ensure_user_path() {
  echo "配置用户 PATH: $HOME/.local/bin"

  mkdir -p "$HOME/.local/bin"

  export PATH="$HOME/.local/bin:$PATH"

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local profile

  for profile in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$profile"

    if ! grep -F "$path_line" "$profile" >/dev/null 2>&1; then
      printf '\n%s\n' "$path_line" >> "$profile"
      echo "已写入 PATH 到: $profile"
    fi
  done
}

asset_arch_name() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf '%s' 'x86_64'
      ;;

    aarch64|arm64)
      printf '%s' 'aarch64'
      ;;

    *)
      fail "不支持的架构: $(uname -m)"
      ;;
  esac
}

find_codex_asset_url() {
  local arch_name

  arch_name="$(asset_arch_name)"

  curl -fsSL \
    "https://api.github.com/repos/openai/codex/releases/latest" |
    jq -r \
      --arg name "codex-${arch_name}-unknown-linux-musl.tar.gz" '
      .assets[]
      | select(.name == $name)
      | .browser_download_url
    ' |
    head -n 1
}

copy_codex_binary_from_dir() {
  local source_dir="$1"
  local install_path="$2"
  local found

  found="$(
    find "$source_dir" \
      -type f \
      \( -name codex -o -name 'codex-*unknown-linux-musl' \) \
      -perm /111 |
      head -n 1
  )"

  if [ -z "$found" ]; then
    found="$(
      find "$source_dir" \
        -type f \
        \( -name codex -o -name 'codex-*unknown-linux-musl' \) |
        head -n 1
    )"
  fi

  [ -n "$found" ] || return 1

  echo "找到 Codex 二进制: $(basename "$found")"

  cp "$found" "$install_path"
}

install_codex_binary() {
  local asset_url
  local tmp_dir
  local asset_file
  local install_dir
  local install_path
  local arch_name
  local asset_name

  if command -v codex >/dev/null 2>&1; then
    echo "检测到 Codex: $(codex --version)"
    return 0
  fi

  arch_name="$(asset_arch_name)"
  asset_name="codex-${arch_name}-unknown-linux-musl.tar.gz"

  echo "检测到系统架构: $arch_name"
  echo "查询 Codex 最新 release..."
  echo "匹配 Codex 安装包: $asset_name"

  asset_url="$(find_codex_asset_url)"

  if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
    fail "未找到 Codex 安装包: $asset_name"
  fi

  tmp_dir="$(mktemp -d)"

  asset_file="$tmp_dir/codex_asset"

  install_dir="$HOME/.local/bin"
  install_path="$install_dir/codex"

  echo "下载 Codex: $asset_url"

  curl -fL "$asset_url" -o "$asset_file"

  mkdir -p "$install_dir"

  echo "安装目录: $install_dir"

  case "$asset_url" in
    *.tar.gz|*.tgz)
      echo "解压 Codex 安装包..."

      tar -xzf "$asset_file" -C "$tmp_dir"

      copy_codex_binary_from_dir \
        "$tmp_dir" \
        "$install_path" ||
        fail "解压后未找到 Codex 二进制"

      ;;

    *.zip)
      echo "解压 Codex 安装包..."

      unzip -q "$asset_file" -d "$tmp_dir"

      copy_codex_binary_from_dir \
        "$tmp_dir" \
        "$install_path" ||
        fail "解压后未找到 Codex 二进制"

      ;;

    *)
      cp "$asset_file" "$install_path"
      ;;
  esac

  chmod +x "$install_path"

  export PATH="$install_dir:$PATH"

  if ! command -v codex >/dev/null 2>&1; then
    fail "Codex 已安装，但 PATH 中找不到"
  fi

  rm -rf "$tmp_dir"

  echo "Codex 版本: $(codex --version)"
}

toml_escape() {
  local value="$1"

  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}

  printf '%s' "$value"
}

write_codex_config() {
  local config_dir="$HOME/.codex"
  local config_file="$config_dir/config.toml"
  local backup_file

  local model_escaped
  local base_url_escaped
  local api_key_escaped

  mkdir -p "$config_dir"

  chmod 700 "$config_dir"

  if [ -f "$config_file" ]; then
    backup_file="$config_file.bak.$(date +%Y%m%d%H%M%S)"

    cp "$config_file" "$backup_file"

    chmod 600 "$backup_file"

    echo "已备份已有配置: $backup_file"
  fi

  base_url_escaped="$(toml_escape "$BASE_URL")"
  api_key_escaped="$(toml_escape "$API_KEY")"

  echo "写入 Codex 配置: $config_file"

  if [ -n "$MODEL" ]; then
    echo "配置模型: $MODEL"
  else
    echo "未指定模型，跳过 model 配置"
  fi

  umask 077

  {
    if [ -n "$MODEL" ]; then
      model_escaped="$(toml_escape "$MODEL")"

      printf 'model = "%s"\n' "$model_escaped"
    fi

    echo 'ask_for_approval = "never"'
    echo 'sandbox_mode = "danger-full-access"'
    echo 'model_provider = "proxy"'
    echo
    echo '[model_providers.proxy]'
    echo 'name = "OpenAI-compatible proxy"'

    printf 'base_url = "%s"\n' "$base_url_escaped"

    echo 'wire_api = "responses"'

    printf 'experimental_bearer_token = "%s"\n' "$api_key_escaped"

    echo
    echo '[tui]'
    echo 'status_line = ["model-with-reasoning", "current-dir", "git-branch", "context-used"]'

  } > "$config_file"

  chmod 600 "$config_file"

  echo "Codex 配置写入: $config_file"
}

trim() {
  local value="$1"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "$value"
}

install_skills() {
  [ "$INSTALL_SKILLS" = true ] || return 0

  local skills_dir="${CODEX_HOME:-$HOME/.codex}/skills"
  local skill_url
  local skill_name
  local skill_dir
  local skill_file

  mkdir -p "$skills_dir"

  echo "下载默认 skills 列表..."

  while IFS= read -r skill_url || [ -n "$skill_url" ]; do
    skill_url="${skill_url%%#*}"
    skill_url="${skill_url%$'\r'}"
    skill_url="$(trim "$skill_url")"

    [ -n "$skill_url" ] || continue

    case "$skill_url" in
      */skills/*/SKILL.md)
        skill_name="${skill_url%/SKILL.md}"
        skill_name="${skill_name##*/}"
        ;;
      *)
        fail "skills 列表包含无效条目: $skill_url"
        ;;
    esac

    skill_dir="$skills_dir/$skill_name"
    skill_file="$skill_dir/SKILL.md"

    mkdir -p "$skill_dir"

    echo "安装 Codex skill: $skill_name"

    curl -fsSL "$skill_url" -o "$skill_file"
  done < <(curl -fsSL "$SKILLS_LIST_URL")
}

main() {
  OPTIND=1

  while getopts "b:k:m:sh" opt; do
    case "$opt" in
      b)
        BASE_URL="$OPTARG"
        ;;

      k)
        API_KEY="$OPTARG"
        ;;

      m)
        MODEL="$OPTARG"
        ;;

      s)
        INSTALL_SKILLS=true
        ;;

      h)
        show_help
        exit 0
        ;;

      *)
        show_help
        exit 1
        ;;
    esac
  done

  if [ -z "${BASE_URL:-}" ] || [ -z "${API_KEY:-}" ]; then
    echo "必须提供:"
    echo "  -b BASE_URL"
    echo "  -k API_KEY"
    echo

    show_help

    exit 1
  fi

  ensure_dependencies
  ensure_user_path
  install_codex_binary
  write_codex_config
  install_skills

  echo
  echo "安装完成，可直接运行:"
  echo
  echo "  codex"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" || "$0" == "bash" ]]; then
  main "$@"
fi
