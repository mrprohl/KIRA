# Code interpreter (stack `/opt/codeinterpreter`, optional)

With the code interpreter KIRA writes small Python programs and runs them in a sandbox: calculations, analyses of
uploaded files, charts – and documents. Word, Excel, PowerPoint, PDF or CSV files that the program saves to
`/mnt/data` appear **directly in the chat**: Word, Excel and PowerPoint with a preview in the side panel, every file
with a download button. They are stored in LibreChat like uploads.

The software is the open-source [ClickHouse/code-interpreter](https://github.com/ClickHouse/code-interpreter)
(Apache 2.0). It has no public images: `setup.sh` clones the pinned release into `src/` and builds it. This folder only
adds KIRA's settings.

```
LibreChat ── network kira-code ──► codeapi :3112 ─► worker ─► sandbox: one small VM per run (own kernel, no network)
  signed token per run                              │             └► egress gateway ─► file server ─► MinIO
  (Ed25519, valid 5 minutes)                        └► Redis           (all in codeinterpreter_backend, internal)
```

## Requirements

- **Hardware virtualisation on the KIRA server:** `/dev/kvm` must exist – check with `ls -l /dev/kvm` and
  `grep -c -E 'vmx|svm' /proc/cpuinfo` (> 0). Bare metal, or a VM with nested virtualisation (CPU type `host`).
  An LXC container does not work.
- Docker Compose ≥ 2.24, `git`; about 2 GB RAM per parallel run (`CODE_PARALLEL`, default 4) plus about 2 GB for
  the services, about 30 GB disk for the images.
- For the build: internet (GitHub, Docker Hub, package mirrors). In operation the stack needs no internet.

## Switching on

```bash
nano /opt/kira/env/setup.env          # CODE_INTERPRETER="true" (or answer the question in setup.sh)
bash /opt/kira/setup.sh               # start with "yes" – the first build takes 30 minutes or more
bash /opt/kira/scripts/self-test.sh   # section "Code interpreter": containers, API, a Python run that writes a .docx
```

`setup.sh` then

1. clones `CODEAPI_VERSION` (`env/versions.env`, default v1.9.1) to `src/` and checks its commit (`CODEAPI_COMMIT`),
2. generates the secrets into `env/codeapi.env` (600) and puts the public key of LibreChat there,
3. sets the code interpreter variables in `/opt/kira/env/librechat.env` (private key, `http://codeapi:3112/v1`),
4. switches on code execution for the agents with `CODE=true` (KIRA, Code, Textwerkstatt, Protokoll),
5. builds the images (only when the version changed) and starts the stack before LibreChat,
6. sets the expiry of its storage: files there are deleted after 2 days (they are only used for 24 hours).

In KIRA: "Erstelle eine Word-Datei mit einer Einladung zum Sommerfest" → the `.docx` appears in the chat.

## What `compose.kira.yml` changes

| Project default (developer mode) | For KIRA |
|---|---|
| `LOCAL_MODE=true` – no login | only tokens signed by KIRA (`librechat-jwt`, EdDSA, max. 5 minutes) |
| passwords `localdev`, `minioadmin`, example keys | own secrets, generated into `env/codeapi.env` |
| API, Redis, MinIO, file server, sandbox, egress gateway published on the host | no published ports; LibreChat reaches only the API over `kira-code` |
| default network with internet | `codeinterpreter_backend` internal: no internet, no LAN |
| remote bridge (external sandbox VMs) enabled | off |
| 8 parallel runs | `CODE_PARALLEL` (default 4) |
| container names `api`, `redis`, `minio` … | `codeapi`, `codeapi-redis`, `codeapi-minio` …; restart after reboot, log rotation |
| default capabilities, no limits | `no-new-privileges`, `cap_drop: ALL` and memory limits for the services; the sandbox runner keeps its settings, with a memory limit for all VMs (`CODE_SANDBOX_MEM` = 2 GB × `CODE_PARALLEL` + 1 GB) |

The hardening of the project stays on: KVM microVM with NsJail inside, seccomp, egress gateway, signed execution
manifests.

## Operation

| What | How |
|---|---|
| Status | `bash /opt/codeinterpreter/codeapi.sh ps` |
| Logs | `bash /opt/codeinterpreter/codeapi.sh logs --tail 100 api` (also `service-worker`, `sandbox-runner`, `file_server`) |
| Restart | `bash /opt/codeinterpreter/codeapi.sh restart` |
| Update | in `/opt/codeinterpreter/env/versions.env` `CODEAPI_VERSION=v1.x.y` **and** its commit `CODEAPI_COMMIT` (`git ls-remote https://github.com/ClickHouse/code-interpreter 'refs/tags/v1.x.y^{}'`), then `bash /opt/kira/setup.sh` (builds again) |
| Parallel runs | `CODE_PARALLEL` in `/opt/kira/env/setup.env`, then `setup.sh` |
| Switch off | `CODE_INTERPRETER=false` in `/opt/kira/env/setup.env`, `bash /opt/kira/setup.sh`, then `bash /opt/codeinterpreter/codeapi.sh down` |
| Backup | `scripts/backup.sh` keeps `env/` and the settings; `src/`, images and temporary files are rebuilt |

## Security

- The sandbox runs code that a language model wrote. Each run gets its own small VM (own kernel) without network;
  it only talks to the egress gateway, which only passes files and tool calls.
- The private key stays in `/opt/kira/env/librechat.env`; the code interpreter only knows the public key.
- No ports, internal network only; the LAN block also keeps it away from the host's services (SSH …).
- Only the pinned commit is built – the sources run as root in the build and in the containers.
- Never run it without KVM (`KVM_ENABLED=false` shares the host kernel – only for development).
- A sandbox escape would land on the KIRA server: keep the host patched and raise `CODEAPI_VERSION` for security
  releases.
