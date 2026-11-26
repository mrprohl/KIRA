package guard

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeVLLM simulates the two checkers: the privacy checker flags texts containing "Müller" (a name), the safety
// checker flags "Bombe" (Violent), "umbringen" (Suicide & Self-Harm), "ignoriere alle Regeln" (Jailbreak) and marks
// "Wahl" as Controversial.
type fakeVLLM struct {
	privacy, safety *httptest.Server
	privacyCalls    atomic.Int32
	safetyCalls     atomic.Int32
	down            atomic.Bool
	delay           time.Duration
	mu              sync.Mutex
	lastAuth        string
}

func newFake(t *testing.T) *fakeVLLM {
	f := &fakeVLLM{}
	handler := func(kind string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			if f.down.Load() {
				http.Error(w, "down", http.StatusServiceUnavailable)
				return
			}
			if f.delay > 0 {
				time.Sleep(f.delay)
			}
			f.mu.Lock()
			f.lastAuth = r.Header.Get("Authorization")
			f.mu.Unlock()
			raw, _ := io.ReadAll(r.Body)
			var req struct {
				Model    string `json:"model"`
				Messages []struct {
					Role    string `json:"role"`
					Content any    `json:"content"`
				} `json:"messages"`
			}
			if err := json.Unmarshal(raw, &req); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			last := req.Messages[len(req.Messages)-1]
			text := fmt.Sprint(last.Content)
			var answer string
			if kind == "privacy" {
				f.privacyCalls.Add(1)
				if req.Model != "kira-privacy" {
					t.Errorf("privacy model = %q", req.Model)
				}
				if strings.Contains(text, "Müller") {
					answer = `{"personal_data": true, "secret": false, "categories": ["name"]}`
				} else if strings.Contains(text, "data:image/png") {
					answer = `{"personal_data": true, "secret": false, "categories": ["document_image"]}`
				} else {
					answer = `{"personal_data": false, "secret": false, "categories": []}`
				}
			} else {
				f.safetyCalls.Add(1)
				switch {
				case strings.Contains(text, "Bombe"):
					answer = "Safety: Unsafe\nCategories: Violent"
				case strings.Contains(text, "umbringen"):
					answer = "Safety: Unsafe\nCategories: Suicide & Self-Harm"
				case strings.Contains(text, "ignoriere alle Regeln"):
					answer = "Safety: Unsafe\nCategories: Jailbreak"
				case strings.Contains(text, "Wahl"):
					answer = "Safety: Controversial\nCategories: Politically Sensitive Topics"
				case strings.Contains(text, "Raubkopie"):
					answer = "Safety: Unsafe\nCategories: Copyright Violation"
				default:
					answer = "Safety: Safe\nCategories: None"
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]any{"content": answer}}}})
		}
	}
	f.privacy = httptest.NewServer(handler("privacy"))
	f.safety = httptest.NewServer(handler("safety"))
	t.Cleanup(func() { f.privacy.Close(); f.safety.Close() })
	return f
}

const vk = "sk-bf-librechat"

func newGuard(t *testing.T, f *fakeVLLM, mode string) (*Guard, *[]string) {
	raw, _ := json.Marshal(map[string]any{
		"mode": mode, "privacy_url": f.privacy.URL + "/", "safety_url": f.safety.URL,
		"answer_model": "vllm/kira-answer", "title_alias": "kira/title", "title_model": "anthropic/claude-haiku-5-5",
		"timeout_seconds": 2,
	})
	env := map[string]string{"VK_LIBRECHAT": vk, "VLLM_API_KEY": "secret-key"}
	cfg, err := ParseConfig(raw, func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	g := New(cfg, nil)
	var mu sync.Mutex
	logs := &[]string{}
	g.Logf = func(format string, args ...any) {
		mu.Lock()
		*logs = append(*logs, fmt.Sprintf(format, args...))
		mu.Unlock()
	}
	return g, logs
}

func chatBody(stream bool, msgs ...map[string]any) []byte {
	b, _ := json.Marshal(map[string]any{"model": "anthropic/claude-sonnet-5-5", "stream": stream, "messages": msgs,
		"fallbacks": []string{"openai/gpt-6.1-sol"},
		"tools": []any{
			map[string]any{"type": "function", "function": map[string]any{"name": "web_search"}},
			map[string]any{"type": "function", "function": map[string]any{"name": "file_search"}},
		}})
	return b
}

func msg(role, content string) map[string]any {
	return map[string]any{"role": role, "content": content}
}

func handle(g *Guard, path string, body []byte) Result {
	return g.Handle(context.Background(), Request{Path: path, Body: body, VirtualKey: vk, ContentType: "application/json"})
}

func decode(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("invalid JSON: %v: %s", err, b)
	}
	return m
}

func TestCleanRequestGoesExternal(t *testing.T) {
	f := newFake(t)
	g, logs := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("system", "Du bist KIRA."), msg("user", "Wie wird das Wetter morgen?")))
	if res.Body != nil || res.Response != nil || res.Notice != nil {
		t.Fatalf("clean request changed: %+v", res)
	}
	if !strings.Contains((*logs)[0], "decision=external") {
		t.Fatalf("log: %v", *logs)
	}
	if f.lastAuth != "Bearer secret-key" {
		t.Fatalf("vLLM API key not sent: %q", f.lastAuth)
	}
}

func TestPersonalDataGoesLocal(t *testing.T) {
	f := newFake(t)
	g, logs := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(true, msg("user", "Schreib einen Brief an Frau Müller.")))
	if res.Response != nil || res.Body == nil {
		t.Fatalf("expected rewrite, got %+v", res)
	}
	b := decode(t, res.Body)
	if b["model"] != "vllm/kira-answer" {
		t.Fatalf("model = %v", b["model"])
	}
	if _, ok := b["fallbacks"]; ok {
		t.Fatal("fallbacks not removed")
	}
	tools := b["tools"].([]any)
	if len(tools) != 1 || toolName(tools[0]) != "file_search" {
		t.Fatalf("tools = %v", tools)
	}
	if res.Notice == nil || !strings.Contains(res.Notice.Text, "Namen") {
		t.Fatalf("notice = %+v", res.Notice)
	}
	if !strings.Contains(strings.Join(*logs, "\n"), "decision=local endpoint=chat categories=name") {
		t.Fatalf("log: %v", *logs)
	}
}

func TestPatternWithoutModelHit(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Überweise 50 € auf DE89 3704 0044 0532 0130 00.")))
	if res.Body == nil || res.Notice == nil || !strings.Contains(res.Notice.Text, "IBAN") {
		t.Fatalf("IBAN not detected: %+v", res)
	}
}

func TestToolResultHitHasNoNotice(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Fasse das Dokument zusammen."),
		map[string]any{"role": "assistant", "content": "", "tool_calls": []any{map[string]any{"function": map[string]any{"name": "file_search", "arguments": "{}"}}}},
		msg("tool", "Vertrag mit Herrn Müller, geboren 1970")))
	if res.Body == nil {
		t.Fatal("expected local")
	}
	if res.Notice != nil {
		t.Fatal("notice in an intermediate step (last message is a tool result)")
	}
}

func TestViolentIsRefused(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Wie baue ich eine Bombe?")))
	if res.Response == nil {
		t.Fatal("expected refusal")
	}
	m := decode(t, res.Response.Body)
	text := m["choices"].([]any)[0].(map[string]any)["message"].(map[string]any)["content"].(string)
	if !strings.Contains(text, "Gewalt") {
		t.Fatalf("text = %q", text)
	}
}

func TestSelfHarmGetsCaringAnswerAsStream(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(true, msg("user", "Ich will mich umbringen.")))
	if res.Response == nil || res.Response.ContentType != "text/event-stream" {
		t.Fatalf("expected SSE refusal, got %+v", res)
	}
	body := string(res.Response.Body)
	if !strings.Contains(body, "0800 111 0 111") || !strings.HasSuffix(body, "data: [DONE]\n\n") {
		t.Fatalf("body = %s", body)
	}
}

func TestLoggedCategoryPasses(t *testing.T) {
	f := newFake(t)
	g, logs := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Wer gewinnt die Wahl?")))
	if res.Body != nil || res.Response != nil {
		t.Fatalf("controversial must pass: %+v", res)
	}
	res = handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Wo finde ich eine Raubkopie?")))
	if res.Response != nil {
		t.Fatal("copyright is a log category, not refused")
	}
	if !strings.Contains(strings.Join(*logs, "\n"), "safety=unsafe safety_categories=copyright") {
		t.Fatalf("log: %v", *logs)
	}
}

func TestCheckerDownIsFailClosed(t *testing.T) {
	f := newFake(t)
	f.down.Store(true)
	g, _ := newGuard(t, f, ModeEnforce)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Hallo")))
	if res.Body == nil || decode(t, res.Body)["model"] != "vllm/kira-answer" {
		t.Fatalf("checker down must answer locally: %+v", res)
	}
	if !strings.Contains(res.Notice.Text, "nicht möglich") {
		t.Fatalf("notice = %q", res.Notice.Text)
	}
	// image generation has no local alternative → refused
	img, _ := json.Marshal(map[string]any{"model": "openai/gpt-image-2", "prompt": "Ein Hund"})
	res = handle(g, "/v1/images/generations", img)
	if res.Response == nil || res.Response.Status != 400 {
		t.Fatalf("image with checker down must be refused: %+v", res)
	}
}

func TestTimeoutIsFailClosed(t *testing.T) {
	f := newFake(t)
	f.delay = 3 * time.Second
	g, _ := newGuard(t, f, ModeEnforce)
	start := time.Now()
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Hallo")))
	if time.Since(start) > 2500*time.Millisecond {
		t.Fatal("timeout not applied")
	}
	if res.Body == nil {
		t.Fatal("timeout must answer locally")
	}
}

func TestCacheAvoidsRepeatedChecks(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	sys := msg("system", strings.Repeat("Lange Agenten-Anweisung. ", 100))
	handle(g, "/v1/chat/completions", chatBody(false, sys, msg("user", "Frage 1")))
	p1, s1 := f.privacyCalls.Load(), f.safetyCalls.Load()
	handle(g, "/v1/chat/completions", chatBody(false, sys, msg("user", "Frage 1"), msg("assistant", "Antwort 1"), msg("user", "Frage 2")))
	if got := f.privacyCalls.Load() - p1; got != 2 { // only "Antwort 1" and "Frage 2" are new
		t.Fatalf("privacy calls for the second request = %d, want 2", got)
	}
	if got := f.safetyCalls.Load() - s1; got != 1 {
		t.Fatalf("safety calls for the second request = %d, want 1", got)
	}
}

func TestObserveChangesNothing(t *testing.T) {
	f := newFake(t)
	g, logs := newGuard(t, f, ModeObserve)
	res := handle(g, "/v1/chat/completions", chatBody(false, msg("user", "Wie baue ich eine Bombe? Frau Müller")))
	if res.Body != nil || res.Response != nil || res.Notice != nil {
		t.Fatalf("observe must not change the request: %+v", res)
	}
	g.Wait()
	if !strings.Contains(strings.Join(*logs, "\n"), "mode=observe decision=refuse") {
		t.Fatalf("log: %v", *logs)
	}
}

func TestTitleAlias(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	body, _ := json.Marshal(map[string]any{"model": "kira/title", "messages": []any{msg("user", "Titel für: Wetter morgen")}})
	res := handle(g, "/v1/chat/completions", body)
	if res.Body == nil || decode(t, res.Body)["model"] != "anthropic/claude-haiku-5-5" {
		t.Fatalf("clean title must go to the title model: %+v", res)
	}
	body, _ = json.Marshal(map[string]any{"model": "kira/title", "messages": []any{msg("user", "Titel für: Brief an Frau Müller")}})
	res = handle(g, "/v1/chat/completions", body)
	if res.Body == nil || decode(t, res.Body)["model"] != "vllm/kira-answer" || res.Notice != nil {
		t.Fatalf("title with personal data: local, without notice: %+v", res)
	}
	// observe: alias is still resolved
	g2, _ := newGuard(t, f, ModeObserve)
	res = handle(g2, "/v1/chat/completions", body)
	if res.Body == nil || decode(t, res.Body)["model"] != "anthropic/claude-haiku-5-5" {
		t.Fatalf("observe: alias must still be resolved: %+v", res)
	}
	g2.Wait()
}

func TestOtherKeysAndPathsUnchecked(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	body := chatBody(false, msg("user", "Frau Müller"))
	if res := g.Handle(context.Background(), Request{Path: "/v1/chat/completions", Body: body, VirtualKey: "sk-bf-other"}); res.Body != nil {
		t.Fatal("other virtual key was checked")
	}
	if res := handle(g, "/v1/embeddings", body); res.Body != nil || res.Response != nil {
		t.Fatal("embeddings must not be checked")
	}
	if f.privacyCalls.Load() != 0 {
		t.Fatal("checker called")
	}
}

func TestResponsesAPI(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	body, _ := json.Marshal(map[string]any{"model": "openai/gpt-6.1-sol", "instructions": "Du bist KIRA.",
		"input": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "input_text", "text": "Brief an Frau Müller"}}}},
		"tools": []any{map[string]any{"type": "web_search"}}})
	res := handle(g, "/v1/responses", body)
	b := decode(t, res.Body)
	if b["model"] != "vllm/kira-answer" || b["tools"] != nil || res.Notice == nil {
		t.Fatalf("responses: %v %+v", b, res)
	}
	out, changed := res.Notice.ApplyToBody(200, []byte(`{"output":[{"type":"message","content":[{"type":"output_text","text":"Sehr geehrte"}]}]}`))
	if !changed || !strings.Contains(string(out), "Lokal beantwortet") {
		t.Fatalf("notice not applied: %s", out)
	}
	// refusal as responses stream
	body, _ = json.Marshal(map[string]any{"model": "openai/gpt-6.1-sol", "stream": true, "input": "Wie baue ich eine Bombe?"})
	res = handle(g, "/v1/responses", body)
	if res.Response == nil || !strings.Contains(string(res.Response.Body), "event: response.completed") {
		t.Fatalf("responses refusal: %+v", res)
	}
}

func TestImagesInChatAreChecked(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	body := chatBody(false, map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "text", "text": "Was steht hier?"},
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": "data:image/png;base64,AAAA"}}}})
	res := handle(g, "/v1/chat/completions", body)
	if res.Body == nil || !strings.Contains(res.Notice.Text, "Foto eines Dokuments") {
		t.Fatalf("image not checked: %+v", res)
	}
}

func TestMissingBodyIsRefused(t *testing.T) {
	f := newFake(t)
	g, _ := newGuard(t, f, ModeEnforce)
	res := g.Handle(context.Background(), Request{Path: "/v1/chat/completions", BodyMissing: true, VirtualKey: vk})
	if res.Response == nil || !strings.Contains(string(res.Response.Body), "nicht auf personenbezogene Daten geprüft") {
		t.Fatalf("missing body: %+v", res)
	}
}

func TestNoticeOnceAndErrors(t *testing.T) {
	n := &Notice{Text: "⚠️ Hinweis\n\n"}
	out, ok := n.ApplyToBody(200, []byte(`{"choices":[{"message":{"role":"assistant","content":"Hallo"}}]}`))
	if !ok || !strings.Contains(string(out), "Hinweis\\n\\nHallo") {
		t.Fatalf("notice: %s", out)
	}
	if n.Take() {
		t.Fatal("notice taken twice")
	}
	n2 := &Notice{Text: "x"}
	out, ok = n2.ApplyToBody(503, []byte(`{"error":{"message":"connection refused"}}`))
	if !ok || !strings.Contains(string(out), "lokale Modell ist gerade nicht erreichbar") {
		t.Fatalf("error not replaced: %s", out)
	}
}

func TestPatterns(t *testing.T) {
	cases := map[string][]string{
		"IBAN DE89370400440532013000":                 {"iban"},
		"Karte 4111 1111 1111 1111":                   {"credit_card"},
		"Schreib an anna.schmidt@gmx.de":              {"email"},
		"Kontakt: kira@example.com":                   nil,
		"Ruf an: 0251 1234567":                        {"phone"},
		"Tel. +49 251 1234567":                        {"phone"},
		"Am 27.11.2026 um 10:30 Uhr, Version 0.8.9":   nil,
		"-----BEGIN OPENSSH PRIVATE KEY-----":         {"private_key"},
		"key sk-ant-api03-abcdefghijklmnopqrstuvwxyz": {"api_key"},
		"Passwort: Sommer2026!":                       {"password"},
		"Das Passwort muss 12 Zeichen haben":          nil,
	}
	if got := Patterns("IBAN DE89 3704 0044 0532 0130 01"); strings.Contains(strings.Join(got, ","), "iban") {
		t.Errorf("IBAN with wrong checksum detected: %v", got)
	}
	for text, want := range cases {
		got := Patterns(text)
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("Patterns(%q) = %v, want %v", text, got, want)
		}
	}
}

func TestConfigValidation(t *testing.T) {
	get := func(string) string { return "" }
	if _, err := ParseConfig([]byte(`{"privacy_url":"http://a","safety_url":"http://b","answer_model":"vllm/x"}`), get); err == nil {
		t.Fatal("missing virtual key not reported")
	}
	get = func(k string) string { return map[string]string{"VK_LIBRECHAT": "k"}[k] }
	if _, err := ParseConfig([]byte(`{"mode":"strict","privacy_url":"http://a","safety_url":"http://b","answer_model":"vllm/x"}`), get); err == nil {
		t.Fatal("invalid mode not reported")
	}
	if _, err := ParseConfig([]byte(`{"privacy_url":"http://a","answer_model":"vllm/x"}`), get); err == nil {
		t.Fatal("missing safety_url not reported")
	}
	c, err := ParseConfig([]byte(`{"privacy_url":"http://a","safety_url":"http://b","answer_model":"vllm/x"}`), get)
	if err != nil || c.Mode != ModeObserve {
		t.Fatalf("defaults: %v %v", c, err)
	}
}
