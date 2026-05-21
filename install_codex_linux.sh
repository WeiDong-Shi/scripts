#!/usr/bin/env bash

# install_codex_linux_no_env.sh
# Install Codex CLI on Ubuntu/Debian and write API settings to config.toml.

set -euo pipefail

MODEL="gpt-5.1-codex"
INSTALL_SKILLS=false

show_help() {
  cat <<'EOF'
用法: install_codex_linux_no_env.sh -b BASE_URL -k API_KEY [-m MODEL] [-s] [-h]
  -b  OpenAI-compatible 中转地址，例如 https://api.example.com/v1
  -k  API Key
  -m  模型名，默认: gpt-5.1-codex
  -s  安装默认 Codex skills，可选，从当前目录 skills.txt 读取 Git 仓库地址
  -h  显示帮助
EOF
}

is_root() {
  [ "$(id -u)" -eq 0 ]
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "缺少命令: $1"
    exit 1
  fi
}

detect_debian_like() {
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      debian:*|ubuntu:*|*:debian*|*:ubuntu*) return 0 ;;
    esac
  fi

  return 1
}

node_major_version() {
  node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1
}

install_node_root() {
  detect_debian_like || {
    echo "当前脚本仅支持 Ubuntu/Debian 自动安装 Node.js 22"
    exit 1
  }

  echo "安装 Node.js 22 (root/apt)..."
  need_cmd apt-get
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  need_cmd curl
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

install_node_user() {
  need_cmd curl

  echo "安装 Node.js 22 (非 root/nvm)..."
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi

  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"

  nvm install 22
  nvm use 22
  nvm alias default 22
}

ensure_node_22() {
  if command -v node >/dev/null 2>&1 && [ "$(node_major_version)" = "22" ] && command -v npm >/dev/null 2>&1; then
    echo "检测到 Node.js $(node -v)，跳过 Node.js 安装"
    return 0
  fi

  if is_root; then
    install_node_root
  else
    install_node_user
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "Node.js 安装失败: 未找到 node 命令"
    exit 1
  fi

  if [ "$(node_major_version)" != "22" ]; then
    echo "Node.js 22 安装失败，当前版本: $(node -v 2>/dev/null || echo unavailable)"
    exit 1
  fi

  need_cmd npm
  echo "Node.js 版本: $(node -v)"
  echo "npm 版本: $(npm -v)"
}

ensure_user_path() {
  mkdir -p "$HOME/.local/bin"
  export PATH="$HOME/.local/bin:$PATH"

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  local profile

  for profile in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$profile"
    if ! grep -F "$path_line" "$profile" >/dev/null 2>&1; then
      printf '\n%s\n' "$path_line" >> "$profile"
    fi
  done
}

install_codex() {
  need_cmd npm

  echo "安装 Codex CLI..."
  if is_root; then
    npm install -g @openai/codex
  else
    ensure_user_path
    npm install --prefix "$HOME/.local" -g @openai/codex
  fi

  if ! command -v codex >/dev/null 2>&1; then
    echo "Codex 安装后未在 PATH 中找到"
    exit 1
  fi

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

  model_escaped="$(toml_escape "$MODEL")"
  base_url_escaped="$(toml_escape "$BASE_URL")"
  api_key_escaped="$(toml_escape "$API_KEY")"

  umask 077
  cat > "$config_file" <<EOF
profile = "default"
model = "$model_escaped"
model_provider = "proxy"

[model_providers.proxy]
name = "OpenAI-compatible proxy"
base_url = "$base_url_escaped"
wire_api = "responses"
experimental_bearer_token = "$api_key_escaped"
EOF

  chmod 600 "$config_file"
  echo "Codex 配置写入 $config_file"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

install_skills() {
  [ "$INSTALL_SKILLS" = true ] || return 0

  if [ ! -f "skills.txt" ]; then
    echo "未找到 skills.txt，跳过 skills 安装"
    return 0
  fi

  need_cmd git

  local skills_dir="$HOME/.agents/skills"
  local skill
  local clean_skill
  local name
  local target

  mkdir -p "$skills_dir"

  echo "安装 skills..."
  while IFS= read -r skill || [ -n "$skill" ]; do
    skill="${skill%%#*}"
    skill="$(trim "$skill")"
    [ -n "$skill" ] || continue

    clean_skill="${skill%/}"
    name="$(basename "$clean_skill" .git)"
    target="$skills_dir/$name"

    if [ -e "$target" ]; then
      echo "skill 已存在，跳过: $target"
      continue
    fi

    echo "安装 skill: $skill"
    git clone "$skill" "$target"
  done < skills.txt
}

main() {
  OPTIND=1

  while getopts "b:k:m:sh" opt; do
    case "$opt" in
      b) BASE_URL="$OPTARG" ;;
      k) API_KEY="$OPTARG" ;;
      m) MODEL="$OPTARG" ;;
      s) INSTALL_SKILLS=true ;;
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
    echo "必须提供 -b BASE_URL 和 -k API_KEY"
    show_help
    exit 1
  fi

  ensure_node_22
  install_codex
  write_codex_config
  install_skills

  echo "安装完成，可直接运行 codex"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
