#!/usr/bin/env bash
# Isolated shell tests. No network, AWS credentials, services, or root needed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -r "$TEST_DIR"' EXIT

# Load definitions and option parsing without running main.
load_installer() {
  source <(sed '$d' "$ROOT_DIR/install.sh")
}

(
  load_installer --aws
  [ "$DO_AWS" = 1 ] && [ "$DO_TAILSCALE" = 0 ] && [ "$DO_NEOVIM" = 0 ]
)
(
  load_installer --with-aws
  [ "$DO_AWS" = 1 ] && [ "$DO_TAILSCALE" = 1 ] && [ "$DO_NEOVIM" = 1 ]
)
(
  load_installer --all
  [ "$DO_AWS" = 1 ]
)

for architecture in x86_64 aarch64; do
  (
    load_installer --aws
    marker="$TEST_DIR/$architecture"
    calls="$marker.calls"
    : > "$calls"
    SUDO=sudo
    uname() { printf '%s\n' "$architecture"; }
    have_cmd() { [ "$1" != gpg ]; }
    apt-get() { printf 'apt %s\n' "$*" >> "$calls"; }
    sudo() { printf 'sudo %s\n' "$1" >> "$calls"; "$@"; }
    curl() {
      [ "$*" = "-fsSL https://awscli.amazonaws.com/v2/install.sh -o $4" ]
      printf 'download\n' >> "$calls"
      printf '# fixture installer\n' > "$4"
    }
    bash() {
      [ -s "$1" ] && [ "$2" = --system ] && [ "$#" = 2 ]
      printf 'install\n' >> "$calls"
      touch "$marker"
    }
    aws() {
      [ "$*" = --version ] || return 99
      [ -f "$marker" ] || return 127
      printf 'aws-cli/2.99.0 fixture\n'
    }
    if check_aws >/dev/null 2>&1; then exit 1; fi
    install_aws
    check_aws
    grep -qx 'sudo bash' "$calls"
    grep -qx 'apt install -y gnupg' "$calls"
    before="$(cat "$calls")"
    install_aws
    [ "$(cat "$calls")" = "$before" ]
    # Reject a v1 command shadowing v2 on the invoking user's PATH.
    aws() {
      if [ "$PATH" = /usr/local/bin:/usr/bin:/bin ]; then
        printf 'aws-cli/2.99.0 fixture\n'
      else
        printf 'aws-cli/1.99.0 fixture\n'
      fi
    }
    PATH="/fixture:$PATH"
    if check_aws >/dev/null 2>&1; then exit 1; fi
  )
done
(
  load_installer --aws --check
  check_aws() { return 0; }
  install_aws() { exit 99; }
  main
)
printf 'AWS CLI installer tests passed\n'
