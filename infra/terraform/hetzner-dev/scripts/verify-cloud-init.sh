#!/bin/sh
# Lightweight red-phase checks for the Terraform root: expected hardening,
# runtime pieces, and no committed secrets.
set -eu

cd "$(dirname "$0")/.."
fail=0
need() {
  if ! grep -q "$1" main.tf; then
    echo "MISSING in main.tf: $1" >&2
    fail=1
  fi
}

need 'PermitRootLogin no'
need 'PasswordAuthentication no'
need 'ssh_pwauth: false'
need 'ufw allow OpenSSH'
need 'ufw allow 80/tcp'
need 'ufw allow 443/tcp'
need 'ufw --force enable'
need 'docker-compose-plugin'
need 'usermod -aG docker'
need 'fail2ban'
need 'unattended-upgrades'
need 'swap:'
need 'pods-dev-up'
need 'aws_route53_record'
need 'tmux'

# No plausible secrets in committed files (tfvars itself is gitignored).
for f in main.tf terraform.tfvars.example README.md; do
  [ -f "$f" ] || continue
  if grep -nE 'AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH )?PRIVATE KEY|hcloud_token *= *"[A-Za-z0-9]{20,}' "$f"; then
    echo "POSSIBLE SECRET COMMITTED in $f" >&2
    fail=1
  fi
done

if [ -f terraform.tfvars ] && git check-ignore -q terraform.tfvars 2>/dev/null; then
  :
elif [ -f terraform.tfvars ]; then
  echo "terraform.tfvars exists but is NOT gitignored" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "verify-cloud-init: OK"
exit "$fail"
