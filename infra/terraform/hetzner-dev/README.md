# Hetzner dev box (pods-dev)

One Hetzner Cloud VPS (`cpx11`, Ubuntu 24.04, `ash`) running Pods via Docker
Compose behind Caddy (automatic HTTPS), with DNS at `pods-dev.mcgiv.dev`
through Route 53.

## Secrets and credentials

- **Hetzner token**: `op://Private/hetzner_podcasts_token/token` — exported as
  `TF_VAR_hcloud_token`, never written to disk.
- **AWS / Route 53**: profile `bosque-chat-admin` (1Password
  `credential_process`; mcgiv.dev's zone `Z0115995336TMVXI5W90N` always lives in
  this account).
- **App secrets**: `/opt/pods/app/.env` on the box (gitignored), populated over
  SSH from 1Password — see below. Never in Terraform, cloud-init, or the repo.

## Provision

```sh
cd infra/terraform/hetzner-dev
cp terraform.tfvars.example terraform.tfvars   # fill in ssh_public_key
export TF_VAR_hcloud_token="$(op read 'op://Private/hetzner_podcasts_token/token')"
terraform init
terraform plan
terraform apply
```

Cloud-init needs a few minutes after apply (Docker install, swap, hardening).
`ssh matt@pods-dev.mcgiv.dev sudo cloud-init status --wait` blocks until done.

## Deploy the app

```sh
HOST=matt@pods-dev.mcgiv.dev

# 1. Clone via read-only deploy key (key generated on the box, registered with
#    `gh repo deploy-key add` from a trusted machine).
ssh $HOST 'git clone git@github.com:mattmcgiv/podcasts.git /opt/pods/app'

# 2. Populate secrets without putting values in argv or history:
{
  printf 'API_TOKEN=';            op read 'op://Private/pods_dev_api_token/token'; \
  printf 'PODCASTINDEX_KEY=';     op read 'op://Private/Podcastindex/API KEY'; \
  printf 'PODCASTINDEX_SECRET=';  op read 'op://Private/Podcastindex/API SECRET'; \
  printf 'PODS_HOSTNAME=pods-dev.mcgiv.dev\n'; \
} | ssh $HOST 'umask 077; cat > /opt/pods/app/.env'

# 3. Build and start (also the command after any git pull):
ssh $HOST pods-dev-up
```

## Day-2

- SSH lands in tmux session `main` (guarded auto-attach; bypass with
  `ssh -t HOST 'TMUX_AUTOATTACH=0 bash -l'`).
- Update app: `ssh $HOST 'cd /opt/pods/app && git pull && pods-dev-up'`
- Logs: `ssh $HOST 'cd /opt/pods/app && docker compose logs -f pods'`
- SQLite data lives in the `pods-data` Docker volume; OPML export is the
  cheap backup.
- Tear down: `terraform destroy` (DNS record included).

## Validation

```sh
terraform fmt -check -diff
terraform init -backend=false
terraform validate
scripts/verify-cloud-init.sh
API_TOKEN=placeholder docker compose config   # from repo root
```
