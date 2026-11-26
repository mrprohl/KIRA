# vLLM servers for the privacy guard

Templates for the GPU servers of the [privacy guard](../kira/PRIVACY-GUARD.md). They run **on the GPU servers, not on
the KIRA server** – one vLLM instance per model, each with its own env file.

| Instance | Template | Served name | Port | Server |
|---|---|---|---|---|
| Privacy checker | `privacy.env.example` | `kira-privacy` | 8101 | privacy (1× A100) |
| Embeddings | `embedding.env.example` | `kira-embedding` | 8104 | privacy (same GPU) |
| Safety checker | `safety.env.example` | `kira-safety` | 8102 | safety (1× A100) |
| Local answer model | `answer.env.example` | `kira-answer` | 8103 | answer (6× A100) |

The **served names** are fixed – KIRA addresses the models by them. Which model is behind a name is up to you (`MODEL=`).
The ports are only proposals; KIRA gets the full address of each instance in `setup.sh`.

## Setting up a server

Requirements: NVIDIA driver, [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/),
Docker with Compose ≥ 2.20.

```bash
mkdir -p /opt/vllm && cp compose.yml privacy.env.example /opt/vllm/ && cd /opt/vllm
cp privacy.env.example privacy.env && chmod 600 privacy.env
nano privacy.env          # VLLM_TAG (pin a version), VLLM_API_KEY, BIND_IP
docker compose --env-file privacy.env up -d
docker logs -f kira-privacy          # first start downloads the model
curl -s -H "Authorization: Bearer <key>" http://127.0.0.1:8101/v1/models
```

On the privacy server the same with `embedding.env` (second instance on the same GPU – `GPU_MEM` of both together
below 0.95).

- **API key:** the same on all instances and in `/opt/bifrost/env/bifrost.env` (`VLLM_API_KEY`) on the KIRA server.
  `setup.sh` generates one if you leave it empty: `grep ^VLLM_API_KEY /opt/bifrost/env/bifrost.env`.
- **Firewall of the GPU servers:** allow the port only from the KIRA server (e.g. `ufw allow from <KIRA-IP> to any port 8101 proto tcp`).
  vLLM speaks plain HTTP; in an untrusted LAN put a reverse proxy with TLS in front and use `https://…` in `setup.sh`.
- **Answer model:** `Qwen3.8-Flash-Next` is new (architecture `qwen4_exp`) – it needs a current vLLM. Start with FP8 on
  4 GPUs as in the template; if it does not load on the A100 (no native FP8), try BF16 with expert parallelism or use
  `Qwen/Qwen3.8-27B` as fallback. Read the licence (Qwen Community License) before use.
- **Tool calls:** agents use tools (document search, intranet). The answer model needs `--enable-auto-tool-choice` and
  the tool-call parser from its model card.
- **Embeddings:** `--runner pooling` (newer vLLM) or `--task embed` (older) – `vllm serve --help`.

## Check from the KIRA server

```bash
bash /opt/kira/scripts/self-test.sh            # section "Privacy guard": all four reachable from Bifrost
bash /opt/kira/scripts/self-test.sh --request  # plus a test request with a test IBAN
```
