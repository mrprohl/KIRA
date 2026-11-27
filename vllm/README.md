# vLLM servers for the privacy guard

Templates for the GPU servers of the [privacy guard](../kira/PRIVACY-GUARD.md). They run **on the GPU servers, not on
the KIRA server** – one vLLM instance per model, each with its own env file.

| Instance | Template | Served name | Port | Server |
|---|---|---|---|---|
| Privacy checker | `privacy.env.example` | `kira-privacy` | 8101 | privacy |
| Safety checker | `safety.env.example` | `kira-safety` | 8102 | safety |
| Embeddings | `embedding.env.example` | `kira-embedding` | 8103 | embedding (own server, small GPU) |
| Local answer model | `answer.env.example` | `kira-answer` | 8104 | answer |

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

The same on the other servers with their env file. The embedding model has its own server, so the document uploads
(many embeddings at once) never slow down the privacy checks that every request waits for. If you still want both on
one GPU: the FP8 variant of the privacy checker and `GPU_MEM` of both together below 0.95.

- **API key:** the same on all instances and in `/opt/bifrost/env/bifrost.env` (`VLLM_API_KEY`) on the KIRA server.
  `setup.sh` generates one if you leave it empty: `grep ^VLLM_API_KEY /opt/bifrost/env/bifrost.env`.
- **Firewall of the GPU servers:** allow the port only from the KIRA server (e.g. `ufw allow from <KIRA-IP> to any port 8101 proto tcp`).
  vLLM speaks plain HTTP; in an untrusted LAN put a reverse proxy with TLS in front and use `https://…` in `setup.sh`.
- **Answer model:** `Qwen3.8-Flash-Next` is new (architecture `qwen4_exp`) – it needs a current vLLM. Start with FP8 on
  4 GPUs as in the template; if it does not load (GPUs without native FP8 run it weight-only), try BF16 with expert parallelism or use
  `Qwen/Qwen3.8-27B` as fallback. Read the licence (Qwen Community License) before use.
- **Tool calls:** agents use tools (document search, intranet). The answer model needs `--enable-auto-tool-choice` and
  the tool-call parser from its model card.
- **Embeddings:** `--runner pooling` (newer vLLM) or `--task embed` (older) – `vllm serve --help`.

## Check from the KIRA server

```bash
bash /opt/kira/scripts/self-test.sh            # section "Privacy guard": all four reachable from Bifrost
bash /opt/kira/scripts/self-test.sh --request  # plus a test request with a test IBAN
```
