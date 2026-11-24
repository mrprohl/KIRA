# Guide: installing KIRA (step by step)

For the server `kira.example.com` (LXC 10.0.0.13), fresh installation. Each step ends with a **checkpoint**: only continue when it passes.
Background on architecture and modules: `/opt/kira/README.md`.

Time needed: about 30 minutes without Onyx, with Onyx an additional 30–60 minutes (first start, indexing).

---

## Step 1 – Prepare (before the appointment)

Have ready (do not paste into chats or tickets):

- [ ] Anthropic API key and OpenAI API key (`sk-proj-…`). Anthropic: preferably a **service account key** (does not
      depend on one person), **scoped to one workspace** – a key without a workspace needs the header
      `anthropic-workspace-id`, which Bifrost does not send (error 400). A personal key (`sk-ant-usr…`) works too,
      but stops working when its owner leaves the organization.
- [ ] list of the external services using the LLM API (e.g. automation tools, own scripts); if they should keep their current Bifrost
      key, have that key (`sk-bf-…`) ready
- [ ] budgets in USD: LibreChat per 5 hours / week / month, Onyx per day / month, each external service per day / month
- [ ] Uptime Kuma: create the push monitors **"KIRA Container"** (interval 360 s) and **"KIRA Backup"** (90000 s), note the push URLs
- [ ] optionally a Slack incoming webhook for budget warnings
- [ ] decisions: Onyx yes/no, images yes/no, speech yes/no, **user data and chat content in Bifrost yes/no**
      (only with the users' knowledge)
- [ ] decisions: terms of use yes/no and text (template
      `kira/terms-of-use.md.example` in the package – deletion periods are filled in automatically), deletion period for chats (e.g. 90 days),
      retention of the Bifrost logs; addresses for privacy policy and help page (optional)
- [ ] with agents per group: Keycloak groups and which agents each one sees (`kira/agents/groups.env.example`)

Only if Onyx is used:
- [ ] enlarge the LXC to **8 vCPU, 24 GB RAM, 150 GB disk** (Proxmox)
- [ ] on the **Proxmox host**: `echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-opensearch.conf && sysctl --system`
- [ ] DNS record for the Onyx domain (e.g. `onyx.example.com`) pointing to the public IP of the upstream proxy, and add the
      domain to that proxy
- [ ] public IPs of the admins who may open the Onyx web interface (`ONYX_ALLOWED_IPS`)

**Checkpoint:** everything ticked.

---

## Step 2 – Extract the package

```bash
ss -tlnp | grep -E ':(80|443|8080) '                   # ports must be free – no output
apt install -y cron python3 curl openssl unzip
cd /root && unzip -o kira-stack.zip -d /opt             # extract directly on the server, not on Windows
umask 077; scp root@10.0.0.99:/opt/keycloak/env/kira-client-kira.env /opt/kira/env/keycloak-client.env
ls /opt                                                 # caddy bifrost kira websearch onyx
```

The certificates live in the volume `caddy_data` and survive a reinstall.

**Checkpoint:** `ls -l /opt/kira/setup.sh` shows `-rwxr-xr-x`.

---

## Step 3 – Set up with setup.sh

```bash
bash /opt/kira/setup.sh
```

Answers for this server:

| Question | Answer |
|---|---|
| Domain for KIRA | `kira.example.com` |
| E-mail address for Let's Encrypt | a mailbox that is read, e.g. `kira@example.com` (expiry warnings) |
| upstream reverse proxy | `10.0.0.10` |
| internal IP of the Keycloak server | `10.0.0.99` |
| Onyx / images / speech | as decided in step 1; speech output e.g. `gpt-4o-mini-tts`, leave the default voice empty (= `fable`) |
| Restrict agents per Keycloak group? | `yes` if the groups are set up in Keycloak – mapper `groups`, default group `kira-users-default` under *Realm settings* → *User registration* → *Default groups* (README, section "Agents per Keycloak group"), otherwise `no` |
| How long does a login stay active? | empty = `30d` (possible `8h` to `365d`) |
| messages per user and minute | empty = `20` |
| terms of use at first login | as decided in step 1 – **before step 5** fill in the contact line in `/opt/kira/config/terms-of-use.md` and run `setup.sh` again |
| links to privacy policy / help page | intranet addresses from step 1, otherwise empty |
| delete chats after / temporary chats | period from step 1 (e.g. `90d`) / empty = `24h` |
| "context window" panel | `no` |
| summarise long chats from | empty = `100000` tokens |
| keep Bifrost logs | empty = `90` days |
| largest file / files per message / office file types only | empty = `20` MB / empty = `10` / `yes` |
| user data / chat content in Bifrost | `no` / `no` (only with the users' knowledge) |
| LAN block | `yes` |
| Domain for the LLM API | `llm.example.com`, allowed IPs: `203.0.113.10 203.0.113.20` |
| Domain for the Bifrost web interface | empty (access via SSH tunnel) – or `bifrost.example.com` with `203.0.113.10` |
| Name of the external service | one name per service (e.g. `automation`, `crm`), then its existing key; empty = done |
| budgets | from step 1 |
| Onyx API key | leave **empty** (comes in step 7) |
| Uptime Kuma push URLs | from step 1, internal IP `10.0.0.10` |
| Start the stacks now? | `yes` |

`setup.sh` pulls the images, starts bifrost → websearch → kira → (onyx) → caddy and runs the self-test.
On first start this takes a few minutes, with Onyx up to 20 minutes.

**Checkpoint:** at the end "Self-test: all OK." – apart from the note on the certificate if Let's Encrypt is still
running. On errors the self-test shows the next command for each item; see section "Troubleshooting" in the README.

---

## Step 4 – Adjust Keycloak

Keycloak admin (`https://id.example.com`) → realm **kira** → Clients → **kira** → settings:

- **Valid redirect URIs:** add `https://kira.example.com/oauth/openid/callback`
- **Valid post logout redirect URIs:** `https://kira.example.com/login`
- Client scopes → `kira-dedicated` → Evaluate with a test user: the **ID token** contains `"roles": ["user"]`
  (or `admin`) – otherwise add a mapper **User Client Role** (client `kira`, claim `roles`, add to ID token).
- With agents per group additionally: mapper **Group Membership** (`groups`, full group path off) and the default
  group `kira-users-default` (README, section "Agents per Keycloak group"); Evaluate then also shows `"groups": [...]`.

**Checkpoint:** Evaluate shows `roles` (and, with agents per group, `groups`) in the ID token.

---

## Step 5 – First login and test

1. Open `https://kira.example.com` → redirect via Keycloak to Microsoft 365 → back in KIRA.
2. Log in with an account from `kira-admins` and check the role:
   ```bash
   . /opt/kira/env/mongodb.env; docker exec librechat-mongodb mongosh -u "$MONGO_INITDB_ROOT_USERNAME" \
     -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --quiet LibreChat \
     --eval 'db.users.find({}, {email: 1, role: 1, _id: 0}).toArray()'
   ```
   Expected: the admin account with `role: 'ADMIN'`, all others `USER` (with agents per group: their group's name).
3. Select agent **KIRA**: "Welche Version hat LibreChat aktuell?" → answer with sources (web search).
4. Agent **Textwerkstatt**: upload a PDF, "Fasse das Dokument zusammen" → answer with a quote (document search).
5. Search the sidebar for a word from the first chat → the chat is found (chat search).
6. Check the Bifrost web interface: `ssh -L 8080:127.0.0.1:8080 root@10.0.0.13`, then `http://localhost:8080`
   (login: `grep ^BIFROST_ADMIN /opt/bifrost/env/bifrost.env`) → the logs show the requests (with user, if enabled).

**Checkpoint:** all six items work.

---

## Step 6 – Image agent (only if images are enabled)

```bash
/opt/kira/scripts/agent-builder.sh on
```

In KIRA (as admin, reload about 1 minute after the command; labels may differ slightly between versions):
1. Open **Agent Builder** in the side panel (German interface: **Agenten erstellen**, robot icon) → create a new agent.
2. Name and description as `TITLE` and `DESCRIPTION` in `agents/40-images.env`, provider **Bild-Agent**, model
   `anthropic/claude-haiku-5-5` (the image itself comes from the image model `IMAGE_MODEL`, whatever the chat model).
3. Instructions: paste the text from `/opt/kira/agents/40-images.md`.
4. **Add tools** → **OpenAI Image Tools** → save.
5. **Share** → "Share with everyone" (viewer) → save. Copy the **agent ID** (`agent_…`).

```bash
nano /opt/kira/agents/40-images.env                    # enter AGENT_ID=agent_…
/opt/kira/scripts/agent-builder.sh off                 # normal operation, the image agent appears
```

**Checkpoint:** image agent: "Ein Leuchtturm im Sonnenuntergang, flacher Illustrationsstil" → an image appears.

---

**Optional – own agents:** README, section "Own agents (builder and model groups)" (Keycloak client
`kira-sync`, `BUILDER_GROUP` and `builder.…` lines in `agents/groups.env`, then `setup.sh`). On the image agent choose the endpoint
**Bild-Agent** – `agent-builder.sh off` moves it there anyway.

---

## Step 7 – Onyx (only if Onyx is enabled)

1. `https://<onyx-domain>` from an allowed IP (`ONYX_ALLOWED_IPS`) → create the first account right away (becomes
   admin), then restrict sign-up to invited users in the Onyx admin settings (label may differ between versions).
2. **LLM:** Admin → LLM providers → OpenAI-compatible: base URL `http://bifrost:8080/v1`, API key
   `grep ^VK_ONYX /opt/bifrost/env/bifrost.env`, model `anthropic/claude-sonnet-5-5` (fast model `anthropic/claude-haiku-5-5`).
3. **SharePoint:** in Entra create an app registration "KIRA Onyx" with the application permission **Sites.Selected**
   (admin consent), create a client secret; via Microsoft Graph give the app **read access only to the released
   sites** (e.g. manuals, notes, documents). In Onyx: Connectors → SharePoint → tenant ID, client ID, secret,
   site URLs → start indexing.
4. **API key for KIRA:** Admin → API Keys → new key (role Basic) → copy, then:

```bash
bash /opt/kira/setup.sh                                # asks for the Onyx API key, start with "yes"
```

**Checkpoint:** the search in Onyx finds a document; in KIRA the agent **Intranet** appears and answers a question
about one of your documents with a link to it.

---

## Step 8 – Check monitoring and external services

```bash
/opt/kira/scripts/monitor.sh && echo ok                # push "KIRA Container" turns green
/opt/kira/scripts/backup.sh                            # first backup, push "KIRA Backup" turns green
/opt/kira/scripts/egress-firewall.sh status | head -3  # LAN block active
```

Create the HTTP monitors in Uptime Kuma: **"KIRA Web"** `https://kira.example.com/health` (keyword `OK`) and
**"KIRA LLM API"** `https://llm.example.com/v1/models` (accepted status 403).
Trigger one workflow per external service – it runs with its virtual key and is visible in the
Bifrost web interface under Logs with the service's name.

**Checkpoint:** all monitors green, workflows of the external services successful.

---

## Step 9 – Wrap-up

- [ ] Short note to the test users: address `https://kira.example.com`, login with the usual account.
