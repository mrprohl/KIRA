# Documents per agent (stack `docs`, optional)

Each agent with `DOCS=true` searches **its own folder** on a NAS and cites its sources with a link to the original file.
Agents with `TEMPLATES=true` also write letters and documents from **their own templates** (Word, Excel, PowerPoint).
Switched on in `setup.sh` (`DOCS_ENABLED`); needs Onyx (`ONYX_ENABLED=true`), templates also need the code interpreter.

```
NAS  \\<nas>\<share>\<agent>\…            ── docs-sync (every 15 min, SMB 2/3, read only) ──┐
                       \<agent>\_vorlagen\ ── skill vorlagen-<agent> ──> LibreChat (skills)  │
                                                                                            v
LibreChat ── MCP docs-<agent> ──> docs-search ── Onyx search, document set kira-<agent> <── Onyx
Browser ── /dokumente/<agent>/<id> ──> Caddy ── login (docs-login, Keycloak) ──> docs-download (copy)
```

| Service | Job | Networks |
|---|---|---|
| `docs-sync` | every 15 minutes: agent folders from the NAS → copy on this server + text → Onyx; `_vorlagen` → skill | `docs-outbound` (only the NAS on port 445), `kira-docs-onyx` (Onyx API), `kira-llm` (image model via Bifrost) |
| `docs-search` | MCP server for LibreChat: one tool `dokumente_suchen`, always in the document set of the calling agent | `kira-docs` (LibreChat), `kira-docs-onyx` (Onyx API) |
| `docs-download` | hands out the original files from the copy, after login and rights check | `kira-docsweb` |
| `docs-login` | Keycloak login for the downloads (oauth2-proxy, client `kira-docs`) | `kira-docsweb`, `docs-auth` (Keycloak) |

The image `kira/docs:<hash>` (Python, Tesseract OCR) is built by `setup.sh` from `docs/app/`; the login service comes from
`quay.io/oauth2-proxy/oauth2-proxy` (`OAUTH2_PROXY_TAG` in `env/versions.env`).

## Folders on the NAS

```
\\nas.example.local\kira-docs\
  writing\                    ← agent "Textwerkstatt" (NAME=writing)
    Hausstil.pdf
    Merkblätter\…              sub-folders are read as well
    _archiv\…                  skipped (more in DOCS_EXCLUDE)
    _vorlagen\                 templates (TEMPLATES=true) – never part of the search, never downloadable
      Brief_HWK.docx
      Brief_HWK.md             optional hint for the model (purpose, salutation, signature)
  intranet\
```

- Folder name = `NAME` from the agent file. A folder without an agent with `DOCS=true`/`TEMPLATES=true` is ignored; a
  missing folder is reported by `setup.sh` and in the self-test.
- Account: read-only on the share. `_vorlagen`: only admins write, the KIRA account reads.
- Size: planned for about 1 GB per agent; files above 100 MB are skipped (`MAX_FILE_MB` in `env/docs-sync.env`).
- Everyone who may see an agent may see **all** documents in its folder – file permissions on the NAS are not taken
  over. Put documents for a smaller circle into the folder of an agent that only this group sees (`agents/groups.env`).

## Switches in the agent files

| Field | Meaning |
|---|---|
| `DOCS=true` | the agent searches its folder `<NAME>` (tool `dokumente_suchen`, sources as links) |
| `TEMPLATES=true` | the agent uses the templates from `<NAME>/_vorlagen` (skill `vorlagen-<NAME>`; needs `CODE=true`) |
| `CONFIDENTIAL=true` | answers, titles and image transcription only with the local model (privacy guard). Without `PRIVACY_GUARD=true` there is no local model – `setup.sh` stops with a hint |

Start: `DOCS=true` for Textwerkstatt (`writing`, also `TEMPLATES=true`) and Intranet (`intranet`), all
`CONFIDENTIAL=false`. After a change: `bash /opt/kira/setup.sh`.

With the document search switched on, `INTRANET=true` (Onyx MCP server) is no longer used: it would search the whole of
Onyx – including every other agent's folder. The agent "Intranet" searches its own folder `intranet` instead.

## Reading the files

| File | How | Costs |
|---|---|---|
| PDF with text, Word, Excel, PowerPoint, text, CSV | text read directly | none |
| scanned PDF, images with printed text | OCR (Tesseract, German and English) in the container | none |
| handwriting, photos, poor scans | image model via Bifrost (`DOCS_VISION`, key `vk-docs`, budget per day/month) | one model call per page |

- Text from OCR or the image model is marked "Automatisch übertragen – Lesefehler möglich"; the agents point this out.
- Results are kept per file (`state.db`): only new or changed files are read again. Files that were not sent
  (privacy guard) or failed are tried again after a day.
- Estimate before the first real run: `docker exec docs-sync python -m kiradocs.sync --estimate` (counts pages and
  images that would go to the image model; no model calls).
- **Privacy guard** (`PRIVACY_GUARD`): off → images go to the image model's provider (as configured,
  `DOCS_VISION_MODEL`, default Claude Sonnet). On → the guard checks the key `vk-docs` like the chats (same mode
  observe/enforce); with personal data the file is answered locally or not sent. Agents with `CONFIDENTIAL=true` never
  send images to Claude/OpenAI: only to `DOCS_VISION_LOCAL_MODEL` (empty = OCR only).

## Templates (skill per agent)

- `docs-sync` turns `<agent>/_vorlagen` into the skill `vorlagen-<agent>` in `/opt/docs/skills/live`: the files
  (`.docx`, `.xlsx`, `.pptx`, logos as `.png`/`.jpg`/`.svg`, max. 10 MB each) plus instructions in German. File names are
  shortened to letters, digits, `.`, `_`, `-` (umlauts → ae/oe/ue); the original name is noted in the skill.
- Placeholders such as `{{ empfaenger }}`, `{{ datum }}`, `{{ betreff }}`, `{{ anrede }}`, `{{ text }}`, `{{ gruss }}`
  are found and listed; the model fills them with `docxtpl`. Without placeholders it writes below the letterhead.
- `<name>.md` next to a template = hint for this template; other `.md` files = general hints.
- Only the agent itself uses its skill (`skills: [vorlagen-<agent>]` in its model spec, `skills: false` for all others);
  the skills area is hidden in the interface.
- **When do changes take effect?** LibreChat reads skills only when it starts. `/etc/cron.d/kira` restarts LibreChat at
  **03:15** if the skills changed (running chats would be cut off during the day). At once:
  `bash /opt/kira/scripts/templates-reload.sh`; status: `templates-reload.sh --status`.
- In the chat: "Schreib dem Betrieb Müller eine Erinnerung als Brief" → the model loads the skill, fills the template
  in the code interpreter and the `.docx` appears in the chat with preview and download – as a draft to be checked.

## Downloads (links in the answers)

- Every document in Onyx carries the link `https://<KIRA domain>/dokumente/<agent>/<document id>` (PDF with `#page=N`).
- Caddy (`sites/kira.d/docs.caddy`): `/dokumente/oauth2/*` → login service; `/dokumente/*` → `forward_auth` at the login
  service, then `docs-download`. The headers `X-Auth-Request-*` from the browser are removed first; only the login service
  sets e-mail and groups.
- `docs-download` checks the groups against the same mapping as the agents (`agents/groups.env`: the group with the most
  agents wins, like in LibreChat; admins see everything). Without agent groups: Keycloak role `user`/`admin`.
  No access, unknown id, `_vorlagen` or a path outside the folder: **404**.
- PDFs and images open in the browser (images with `Content-Security-Policy: sandbox`); everything else (Word, Excel,
  HTML, SVG …) is always downloaded (`Content-Disposition: attachment`, `nosniff`).
- Download log (`DOCS_DOWNLOAD_LOG`, `DOCS_DOWNLOAD_LOG_DAYS`, default 90 days): time, user e-mail, agent, document,
  result (`geliefert`/`verweigert`/`unbekannt`), in the volume `docs_logs` (`downloads.jsonl`); older entries are deleted
  daily. Off: the log is deleted, and the login service does not log logins either (`docker logs docs-login`).
- A user removed from a group keeps download access for at most one hour (session refresh); at once: log out via
  `https://<KIRA domain>/dokumente/oauth2/sign_out`.

### Keycloak client `kira-docs`

Once in the realm of KIRA (labels of Keycloak 26):

| Setting | Value |
|---|---|
| Client type / Client ID / Name | OpenID Connect / `kira-docs` / KIRA Dokumente |
| Client authentication | **On** (secret – `setup.sh` asks for it) |
| Standard flow | **On**; Direct access grants, Implicit flow, Service accounts, Device grant, CIBA: Off |
| PKCE method | S256 |
| Root URL / Home URL | `https://<KIRA domain>` / `https://<KIRA domain>/` |
| Valid redirect URIs | `https://<KIRA domain>/dokumente/oauth2/callback` (exactly this, no `*`) |
| Valid post logout redirect URIs | `https://<KIRA domain>/` |
| Web origins | empty |
| Advanced → Front channel logout | Off |

Client scopes → `kira-docs-dedicated` → Add mapper → By configuration:

| Mapper | Settings |
|---|---|
| Group Membership | name `groups`, claim `groups`, full group path **off**, ID token, access token and userinfo on |
| User Client Role | name `roles`, client = the KIRA client (`OPENID_CLIENT_ID` of LibreChat), claim `roles`, multivalued on, ID token, access token and userinfo on |
| Audience | name `audience`, included client audience `kira-docs`, access token on |

`profile` and `email` stay default scopes. Check with Client scopes → Evaluate → user → generated ID token: `groups`
(with agent groups) or `roles`, `email` and `"email_verified": true` (for users from Microsoft: enable *Trust Email* at
the identity provider – the login service refuses unverified e-mails).

## Setup questions (stored in `/opt/kira/env/setup.env`)

| Key | Question |
|---|---|
| `DOCS_ENABLED` | document search per agent (only with Onyx) |
| `DOCS_NAS_HOST`, `DOCS_NAS_SHARE`, `DOCS_NAS_DOMAIN`, `DOCS_NAS_USER` | NAS (name or IP), share, Windows domain (empty = local account), account |
| `DOCS_EXCLUDE` | more sub-folders to skip (comma-separated; `_vorlagen`, `_archiv` always) |
| `DOCS_VISION`, `DOCS_BUDGET_1D`, `DOCS_BUDGET_1M` | image model for handwriting/photos and its budget in USD per day and month (key `vk-docs`) |
| `DOCS_DOWNLOAD_LOG`, `DOCS_DOWNLOAD_LOG_DAYS` | download log on/off and days (empty = 90d) |
| `DOCS_CLIENT_ID` | Keycloak client (default `kira-docs`) |
| `DOCS_VISION_MODEL`, `DOCS_VISION_LOCAL_MODEL` | image model (default `anthropic/claude-sonnet-5-5`); local image model for `CONFIDENTIAL` agents (empty = OCR only) |

Secrets only in `/opt/docs/env/` (600): NAS password and Onyx admin key (`docs-sync.env`), search key (`docs-search.env`),
client and cookie secret (`docs-login.env`); `DOCS_SEARCH_KEY` also in `kira/env/librechat.env`, `VK_DOCS` in
`bifrost/env/bifrost.env`. Onyx keys: admin area → API Keys – role **Admin** for the sync (creates connectors and
document sets), role **Basic** for the search (empty = LibreChat's `ONYX_API_KEY`).

`setup.sh` resolves the NAS name on every run and allows exactly this IP on port 445 (`DOCS_NAS_DST` in
`config/egress.env`); after starting it checks the connection (`python -m kiradocs.sync --check`).

## Security

- Separation per agent is enforced by KIRA (the free Onyx edition cannot restrict document sets to groups): one
  document set `kira-<agent>` per agent; the MCP entry of an agent fixes the agent name; `docs-search` checks the key,
  refuses own agents (agent builder – `X-Agent-Id` set) and checks the user's role against `config/docs-agents.json`.
- `docs-sync` reaches only the NAS (ip:445) – no internet, no other LAN destination; `docs-login` only Keycloak;
  `docs-search` and `docs-download` have no external access at all. `docs-download` reads the copy read-only.
  LibreChat reaches only `docs-search` (network `kira-docs`), not the Onyx API (`kira-docs-onyx`).
- Everyone with an account in Onyx's web interface sees all document sets – keep Onyx accounts to admins.
- All containers: `read_only`, `no-new-privileges`, `cap_drop: ALL`, memory limits; the Python services run as uid 10001.
- **Residual risks:** with `CONFIDENTIAL=false` search hits go to the answering model (Claude/OpenAI) and images to the
  image model – covered by the data processing agreements; clarify member data with data protection first. The Onyx
  search itself uses the LLM configured in Onyx (Claude via `vk-onyx`) – with `CONFIDENTIAL=true` switch it to the local
  model in the Onyx admin area. Texts in the documents can try to steer the agent (prompt injection, e.g. misleading
  links) – only trusted people write to the folders. Templates are not secret: a hand-crafted request of a builder
  could reach them.

## Operation and troubleshooting

```bash
docker logs -f docs-sync                                   # passes, errors per agent
docker exec docs-sync cat /data/status.json                # last pass
docker exec docs-sync python -m kiradocs.sync --check      # NAS readable? which agent folders exist?
docker exec docs-sync python -m kiradocs.sync --estimate   # pages/images for the image model
bash /opt/kira/scripts/templates-reload.sh --status        # template skills changed?
bash /opt/kira/scripts/self-test.sh                        # section "Documents"
```

| Symptom | Check |
|---|---|
| `NAS … not readable` | address/share/account in `env/setup.env`, password in `env/docs-sync.env`; SMB 2/3 enabled on the NAS; `egress-firewall.sh status` shows the NAS IP under `KIRA-EGRESS-DOCS` |
| `ONYX_ADMIN_KEY is empty` / HTTP 401/403 from Onyx | admin key in `env/docs-sync.env` (setup.sh asks again when empty) |
| agent answers "Die Dokumentensuche ist gerade nicht erreichbar" | `docker logs docs-search`, Onyx running, `ONYX_SEARCH_KEY` |
| "Für diese Dokumente fehlt die Berechtigung" | the user's group does not see this agent (`agents/groups.env`) |
| download ends at the Keycloak error page | redirect URI of `kira-docs`, client secret, `email_verified` |
| download 404 although logged in | group mapping (`groups`/`roles` mapper), document still in the index (`docker exec docs-sync cat /data/mirror/<agent>.index.json`) |
| LibreChat does not start after a template change | `docker logs librechat 2>&1 \| grep -i skill`; set `TEMPLATES=false`, `setup.sh`, report the file |

Backups (`scripts/backup.sh`): `/opt/docs` incl. `env/`, the sync state (`state.db`, saves model calls) and the download
log. The copy of the NAS files is not backed up – `docs-sync` fetches it again.

**SharePoint later:** per agent an Onyx SharePoint connector on `…/<library>/<agent>/` (app registration with
`Sites.Selected`), added to the document set `kira-<agent>`; links then point to SharePoint with SharePoint permissions.
