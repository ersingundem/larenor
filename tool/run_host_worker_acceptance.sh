#!/usr/bin/env bash
# Execute committed host proofs in a public, isolated source/runtime tree.
# Household devices and the runner's checkout/home remain inaccessible.
set -euo pipefail
test "${CI:-}" = true
test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test "$(uname -s)" = Linux
test "$#" -eq 1
uv_bin="$1"
test -x "$uv_bin"
proof_root="$(mktemp -d /tmp/larenor-host-proof.XXXXXX)"
trap 'rm -rf -- "$proof_root"' EXIT
chmod 0755 "$proof_root"
source_revision="$(git rev-parse HEAD)"
git archive HEAD | tar -xf - -C "$proof_root"
export UV_PYTHON_INSTALL_DIR=/tmp/larenor-host-proof-python
export UV_PROJECT_ENVIRONMENT="$proof_root/server/.venv"
"$uv_bin" sync --locked --no-editable --project "$proof_root/server" --python 3.12.14
chmod -R a+rX "$UV_PYTHON_INSTALL_DIR" "$UV_PROJECT_ENVIRONMENT"
cd "$proof_root"
case "$(uname -m)" in
  x86_64) package_platform=linux/amd64 ;;
  aarch64) package_platform=linux/arm64 ;;
  *) exit 2 ;;
esac
python_bin="$("$uv_bin" python find 3.12.14)"
"$UV_PROJECT_ENVIRONMENT/bin/python" server/tests/support/host_worker_package_linux.py \
  --root "$proof_root" --work "$proof_root/host-package" --uv "$uv_bin" \
  --python "$python_bin" --source-revision "$source_revision" \
  --platform "$package_platform"
sudo --non-interactive env -i PATH=/usr/bin:/bin PYTHONPATH="$proof_root/server" \
  CI=true GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted \
  LARENOR_HOST_WORKER_SYSTEMD_ACCEPTANCE=1 \
  LARENOR_HOST_WORKER_BUNDLE="$proof_root/host-package/bundle/bundle.json" \
  LARENOR_HOST_WORKER_PYTHON="$python_bin" \
  LARENOR_HOST_WORKER_SOURCE_REVISION="$source_revision" \
  "$UV_PROJECT_ENVIRONMENT/bin/python" -B -m pytest -q -p no:cacheprovider \
  server/tests/test_media_archive_linux_uid_ipc.py \
  server/tests/test_host_worker_systemd_linux.py
