<img src="kira/agents/10-kira.svg" alt="KIRA logo: a white speech bubble with a spark on an indigo tile" width="96">

# KIRA

Personal AI assistant on its own server: [LibreChat](https://www.librechat.ai) as the chat interface, fixed agents per
Keycloak group, [Bifrost](https://docs.getbifrost.ai) as the LLM gateway (Anthropic, OpenAI) with budgets, web search
with SearXNG and Firecrawl, optional intranet search with Onyx, documents per agent from a NAS and a code interpreter in
a KVM sandbox – everything behind Caddy, login via Keycloak SSO.
Optionally a privacy guard checks every request with own LLMs before it leaves the house.

## Features

- **Chat with fixed agents** (KIRA, code, intranet, images, writing, minutes) – which agents a user sees comes from
  the Keycloak groups; own agents with the models of the user's model groups
- **LLM gateway** Bifrost: one virtual key per application, budgets per time window, cost logs, fallbacks
- **Web search** without a search API (SearXNG, Firecrawl), **document search** (RAG), **intranet search** (Onyx, optional)
- **Documents per agent** (optional, [details](docs/README.md)): each agent searches its own folder on the NAS (also
  scans and handwriting), cites sources with a link to the original (login and rights check) and writes letters from
  its own templates
- **Code interpreter and documents** (optional, needs KVM on the server): Python in a sandbox for analyses and
  charts; Word, Excel, PowerPoint and PDF files appear directly in the chat with preview and download
- **Images and speech** (optional), own logo, favicon and agent icons
- **Privacy guard** (optional, [details](kira/PRIVACY-GUARD.md)): personal or secret data is answered by a local
  model on own vLLM servers, harmful requests are refused, only clean requests go to Claude or OpenAI
- **Security:** only Caddy is published, egress firewall (no LAN access for the containers), secrets generated on the
  server – [security review](kira/SECURITY.md)
- **Operation:** one `setup.sh` for everything, self-test, monitoring (Uptime Kuma), backups, Slack reports

## Structure

The folders are extracted to `/opt` on the server, one Docker Compose stack each:

| Folder | Content |
|---|---|
| [`kira/`](kira/) | LibreChat, `setup.sh` (sets up all stacks), scripts, agents, branding (logo, favicon), documentation |
| [`caddy/`](caddy/) | reverse proxy with Let's Encrypt |
| [`bifrost/`](bifrost/) | LLM gateway with virtual keys and budgets; `plugins/privacy-guard/` for the optional privacy guard |
| [`websearch/`](websearch/) | SearXNG and Firecrawl |
| [`onyx/`](onyx/) | optional intranet search (SharePoint and more) |
| [`codeinterpreter/`](codeinterpreter/) | optional code interpreter (KVM sandbox, built from source by `setup.sh`) |
| [`docs/`](docs/) | optional documents per agent: NAS sync to Onyx, search per agent, templates, downloads behind login |
| [`vllm/`](vllm/) | templates for the GPU servers of the optional privacy guard (not for the KIRA server) |

## Documentation

- [kira/README.md](kira/README.md) – overview, settings, agents, groups, troubleshooting
- [kira/INSTALL.md](kira/INSTALL.md) – installation step by step
- [kira/NETWORK.md](kira/NETWORK.md) – networks and containers
- [kira/SECURITY.md](kira/SECURITY.md) – security review
- [kira/PRIVACY-GUARD.md](kira/PRIVACY-GUARD.md) – optional privacy guard with own LLMs (vLLM)
- [vllm/README.md](vllm/README.md) – setting up the vLLM servers for it
- [codeinterpreter/README.md](codeinterpreter/README.md) – code interpreter and documents in the chat
- [docs/README.md](docs/README.md) – documents per agent (NAS folders, templates, downloads, Keycloak client `kira-docs`)
- [kira/agents/README.md](kira/agents/README.md) – defining agents

## Quick start

```bash
unzip kira-stack.zip -d /opt        # or: git clone … and copy the folders to /opt
bash /opt/kira/setup.sh             # asks for everything, generates secrets and configuration
bash /opt/kira/scripts/self-test.sh
```

## Not in this repository

Secrets and everything generated on the server stay out (see [.gitignore](.gitignore)): every `env/` folder,
`kira/config/`, `kira/agents/groups.env`, `bifrost/config/bifrost.json`, the Caddy site files and backups.
`setup.sh` creates them on the server.

## License

[MIT](LICENSE). The configuration templates are examples – domains and IP addresses are placeholders
(`example.com`, `203.0.113.x`, `<KIRA-IP>`, `<KEYCLOAK-IP>`, `<PROXY-IP>`).
