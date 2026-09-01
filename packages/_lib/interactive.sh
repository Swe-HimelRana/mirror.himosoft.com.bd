# Himosoft interactive helpers — sourced by package CLIs.
# Do not auto-apply values; always prompt the operator.

hs_prompt() {
  local var_name="$1" question="$2"
  local input
  read -r -p "${question}: " input
  printf -v "${var_name}" '%s' "${input}"
}

hs_prompt_secret() {
  local var_name="$1" question="$2"
  local input
  read -r -s -p "${question}: " input
  echo ""
  printf -v "${var_name}" '%s' "${input}"
}

hs_prompt_optional() {
  local var_name="$1" question="$2"
  local input
  read -r -p "${question} (optional): " input
  printf -v "${var_name}" '%s' "${input}"
}

hs_confirm() {
  local question="$1"
  local reply
  read -r -p "${question} [y/N]: " reply
  [[ "${reply}" =~ ^[Yy]$ ]]
}

hs_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root: sudo $0"
    exit 1
  fi
}

hs_banner() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║  $1"
  echo "╚══════════════════════════════════════════╝"
  echo ""
}
