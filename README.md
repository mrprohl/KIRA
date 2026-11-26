<img src="kira/agents/10-kira.svg" alt="KIRA logo: a white speech bubble with a spark on an indigo tile" width="96">

# KIRA

Personal AI assistant on its own server: [LibreChat](https://www.librechat.ai) as the chat interface, fixed agents per
Keycloak group, [Bifrost](https://docs.getbifrost.ai) as the LLM gateway (Anthropic, OpenAI) with budgets, web search
with SearXNG and Firecrawl, optional intranet search with Onyx – everything behind Caddy, login via Keycloak SSO.

## Structure

The folders are extracted to `/opt` on the server, one Docker Compose stack each:

| Folder | Content |
|---|---|
| [`kira/`](kira/) | LibreChat, `setup.sh` (sets up all stacks), scripts, agents, branding (logo, favicon), documentation |
| [`caddy/`](caddy/) | reverse proxy with Let's Encrypt |
| [`bifrost/`](bifrost/) | LLM gateway with virtual keys and budgets; `plugins/privacy-guard/` for the optional privacy guard |
| [`websearch/`](websearch/) | SearXNG and Firecrawl |
| [`onyx/`](onyx/) | optional intranet search (SharePoint and more) |
| [`vllm/`](vllm/) | templates for the GPU servers of the optional privacy guard (not for the KIRA server) |

## Documentation

- [kira/README.md](kira/README.md) – overview, settings, agents, groups, troubleshooting
- [kira/INSTALL.md](kira/INSTALL.md) – installation step by step
- [kira/NETWORK.md](kira/NETWORK.md) – networks and containers
- [kira/SECURITY.md](kira/SECURITY.md) – security review
- [kira/PRIVACY-GUARD.md](kira/PRIVACY-GUARD.md) – optional privacy guard with own LLMs (vLLM)
- [vllm/README.md](vllm/README.md) – setting up the vLLM servers for it
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
