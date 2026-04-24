#!/usr/bin/env bash

set -euo pipefail

BASE_URL=""
API_KEY=""
MODEL=""

usage() {
  cat <<EOF
用法: $0 [-b BASE_URL] [-k API_KEY] [-m MODEL] [-h]

参数:
  -b <BASE_URL>   写入 ANTHROPIC_BASE_URL
  -k <API_KEY>    写入 ANTHROPIC_API_KEY
  -m <MODEL>      写入 ANTHROPIC_DEFAULT_OPUS_MODEL
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
  sudo apt-get install -y --no-upgrade curl ca-certificates
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

install_claude_code() {
  if command -v claude >/dev/null 2>&1; then
    echo "✅ Claude Code 已安装: $(command -v claude)"
    return
  fi

  echo "👉 安装 Claude Code..."
  curl -fsSL https://claude.ai/install.sh | bash

  if command -v claude >/dev/null 2>&1; then
    echo "✅ Claude Code 安装成功: $(command -v claude)"
    return
  fi

  source_shell_config

  if command -v claude >/dev/null 2>&1; then
    echo "✅ Claude Code 安装成功: $(command -v claude)"
    return
  fi

  echo "❌ Claude Code 安装后仍未找到命令，请检查安装输出"
  exit 1
}

upsert_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  [ -z "$value" ] && return

  touch "$file"

  if grep -q "^export ${key}=" "$file"; then
    python - "$file" "$key" "$value" <<'PY'
import sys
path, key, value = sys.argv[1:4]
with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
with open(path, 'w', encoding='utf-8') as f:
    replaced = False
    for line in lines:
        if line.startswith(f'export {key}=') and not replaced:
            f.write(f'export {key}="{value}"\n')
            replaced = True
        else:
            f.write(line)
    if not replaced:
        f.write(f'export {key}="{value}"\n')
PY
  else
    printf 'export %s="%s"\n' "$key" "$value" >> "$file"
  fi
}

write_env_vars() {
  local shell_file="${HOME}/.bashrc"

  if [ ! -f "$shell_file" ] && [ -f "${HOME}/.bash_profile" ]; then
    shell_file="${HOME}/.bash_profile"
  fi

  echo "👉 写入环境变量..."
  upsert_env_var "$shell_file" "ANTHROPIC_BASE_URL" "$BASE_URL"
  upsert_env_var "$shell_file" "ANTHROPIC_API_KEY" "$API_KEY"
  upsert_env_var "$shell_file" "ANTHROPIC_DEFAULT_OPUS_MODEL" "$MODEL"
}

verify_installation() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "❌ 当前 shell 中未找到 claude 命令"
    exit 1
  fi

  echo "👉 验证安装..."
  claude --version
}

while getopts "b:k:m:h" opt; do
  case "$opt" in
    b) BASE_URL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
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

require_linux_apt
install_dependencies
install_claude_code
write_env_vars
source_shell_config
verify_installation

echo "✅ 脚本执行完成"
echo "👉 如果当前终端仍然识别不到 claude，请手动执行: source ~/.bashrc"
echo "👉 已将 ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY / ANTHROPIC_DEFAULT_OPUS_MODEL 写入 ~/.bashrc，重启后仍然生效"
