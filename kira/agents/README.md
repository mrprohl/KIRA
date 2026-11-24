# Agents

Two files with the same name per agent: `NN-name.env` (settings) and `NN-name.md` (instruction/system prompt).
The number at the beginning sets the order in the selection. New agent: copy a pair, adapt it, then run
`bash /opt/kira/setup.sh` – it regenerates `config/librechat.yaml` and offers to restart LibreChat.

| Field | Meaning |
|---|---|
| `NAME` | technical name, only `a-z`, `0-9`, `-` (unique) |
| `TITLE` | display name in KIRA |
| `DESCRIPTION` | subtitle in the selection |
| `MODEL` | Bifrost model ID with provider, e.g. `anthropic/claude-sonnet-5-5`, `openai/gpt-6.1-sol` – must be allowed for the key `vk-librechat` in `/opt/bifrost/config/bifrost.json` (`setup.sh` checks it). Claude models run with prompt caching on the endpoint "Bifrost", other providers on "Bifrost OpenAI" etc. without it |
| `ICON` | optional, image file in `agents/` (`.webp`, `.png`, `.jpg`, `.svg`, max. 256 KB) shown as the agent's icon |
| `TEMPERATURE` | optional, 0 to 1 for Claude, 0 to 2 for OpenAI (low = factual, high = creative); Opus ignores it |
| `DEFAULT` | `true` = preselected (only one agent) |
| `WEB_SEARCH` | `true` = may search the internet (SearXNG + Firecrawl) |
| `FILE_SEARCH` | `true` = may search uploaded documents (RAG) |
| `INTRANET` | `true` = searches the intranet via Onyx (only if Onyx is active) |
| `IMAGES` | `true` = image agent; needs the `AGENT_ID` of an agent created in the web interface (README) |
| `AGENT_ID` | image agents only: ID from LibreChat (`agent_…`) |
| `ENABLED` | `false` = hidden without deleting the files |

Which group sees which agents: `groups.env` (only with `AGENT_GROUPS=true`, README).

Put values containing spaces in quotes. The text of the `.md` file is used unchanged as the instruction.
Titles, descriptions and instructions stay in German – they are what the users see.
