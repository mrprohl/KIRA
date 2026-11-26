# KIRA – security review

Review of the KIRA stack package (stacks `caddy`, `kira`, `bifrost`, `websearch`, `onyx`) as of **24.11.2026**,
versions LibreChat v0.8.9, Bifrost v2.6, Firecrawl 2.11. Checked: code, scripts, generated configuration and
the network rules (firewall rules tested with real traffic in network namespaces). Not checked: the running server,
Keycloak, Proxmox, the upstream proxy – see "Outside the package".

Overview of networks and containers: [NETWORK.md](NETWORK.md). Groups and permissions: [README.md](README.md),
section "Own agents".

## Result

No critical finding. Three hardenings were applied during the review (see "Changes"); some small residual risks are
accepted and listed below.

## Threat model

| Who / what | Goal | Main protection |
|---|---|---|
| Anyone on the internet | reach a service, log in | only Caddy publishes ports; login only via Keycloak; admin interfaces only from allowed IPs |
| Logged-in user | use more than allowed (agents, models, money) | role per Keycloak group, agent list enforced by LibreChat, budgets in Bifrost, message limit |
| Builder | expensive models, share agents, reach internals | model groups, no sharing permission, no actions/code/own MCP servers |
| Malicious web page (web search) | make the scraper call internal addresses (SSRF) | LAN block, internal-only networks, Firecrawl fix for redirects |
| Compromised container | spread to the LAN, the host, other stacks | LAN block, one internal network per stack, `cap_drop`, `no-new-privileges`, no Docker socket |
| Script on another web page | use a logged-in admin's session | CORS of Bifrost only for its own interface, `X-Frame-Options: DENY` |

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
- Off for users: prompt library, memories, presets, marketplace, "+" (multiConvo, admins only), code execution,
  OpenAPI actions, own MCP servers.
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

### Networks and egress

- Databases and caches have no internet and sit only in the internal network of their own stack.
- Shared internal networks with one purpose each (`kira-llm`, `kira-search`, `kira-onyx`, `kira-proxy`).
- LAN block (`kira-egress-firewall`): containers with internet cannot reach the LAN or the host. Exceptions:
  DNS servers of the host (port 53), Keycloak on port 443 – **only for LibreChat and Onyx**.
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

- Capabilities: file search, web search, artifacts, context, the image tool. No OpenAPI actions, no code
  execution, no own MCP servers – an agent cannot call arbitrary addresses from inside the stack.
- Tool library only with "OpenAI Image Tools" (Google, Wolfram, Tavily, … are not loaded).
- "Übergaben" (handoffs) cannot be switched off in LibreChat v0.8.9; uncritical, because handovers only go to agents
  the user can see anyway.

### Secrets

- Only in `env/` of each stack (folders 700, files 600); generated with `openssl rand`; not in the package, not in
  Portainer, not in the generated configuration (`librechat.yaml` and `bifrost.json` only reference environment
  variables).
- Slack/Uptime Kuma URLs and the Keycloak service account secret go to curl via stdin (`-K`), not on the command line.
- The builder sync's state file (Keycloak user IDs) is readable by root only.

### Containers

- `no-new-privileges` everywhere; `cap_drop: ALL` except Onyx and the Firecrawl API (their images need the default
  capabilities); memory and process limits except Onyx; log rotation; no container gets the Docker socket.

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

## Outside the package (recommended, not checkable from here)

- **Proxmox firewall** for the LXC: TCP 80/443 only from the upstream proxy (<PROXY-IP>); SSH and Portainer (9443 =
  root on the host) only from the admin network.
- **Backups** in `/var/backups/kira` contain the secrets and all chats unencrypted (folder 700) – enable client-side
  encryption in Proxmox Backup Server.
- **Keycloak:** `/admin` from the KIRA host only for the service account; the client `kira` confidential with PKCE.
- **Updates:** check LibreChat, Bifrost, Onyx and Firecrawl releases for security fixes regularly and raise the tags in
  `env/versions.env`.

## Checking it on the server

```bash
bash /opt/kira/scripts/self-test.sh                       # incl. LAN block and "LibreChat without internet"
bash /opt/kira/scripts/egress-firewall.sh status          # firewall rules
python3 -c 'import json; print(json.load(open("/opt/bifrost/config/bifrost.json"))["client"]["allowed_origins"])'
bash /opt/kira/scripts/user-check.sh <e-mail>             # role and agent list of a user
ss -tlnp | grep -E ':(80|443|8080) '                      # only Caddy (docker-proxy) listens
```

## Sources

- [Bifrost – security best practices](https://docs.getbifrost.ai/deployment-guides/how-to/security-best-practices)
- [Bifrost – client configuration](https://docs.getbifrost.ai/deployment-guides/config-json/client)
- [NVD – CVE-2024-56800 (Firecrawl SSRF)](https://nvd.nist.gov/vuln/detail/CVE-2024-56800)
