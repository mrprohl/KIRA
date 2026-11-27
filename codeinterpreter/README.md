# Code interpreter for KIRA (own server with KVM)

With the code interpreter KIRA writes small programs and runs them in a sandbox: analyses of uploaded files, exact
calculations, charts, and files the Office tools cannot make (PDF, CSV …). The files appear in the chat for download.

It runs **on an own server, not on the KIRA server**: the sandbox starts a small virtual machine per run and needs
hardware virtualisation (`/dev/kvm`). A VM on Proxmox that itself runs in a cloud VM usually has none. The software is
the open-source [ClickHouse/code-interpreter](https://github.com/ClickHouse/code-interpreter) (Apache 2.0); this
folder only adds KIRA's settings.

```
KIRA server                                   code server (KVM)
LibreChat ──── HTTP(S), signed token ────►    API :3112 ─► worker ─► KVM sandbox (no network, own kernel)
           (Ed25519, valid 5 minutes)                    └► Redis, MinIO, file server (internal only)
```

## Setting up

Requirements: Linux with `/dev/kvm` (`ls -l /dev/kvm`, CPU flags `grep -c -E 'vmx|svm' /proc/cpuinfo` > 0), Docker,
Docker Compose ≥ 2.24, git, openssl, python3. About 8 GB RAM and 30 GB disk.

1. On the KIRA server: `CODE_INTERPRETER=yes` in `setup.sh` with the address of the code server
   (e.g. `http://10.0.0.60:3112`). It generates the key pair; the public key is in `/opt/kira/config/codeapi-jwks.json`.
2. On the code server:
   ```bash
   mkdir -p /opt/codeinterpreter
   # copy compose.kira.yml and setup-codeapi.sh from this folder to /opt/codeinterpreter
   scp root@<KIRA-IP>:/opt/kira/config/codeapi-jwks.json /opt/codeinterpreter/jwks.json
   bash /opt/codeinterpreter/setup-codeapi.sh
   ```
   The script clones the pinned release (`CODEAPI_VERSION`, default v1.9.1), generates all secrets into
   `/opt/codeinterpreter/.env` (600), builds the images (the first build takes 30 minutes or more) and starts them.
3. Firewall of the code server: port 3112 only from the KIRA server, e.g.
   `ufw allow from <KIRA-IP> to any port 3112 proto tcp`.
4. On the KIRA server: `bash /opt/kira/scripts/self-test.sh` – section "Code interpreter".

Over the internet: put a reverse proxy with TLS in front of port 3112 and enter `https://…` in `setup.sh`; still allow
it only from the public IP of the KIRA server.

## What `compose.kira.yml` changes

| Project default (developer mode) | For KIRA |
|---|---|
| `LOCAL_MODE=true` – no login | only tokens signed by KIRA (`librechat-jwt`, EdDSA, public key from `jwks.json`) |
| passwords `localdev`, `minioadmin`, example keys | own secrets, generated into `.env` |
| Redis, MinIO, file server, sandbox, egress gateway published | only the API (`BIND_IP:API_PORT`) |
| | `restart: unless-stopped` for all services |

The hardening of the project stays on: KVM microVM with NsJail inside, seccomp, egress gateway, signed execution
manifests.

## Operation

| What | How |
|---|---|
| Status | `docker compose -p codeinterpreter ps` · `curl http://127.0.0.1:3112/v1/health` |
| Logs | `docker logs --tail 100 api` · `docker logs --tail 100 service-worker` · `docker logs --tail 100 sandbox-runner` |
| Update | `CODEAPI_VERSION=v1.x.y bash /opt/codeinterpreter/setup-codeapi.sh` |
| New key on the KIRA server | copy `codeapi-jwks.json` again to `jwks.json`, run `setup-codeapi.sh` |
| Switch off | `CODE_INTERPRETER=false` in `/opt/kira/env/setup.env`, `bash /opt/kira/setup.sh`; here `docker compose -p codeinterpreter down` |

## Security

- The sandbox runs code that a language model wrote – treat the server as exposed: no other services on it, no
  access to the LAN, keep it patched. Never run it without KVM (`KVM_ENABLED=false` shares the host kernel).
- KIRA's private key never leaves the KIRA server; the code server only knows the public key.
- Files of a chat are copied into the sandbox for a run; results come back to LibreChat and are stored there.
