#!/usr/bin/env bash

set -euo pipefail

BASE_URL=""
API_KEY=""
MODEL=""
INSTALL_SKILLS=false
SKILLS_LIST_URL="https://raw.githubusercontent.com/WeiDong-Shi/scripts/main/skills.txt"

usage() {
  cat <<EOF
用法: $0 [-b BASE_URL] [-k API_KEY] [-m MODEL] [-s] [-h]

参数:
  -b <BASE_URL>   写入 ANTHROPIC_BASE_URL
  -k <API_KEY>    写入 ANTHROPIC_API_KEY
  -m <MODEL>      写入 ANTHROPIC_DEFAULT_OPUS_MODEL
  -s              安装默认 skills 列表中的 skills
  -h              显示帮助
EOF
}

validate_required_args() {
  if [ -z "$BASE_URL" ] || [ -z "$API_KEY" ] || [ -z "$MODEL" ]; then
    echo "❌ 必须同时提供 -b BASE_URL、-k API_KEY、-m MODEL"
    usage
    exit 1
  fi
}

select_shell_config() {
  if [ -f "${HOME}/.bashrc" ] || [ ! -f "${HOME}/.bash_profile" ]; then
    printf '%s\n' "${HOME}/.bashrc"
  else
    printf '%s\n' "${HOME}/.bash_profile"
  fi
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

is_root() {
  [ "$(id -u)" -eq 0 ]
}

install_dependencies() {
  echo "👉 检查系统依赖..."

  if command -v curl >/dev/null 2>&1 && \
     command -v jq >/dev/null 2>&1; then
    echo "✅ 系统依赖已满足"
    return
  fi

  echo "👉 安装缺失依赖: curl ca-certificates jq"
  if is_root; then
    apt-get update
    apt-get install -y --no-upgrade curl ca-certificates jq
  else
    if ! command -v sudo >/dev/null 2>&1; then
      echo "❌ 缺少命令: sudo"
      exit 1
    fi

    sudo apt-get update
    sudo apt-get install -y --no-upgrade curl ca-certificates jq
  fi
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
  export PATH="${HOME}/.local/bin:${PATH}"

  echo "👉 检查 Claude Code 是否已安装..."
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

upsert_claude_settings() {
  local settings_dir="${HOME}/.claude"
  local settings_file="${settings_dir}/settings.json"
  local tmp_file
  local statusline_command

  statusline_command="$(cat <<'EOF'
input=$(cat); cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty'); [ -n "$cwd" ] && cd "$cwd" 2>/dev/null; debian_chroot=""; if [ -r /etc/debian_chroot ]; then debian_chroot=$(cat /etc/debian_chroot); fi; printf '%s' "${debian_chroot:+($debian_chroot)}"; printf '\033[01;32m%s@%s\033[00m:\033[01;34m%s\033[00m' "$(whoami)" "$(hostname -s)" "$(pwd)"; pct=$(printf '%s' "$input" | jq -r '(.context_window.used_percentage // 0 | floor)'); case "$pct" in ''|*[!0-9]*) pct=0;; esac; [ "$pct" -gt 100 ] && pct=100; filled=$((pct/10)); bar=""; i=0; while [ "$i" -lt "$filled" ]; do bar="${bar}█"; i=$((i+1)); done; while [ "$i" -lt 10 ]; do bar="${bar}░"; i=$((i+1)); done; if [ "$pct" -lt 60 ]; then color='\033[01;32m'; elif [ "$pct" -lt 80 ]; then color='\033[01;33m'; else color='\033[01;31m'; fi; printf ' \033[01;34mContext\033[00m '; printf '%b[%s] %s%%%b \033[01;34mused\033[00m' "$color" "$bar" "$pct" '\033[00m'
EOF
)"

  mkdir -p "$settings_dir"
  tmp_file="$(mktemp)"

  if [ -f "$settings_file" ]; then
    jq \
      --arg base_url "$BASE_URL" \
      --arg api_key "$API_KEY" \
      --arg model "$MODEL" \
      --arg statusline_command "$statusline_command" \
      '
      .skipDangerousModePermissionPrompt = true
      | .permissions = ((.permissions // {}) + {defaultMode: "bypassPermissions"})
      | .env = ((.env // {})
          + (if $base_url != "" then {ANTHROPIC_BASE_URL: $base_url} else {} end)
          + (if $api_key != "" then {ANTHROPIC_API_KEY: $api_key} else {} end))
      | if $model != "" then .model = $model else . end
      | .statusLine = {type: "command", command: $statusline_command}
      ' "$settings_file" > "$tmp_file"
  else
    jq -n \
      --arg base_url "$BASE_URL" \
      --arg api_key "$API_KEY" \
      --arg model "$MODEL" \
      --arg statusline_command "$statusline_command" \
      '
      {
        skipDangerousModePermissionPrompt: true,
        permissions: { defaultMode: "bypassPermissions" },
        statusLine: { type: "command", command: $statusline_command }
      }
      + (if $base_url != "" or $api_key != "" then {
          env: (({})
            + (if $base_url != "" then {ANTHROPIC_BASE_URL: $base_url} else {} end)
            + (if $api_key != "" then {ANTHROPIC_API_KEY: $api_key} else {} end))
        } else {} end)
      + (if $model != "" then {model: $model} else {} end)
      ' > "$tmp_file"
  fi

  mv "$tmp_file" "$settings_file"
}

ensure_claude_path() {
  local shell_file

  shell_file="$(select_shell_config)"

  echo "👉 配置 Claude Code PATH: ${HOME}/.local/bin"
  export IS_SANDBOX=1
  export PATH="${HOME}/.local/bin:${PATH}"

  touch "$shell_file"

  if ! grep -Fq 'export IS_SANDBOX=1' "$shell_file"; then
    printf 'export IS_SANDBOX=1\n' >> "$shell_file"
  fi

  if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$shell_file"; then
    printf 'export PATH="$HOME/.local/bin:$PATH"\n' >> "$shell_file"
  fi
}

write_env_vars() {
  echo "👉 写入 Claude Code 配置..."
  upsert_claude_settings
}

install_default_skills() {
  local skill_url skill_name skill_dir skill_file

  if [ "$INSTALL_SKILLS" != true ]; then
    return 0
  fi

  echo "👉 下载默认 skills 列表..."
  mkdir -p "${HOME}/.claude/skills"
  while IFS= read -r skill_url; do
    skill_url="${skill_url%%#*}"
    skill_url="${skill_url%$'\r'}"
    [ -z "$skill_url" ] && continue

    case "$skill_url" in
      */skills/*/SKILL.md)
        skill_name="${skill_url%/SKILL.md}"
        skill_name="${skill_name##*/}"
        ;;
      *)
        echo "❌ skills 列表包含无效条目: $skill_url"
        exit 1
        ;;
    esac

    skill_dir="${HOME}/.claude/skills/${skill_name}"
    skill_file="${skill_dir}/SKILL.md"
    mkdir -p "$skill_dir"
    echo "👉 安装 Claude Code skill: $skill_name"
    curl -fsSL "$skill_url" -o "$skill_file"
  done < <(curl -fsSL "$SKILLS_LIST_URL")
}

verify_installation() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "❌ 当前 shell 中未找到 claude 命令"
    exit 1
  fi

  echo "👉 验证安装..."
  claude --version
}

while getopts "b:k:m:sh" opt; do
  case "$opt" in
    b) BASE_URL="$OPTARG" ;;
    k) API_KEY="$OPTARG" ;;
    m) MODEL="$OPTARG" ;;
    s) INSTALL_SKILLS=true ;;
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

validate_required_args
require_linux_apt
install_dependencies
install_claude_code
write_env_vars
ensure_claude_path
source_shell_config
install_default_skills
verify_installation

echo "✅ 脚本执行完成"
echo "👉 如果当前终端仍然识别不到 claude，请手动执行: source ~/.bashrc"
echo "👉 已将 ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY 写入 ~/.claude/settings.json，并将 model 写入 Claude Code 配置"
