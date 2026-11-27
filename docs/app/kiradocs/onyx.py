"""Onyx API (api_server, internal network kira-docs): one connector + document set per agent, ingestion, search.

Paths as served by the Onyx api_server itself (no /api prefix – that is only added by Onyx' nginx).
"""
from .common import http_json


class OnyxError(Exception):
    pass


class Onyx:
    def __init__(self, url, key, log):
        self.url, self.key, self.log = url.rstrip("/"), key, log

    def _call(self, method, path, body=None, ok=(200,), timeout=120):
        status, data = http_json(method, self.url + path, body, self.key, timeout=timeout)
        if status not in ok:
            detail = data.get("detail") if isinstance(data, dict) else str(data)[:300]
            raise OnyxError(f"{method} {path}: HTTP {status} {detail}")
        return data

    # -- setup per agent ----------------------------------------------------------------------------------------
    def document_sets(self):
        data = self._call("GET", "/manage/document-set")
        return data if isinstance(data, list) else []

    def ensure_agent(self, agent, label, known_cc_pair=None):
        """Connector "kira-<agent>" (source ingestion_api, public) + document set "kira-<agent>" containing it.
        Returns the cc_pair id. Idempotent: an existing document set with this name is reused."""
        name = f"kira-{agent}"
        sets = {s.get("name"): s for s in self.document_sets()}
        existing = sets.get(name)
        if existing and known_cc_pair:
            ids = [c.get("id") for c in existing.get("cc_pair_summaries") or existing.get("cc_pair_descriptors") or []]
            if not ids or known_cc_pair in ids:
                return known_cc_pair
        cc_pair = known_cc_pair
        if not cc_pair:
            res = self._call("POST", "/manage/admin/connector-with-mock-credential?paused=true", {
                "name": name, "source": "ingestion_api", "input_type": "load_state",
                "connector_specific_config": {}, "refresh_freq": None, "prune_freq": None,
                "access_type": "public", "groups": []})
            cc_pair = res.get("data") if isinstance(res, dict) else None
            if not isinstance(cc_pair, int):
                raise OnyxError(f"connector {name}: unexpected answer {str(res)[:200]}")
            self.log.info("Onyx: connector %s created (cc_pair %s)", name, cc_pair)
        if existing:
            ids = [c.get("id") for c in existing.get("cc_pair_summaries") or existing.get("cc_pair_descriptors") or []]
            if cc_pair not in ids:
                self._call("PATCH", "/manage/admin/document-set", {
                    "id": existing["id"], "name": name, "description": existing.get("description") or "",
                    "cc_pair_ids": [i for i in ids if isinstance(i, int)] + [cc_pair],
                    "is_public": True, "users": [], "groups": []})
                self.log.info("Onyx: document set %s now contains cc_pair %s", name, cc_pair)
        else:
            self._call("POST", "/manage/admin/document-set", {
                "name": name, "description": f"KIRA – Dokumente des Agenten {label} (Abgleich vom NAS)",
                "cc_pair_ids": [cc_pair], "is_public": True, "users": [], "groups": []})
            self.log.info("Onyx: document set %s created", name)
        return cc_pair

    # -- documents ----------------------------------------------------------------------------------------------
    def upsert(self, cc_pair, doc):
        return self._call("POST", "/onyx-api/ingestion", {"document": doc, "cc_pair_id": cc_pair}, timeout=600)

    def delete(self, doc_id):
        self._call("DELETE", f"/onyx-api/ingestion/{doc_id}", ok=(200, 204, 404))

    # -- search (docs-search, key with READ_SEARCH) ---------------------------------------------------------------
    def search(self, query, document_set):
        data = self._call("POST", "/search", {"query": query, "document_sets": [document_set],
                                              "skip_query_expansion": True}, timeout=90)
        return (data or {}).get("results") or []
