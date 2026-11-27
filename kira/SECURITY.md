# KIRA – security review

Review of the KIRA stack package (stacks `caddy`, `kira`, `bifrost`, `websearch`, `onyx`, `codeinterpreter`, `docs`) as of
**27.11.2026**, versions LibreChat v0.8.9, Bifrost v2.6, Firecrawl 2.11, code interpreter v1.9.1. Checked: code,
scripts, generated configuration and the network rules (firewall rules tested with real traffic in network
namespaces). Not checked: the running server, Keycloak, the hypervisor, the upstream proxy – see "Outside the package".

Overview of networks and containers: [NETWORK.md](NETWORK.md). Groups and permissions: [README.md](README.md),
section "Own agents".

## Result

No critical finding. Hardenings applied during the reviews are listed under "Changes"; some small residual risks are
accepted and listed below.

## Threat model

| Who / what | Goal | Main protection |
|---|---|---|
| Anyone on the internet | reach a service, log in | only Caddy publishes ports; login only via Keycloak; admin interfaces only from allowed IPs |
| Logged-in user | use more than allowed (agents, models, money) | role per Keycloak group, agent list enforced by LibreChat, budgets in Bifrost, message limit |
| Builder | expensive models, share agents, reach internals | model groups, no sharing permission, no actions or own MCP servers; code only in the sandbox and only if their group may run code |
| Code written by the model (also steered by a prompt injection in a document or web page) | read secrets, reach the LAN or the host, keep running | one KVM microVM per run without network, egress gateway, internal networks, no host services from container networks, limits |
| Malicious web page (web search) | make the scraper call internal addresses (SSRF) | LAN block, internal-only networks, Firecrawl fix for redirects |
| Compromised container | spread to the LAN, the host, other stacks | LAN block, one internal network per stack, `cap_drop`, `no-new-privileges`, no Docker socket |
| Script on another web page | use a logged-in admin's session | CORS of Bifrost only for its own interface, `X-Frame-Options: DENY` |
| Logged-in user (documents) | read documents of an agent they do not see | search fixed per agent and checked against the role; downloads only after login with the same group rule; login headers from the browser removed |
| Author of a file in a NAS folder (or a crafted file) | steer the agent (prompt injection), exploit a file parser | write access to the folders only for trusted people; parsers run in `docs-sync` without internet and with only the NAS and Onyx reachable, read-only root, uid 10001, limits; rendered pages capped in size |

## Controls by area

### Exposure (Caddy)

- Only Caddy publishes ports: 80, 443 and `127.0.0.1:8080` (Bifrost interface via SSH tunnel).
- Onyx, the LLM API and the Bifrost interface only from allowed IPs (`*_ALLOWED_IPS`); the LLM API only forwards
  `/v1/chat/completions`, `/v1/responses` and `/v1/models`, everything else gets 404.
- Behind an upstream proxy only that proxy is trusted for the client IP (`trusted_proxies_strict`).
- Security headers: HSTS, `nosniff`, `X-Frame-Options: DENY`, referrer policy, no `Server` header; upload limit
  50 MB (KIRA) and 10 MB (LLM API).
- Values from the setup (domains, IP lists, e-mail) are checked against strict patterns before they are written into
  the Caddy configuration – no injection of Caddy directives.

### Login and permissions (LibreChat)

- Login only via Keycloak (OIDC with PKCE); no local accounts, registration, password reset, account deletion or
  shared links.
- Access only with a required role or group in the ID token (`OPENID_REQUIRED_ROLE`); admins by group/role.
- Agents per group: each Keycloak group gets a LibreChat role with its own agent list; users without a matching group
  get the role `USER` and see no agent. The model specs are enforced, so a user cannot run other agents with
  hand-made requests.
- Own agents only for members of `BUILDER_GROUP` **and** a model group; the models are narrowed per user and checked
  by LibreChat on every message. Builders cannot share agents. Admins get all models and parameters.
- Off for users: prompt library, skills, memories, presets, marketplace, "+" (multiConvo, admins only), OpenAPI
  actions, own MCP servers; code execution only with the code interpreter, for agents with `CODE=true`.
- Links with `?prompt=…&submit=true` only fill in the prompt; `/api/config` shows no build information.

### LLM gateway (Bifrost)

- A virtual key is required for every request (`enforce_auth_on_inference`); no direct provider keys
  (`allow_direct_keys: false`).
- Budgets per key and time window; external services additionally 60 requests per minute and only Haiku/Sonnet.
- Admin login for the web interface (random password in `env/`).
- CORS (`allowed_origins`) only for the Bifrost interface itself – scripts on other pages, including the KIRA page,
  cannot use the admin API with a logged-in admin's session.
- Chat contents are not logged unless switched on (`LOG_CHAT_CONTENT`); log retention configurable.
- Optional privacy guard ([PRIVACY-GUARD.md](PRIVACY-GUARD.md)): requests with personal or secret data are answered
  by a local model, harmful requests refused; fail-closed when a checker is down. Bifrost then runs as an own build with
  the plugin and may reach exactly the vLLM servers in the LAN (ip:port). The checkers are language models – no
  guarantee, the data processing agreements stay necessary.
- Optional code interpreter (`CODE_INTERPRETER`): code written by the model runs in a KVM microVM per run (own guest
  kernel, NsJail and seccomp inside, signed execution manifests – the hardening of the project stays on). The stack has
  no published ports, no internet and no LAN (`codeinterpreter_backend` is internal); the sandbox only reaches its egress
  gateway. LibreChat signs a token per run (Ed25519, 5 minutes); the code interpreter only knows the public key.
  Residual risk: a sandbox escape would land on the KIRA server – keep the host and `CODEAPI_VERSION` up to date.

### Networks and egress

- Databases and caches have no internet and sit only in the internal network of their own stack.
- Shared internal networks with one purpose each (`kira-llm`, `kira-search`, `kira-onyx`, `kira-code`, `kira-proxy`).
- LAN block (`kira-egress-firewall`): containers with internet cannot reach the LAN or the host. Exceptions:
  DNS servers of the host (port 53), Keycloak on port 443 – **only for LibreChat and Onyx**.
- No container network reaches services of the host (SSH, Portainer …): the LAN block drops new connections to the
  host from the egress networks **and** from all internal networks (`172.30.0.0/16` – Docker keeps internal networks
  away from LAN and internet, but not from the host's own addresses).
- With Keycloak in the LAN, LibreChat has **no internet at all** (only Keycloak and DNS).

Tested with real traffic (network namespaces, iptables as on the server):

| Network | Keycloak:443 | Internet:443 | DNS |
|---|:-:|:-:|:-:|
| LibreChat (`kira-outbound`) | ✔ | blocked | ✔ |
| Onyx (`onyx-outbound`) | ✔ | ✔ | ✔ |
| Bifrost (`bifrost-outbound`) | blocked | ✔ | ✔ |
| Web search (`websearch-outbound`) | blocked | ✔ | ✔ |

### Web search (SSRF)

- Firecrawl API 2.11 contains the fix for CVE-2024-56800 (redirects to internal addresses). Its Playwright service
  is not patchable upstream – the LAN block stops it from reaching private addresses.
- Firecrawl and SearXNG are only reachable from LibreChat (`kira-search`); LibreChat only accepts these internal
  addresses for the web search (`allowedAddresses`).
- RabbitMQ runs without its management web interface; Redis refuses HTTP-style requests.

### Agents and tools

- Capabilities: file search, web search, artifacts, context, the image tool, code execution (only with
  `CODE_INTERPRETER=true`, see below). No OpenAPI actions, no own MCP servers – an agent cannot call arbitrary
  addresses from inside the stack.
- Tool library only with "OpenAI Image Tools" (Google, Wolfram, Tavily, … are not loaded).
- "Übergaben" (handoffs) cannot be switched off in LibreChat v0.8.9; uncritical, because handovers only go to agents
  the user can see anyway.

### Code interpreter (optional)

- Every run gets its own KVM microVM (own guest kernel, NsJail and seccomp inside, per-run user, 2 GB, 2 vCPUs,
  300 s). The VM has no network; the launcher only forwards to the egress gateway, which only passes files and tool
  calls (signed execution manifests). `KVM_ENABLED=false` is never used.
- The stack publishes no ports and sits in the internal network `codeinterpreter_backend` (no internet, no LAN, no
  host services). LibreChat reaches only the API `codeapi:3112` over `kira-code`.
- Login: LibreChat signs a token per request (Ed25519, 5 minutes, issuer/audience checked); the code interpreter
  only knows the public key. Without a valid token no run (`LOCAL_MODE=false`). Remote bridge (external sandboxes)
  off. Files and outputs are separated per user (the user ID in the token).
- Who may run code: only agents with `CODE=true`; with agents per group only groups that have such an agent
  (LibreChat permission `RUN_CODE`).
- Sources: the pinned release is checked against its commit (`CODEAPI_COMMIT`) before it is built – a moved tag is
  refused. Own secrets instead of the project's examples (`env/codeapi.env`, 600).
- Services with `no-new-privileges`, `cap_drop: ALL` (Redis: only the capabilities to switch users), memory limits;
  the sandbox runner keeps the project's settings (it starts the VMs and the per-run users) with a memory limit for
  all VMs together.
- Files in its storage (MinIO) are deleted after 2 days (lifecycle rule set by `setup.sh`); results are stored in
  LibreChat and deleted with the chat (`CHAT_RETENTION`).

### Documents per agent (optional)

- One Onyx document set per agent (`kira-<agent>`); the free Onyx edition cannot restrict them to groups, so KIRA
  enforces the separation itself: each agent has its own MCP entry `docs-<agent>` (agent name fixed in the
  configuration, not chosen by the model); `docs-search` checks a shared key, refuses own agents (`X-Agent-Id` is set
  for stored agents) and checks the user's role (`{{LIBRECHAT_USER_ROLE}}`) against `config/docs-agents.json`.
  The Onyx MCP server ("intranet", whole index) is not configured while the document search is on.
- Downloads: Caddy removes `X-Auth-Request-*` from the browser, asks the login service (oauth2-proxy, Keycloak client
  `kira-docs`, PKCE, cookie `__Secure-`, path `/dokumente`) and copies only e-mail and groups; `docs-download` checks
  the groups like LibreChat (group with the most agents wins, admins all), answers 404 for everything else, never
  serves `_vorlagen`, refuses paths outside the agent's folder, delivers non-PDF/image files only as attachment with
  `nosniff` and images with `CSP: sandbox`. Tested: forged headers without a session end at the login.
- Networks: `docs-sync` reaches only the NAS ip:445 (chain `KIRA-EGRESS-DOCS`, no internet, no DNS), `docs-login`
  only Keycloak (like LibreChat), `docs-search` and `docs-download` have no external access; `docs-download` reads the
  copy read-only. Containers `read_only`, `no-new-privileges`, `cap_drop: ALL`, memory and process limits, uid 10001.
- The NAS account only reads; secrets in `/opt/docs/env/` (600). Download log (e-mail, file) and the login log of
  `docs-login` only if switched on, with daily deletion after the configured days (Docker log rotation for the login log).
- The Onyx key of `docs-sync` has the role Admin (the ingestion API needs it) – it stays in the container that parses
  the files; `docs-search` uses its own key with role Basic.

### Secrets

- Only in `env/` of each stack (folders 700, files 600); generated with `openssl rand`; not in the package, not in
  Portainer, not in the generated configuration (`librechat.yaml` and `bifrost.json` only reference environment
  variables).
- Slack/Uptime Kuma URLs and the Keycloak service account secret go to curl via stdin (`-K`), not on the command line.
- The builder sync's state file (Keycloak user IDs) is readable by root only.

### Containers

- `no-new-privileges` everywhere except the code interpreter's sandbox runner; `cap_drop: ALL` except Onyx, the
  Firecrawl API, MinIO and the sandbox runner (their images need the default capabilities); memory limits except
  Onyx; log rotation; no container gets the Docker socket; only the sandbox runner gets a device (`/dev/kvm`).

### Keycloak service account (builder sync)

- Only reads users and groups (`realm-management`: `view-users`, `query-groups`); the admin API is reached from the
  host, not from a container. Errors go to Slack once, plus a recovery message.

### Scripts

- `shellcheck` and `pyflakes` without findings; all values passed into JavaScript inside the containers are
  base64 or JSON encoded (no injection); temporary files with restrictive `umask`.

## Changes during this review

1. **Bifrost CORS:** the KIRA domain was removed from `allowed_origins` (LibreChat calls Bifrost server-side and needs
   no CORS).
2. **Keycloak exception of the LAN block** only for LibreChat and Onyx – before, every container with internet
   (including the web scraper) could reach Keycloak in the LAN.
3. **LibreChat without internet** whenever Keycloak is in the LAN (also with a private DNS answer); the self-test checks
   it with a plain TCP connection.
4. **Web search:** RabbitMQ without the management interface (`RABBITMQ_TAG=3-alpine`), process limits for all
   web search containers.
5. **Builder sync:** state file 600.
6. **Code interpreter (27.11.2026):** runs locally instead of on an own server – no published ports, internal network
   only, remote bridge off, sources pinned to the release commit, hardening of its services, file expiry in its storage,
   code permission only for groups with a code agent.
7. **Host services:** the LAN block now also drops new connections from the internal networks to the host.
8. **Office download links removed:** documents come from the code interpreter and stay in LibreChat – no files
   reachable by link without login.
9. **Documents per agent (27.11.2026):** new stack `docs` with the separation above; the Onyx MCP server with access to
   the whole index is switched off while it is active.
10. **Review of the documents stack (27.11.2026):** LibreChat no longer shares a network with the Onyx API (own network
    `kira-docs-onyx` for docs-sync/docs-search ↔ Onyx); `setup.sh` no longer follows links in the template folder
    (chown/chmod as root), LibreChat mounts its parent folder; PDF pages are rendered with a size cap; skill text kept
    well below LibreChat's start limit; login log of the downloads only together with the download log; a restored sync
    state fetches missing copies again.

## Accepted residual risks

| Risk | Why accepted |
|---|---|
| Builders reach the endpoint "Bifrost" of the fixed agents (and its models) with hand-made API requests | the fixed agents run on it; closing it would break them for builders. Budgets and the message limit still apply |
| Firecrawl's Redis has no password | internal network of the web search only; Redis refuses HTTP-style requests; a password could not be tested here |
| MongoDB backup and `terms-reset.sh` pass the database password on the command line | visible in the process list for a moment; the host is used by root only |
| No Content-Security-Policy for LibreChat | its artifacts load code from external sandboxes; a strict policy would break them |
| All KIRA users share one virtual key | one user can use up the budget for everyone; `MESSAGE_LIMIT` slows this down |
| Builders can add the MCP server "intranet" (Onyx) to their own agents | only make people builders who may see the intranet |
| `SEARXNG_TAG`, `FIRECRAWL_PLAYWRIGHT_TAG`, `FIRECRAWL_NUQ_TAG` are `latest` | upstream offers no version tags for some of them; pin by digest if needed |
| Code interpreter: a sandbox escape (KVM or guest kernel bug) lands on the KIRA server | defence in depth (microVM + NsJail + seccomp, no network, internal network only); keep the host and `CODEAPI_VERSION` up to date |
| Code interpreter: MinIO image `quay.io/minio/minio` without version and no longer maintained as a community image | internal network only, own credentials; pin `MINIO_IMAGE` by digest after the first start |
| Code interpreter: the Redis password is on the command line of `codeapi-redis` (project default) | visible only on the host (`docker inspect`); Redis is reachable only in its internal network |
| Users can run any code in the sandbox (also via "Run code" on code blocks) | that is the feature; it runs isolated, with time, memory and parallel limits |
| Documents: whoever sees an agent sees all files of its folder; NAS file permissions are not taken over | wanted (decision 27.11.2026); smaller circles get their own agent/folder |
| Documents: with `CONFIDENTIAL=false` hits go to Claude/OpenAI and images to the image model; the Onyx search uses Onyx's LLM | data processing agreements; member data only after clarification with data protection; `CONFIDENTIAL=true` with the privacy guard for sensitive folders |
| Documents: template skills are deployment skills; with the capability `skills` on, a builder could try to enable them for an own agent by a hand-made request | the skills area and API are off for users (`SKILLS` permission); only fixed agents list them; templates (letterheads) are not secret |
| Documents: the login service refuses users whose e-mail is not verified | intended; Keycloak *Trust Email* for the Microsoft provider |
| Documents: texts in the files can try to steer the agent (prompt injection), e.g. towards misleading links | only trusted people write to the NAS folders; agents without web search cannot send data out; answers are drafts |
| Documents: a changed Keycloak group takes effect for downloads after at most one hour (session refresh) | short enough for the use case; immediately: the user logs out (`/dokumente/oauth2/sign_out`) |
| Documents: PDFs open in the browser's PDF viewer on the KIRA domain (no CSP sandbox – it would break the viewer) | delivered as `application/pdf` with `nosniff`, never as HTML; the viewers run PDF scripts isolated |

## Outside the package (recommended, not checkable from here)

- **Firewall** of the server (or the hypervisor): TCP 80/443 only from the upstream proxy (<PROXY-IP>); SSH and
  Portainer (9443 = root on the host) only from the admin network.
- **Backups** in `/var/backups/kira` contain the secrets, all chats and the transcribed document texts unencrypted (folder 700) – copy them only
  encrypted to another system.
- **Keycloak:** `/admin` from the KIRA host only for the service account; the client `kira` confidential with PKCE.
- **Updates:** check LibreChat, Bifrost, Onyx, Firecrawl and code interpreter releases for security fixes regularly and
  raise the tags in `env/versions.env`; keep the host kernel patched (KVM).

## Checking it on the server

```bash
bash /opt/kira/scripts/self-test.sh                       # incl. LAN block and "LibreChat without internet"
bash /opt/kira/scripts/egress-firewall.sh status          # firewall rules
python3 -c 'import json; print(json.load(open("/opt/bifrost/config/bifrost.json"))["client"]["allowed_origins"])'
bash /opt/kira/scripts/user-check.sh <e-mail>             # role and agent list of a user
bash /opt/codeinterpreter/codeapi.sh ps                   # code interpreter: no ports listed under PORTS
docker exec docs-sync python -m kiradocs.sync --check     # documents: NAS readable (only ip:445 allowed)
ss -tlnp | grep -E ':(80|443|8080) '                      # only Caddy (docker-proxy) listens
```

## Sources

- [Bifrost – security best practices](https://docs.getbifrost.ai/deployment-guides/how-to/security-best-practices)
- [Bifrost – client configuration](https://docs.getbifrost.ai/deployment-guides/config-json/client)
- [NVD – CVE-2024-56800 (Firecrawl SSRF)](https://nvd.nist.gov/vuln/detail/CVE-2024-56800)
