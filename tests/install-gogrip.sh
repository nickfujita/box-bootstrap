#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/box-bootstrap-gogrip-test.XXXXXX)"
trap 'rm -r "$TEST_DIR"' EXIT

uname() {
  if [ "${1:-}" = "-m" ]; then
    printf '%s\n' aarch64
    return
  fi
  command uname "$@"
}

curl() {
  local url="" output=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -o)
        output="$2"
        shift 2
        ;;
      -*) shift ;;
      *)
        url="$1"
        shift
        ;;
    esac
  done

  printf '%s\n' "$url" >> "$GOGRIP_TEST_DOWNLOADS"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$output"
}

systemctl() { return 0; }
sudo() { return 0; }

export -f uname curl systemctl sudo

run_install() {
  local case_name="$1"
  local home_dir="${TEST_DIR}/${case_name}/home"
  local downloads="${TEST_DIR}/${case_name}/downloads"

  mkdir -p "$home_dir"
  : > "$downloads"

  HOME="$home_dir" \
    USER=dev \
    GOGRIP_TEST_DOWNLOADS="$downloads" \
    bash "$ROOT_DIR/install.sh" --gogrip >/dev/null

  if ! grep -Fxq 'https://github.com/nickfujita/go-grip/releases/latest/download/go-grip-linux-arm64' "$downloads"; then
    printf 'expected ARM64 release download, got:\n' >&2
    sed 's/^/  /' "$downloads" >&2
    return 1
  fi
}

run_install fresh

broken_home="${TEST_DIR}/repair/home"
mkdir -p "$broken_home/.local/bin"
printf '#!/usr/bin/env bash\nexit 126\n' > "$broken_home/.local/bin/go-grip"
chmod +x "$broken_home/.local/bin/go-grip"
run_install repair

"$broken_home/.local/bin/go-grip" --help
printf 'gogrip ARM64 install tests passed\n'
