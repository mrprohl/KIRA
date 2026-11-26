package guard

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Decisions
const (
	DecisionExternal = "external" // clean: to Claude/OpenAI as requested
	DecisionLocal    = "local"    // personal/secret data or check failed: local answer model
	DecisionRefuse   = "refuse"   // harmful request, or no local alternative (images, speech, unreadable)
)

// Request is what the adapter hands over from the HTTP request.
type Request struct {
	Path        string
	ContentType string
	Body        []byte
	BodyMissing bool   // Bifrost did not pass the body (too large) – cannot be checked
	VirtualKey  string // virtual key of the caller (x-bf-vk / Authorization: Bearer)
}

// Response is a reply the guard sends instead of forwarding the request.
type Response struct {
	Status      int
	ContentType string
	Body        []byte
}

// Result tells the adapter what to do. All fields nil = forward unchanged.
type Result struct {
	Body     []byte    // rewritten request body
	Response *Response // reply instead of the provider call
	Notice   *Notice   // first line of a locally answered reply
}

// Verdict is the outcome of the checks of one request.
type Verdict struct {
	Decision   string
	Categories []string // privacy categories (slugs) or safety category of a refusal
	Safety     string   // Safe / Controversial / Unsafe / "" (not checked)
	SafetyCats []string
	Failed     bool // a checker failed – fail-closed
	Unreadable bool // content the checkers cannot read (body missing, attached files)
	SelfHarm   bool
	Elapsed    time.Duration
}

// Guard holds configuration and checker (one per plugin instance).
type Guard struct {
	cfg *Config
	chk *checker
	now func() time.Time
	// Logf writes one line per decision (never content); the adapter can replace it
	Logf func(format string, args ...any)
	// wg tracks background checks in observe mode (tests wait for it)
	wg sync.WaitGroup
}

// New creates the guard; client may be nil (default HTTP client, timeouts come from the request context).
func New(cfg *Config, client *http.Client) *Guard {
	return &Guard{cfg: cfg, chk: newChecker(cfg, client), now: time.Now, Logf: log.Printf}
}

// Wait waits for background checks (observe mode) – for tests and shutdown.
func (g *Guard) Wait() { g.wg.Wait() }

// Handle checks one request and returns what to do with it.
func (g *Guard) Handle(ctx context.Context, req Request) Result {
	if !g.cfg.Guarded(req.VirtualKey) {
		return Result{}
	}
	endpoint := EndpointOf(req.Path)
	if endpoint == EndpointNone {
		return Result{}
	}
	var body parsed
	var bodyChanged bool
	isTitle := false
	var pieces []Piece
	lastIsUser := false
	unreadable := req.BodyMissing
	if !unreadable {
		if endpoint == EndpointImage && strings.HasPrefix(strings.ToLower(req.ContentType), "multipart/") {
			prompt, ok := multipartPrompt(req.ContentType, req.Body)
			if !ok {
				unreadable = true
			}
			pieces, lastIsUser = []Piece{{Role: "user", Text: prompt}}, true
		} else {
			var err error
			if body, err = parseJSON(req.Body); err != nil {
				unreadable = true
			} else {
				// titles: LibreChat asks for the alias, the guard picks the real model (external or local), no notice
				if g.cfg.TitleAlias != "" && body.str("model") == g.cfg.TitleAlias {
					isTitle = true
					body["model"] = g.cfg.TitleModel
					bodyChanged = true
				}
				pieces, lastIsUser = extract(endpoint, body)
			}
		}
	}

	finish := func(v Verdict) Result {
		g.logVerdict(endpoint, v, isTitle)
		if g.cfg.Mode != ModeEnforce {
			return Result{}
		}
		return g.act(endpoint, body, v, isTitle, lastIsUser)
	}

	if g.cfg.Mode == ModeObserve {
		// observe: never delay or change the request (except the title alias); check in the background
		var res Result
		if bodyChanged {
			res.Body = mustJSON(body)
		}
		g.wg.Add(1)
		go func() {
			defer g.wg.Done()
			bg, cancel := context.WithTimeout(context.Background(), g.cfg.timeout)
			defer cancel()
			finish(g.check(bg, endpoint, pieces, unreadable))
		}()
		return res
	}

	cctx, cancel := context.WithTimeout(ctx, g.cfg.timeout)
	defer cancel()
	res := finish(g.check(cctx, endpoint, pieces, unreadable))
	if res.Response == nil && res.Body == nil && bodyChanged {
		res.Body = mustJSON(body)
	}
	return res
}

// check runs pattern check, privacy checker and safety checker and decides.
func (g *Guard) check(ctx context.Context, endpoint string, pieces []Piece, unreadable bool) Verdict {
	start := g.now()
	v := Verdict{Unreadable: unreadable}
	cats := map[string]bool{}
	var all []Piece
	for _, p := range pieces {
		if p.Files > 0 {
			v.Unreadable = true
		}
		for _, c := range Patterns(p.Text) {
			cats[c] = true
		}
		all = append(all, chunks(p, g.cfg.MaxChunkChars)...)
	}

	var jobs []job
	for _, p := range all {
		if strings.TrimSpace(p.Text) == "" && len(p.Images) == 0 {
			continue
		}
		jobs = append(jobs, job{p, false})
		// safety: what the user asks (user messages, image prompts, speech text) – not tool results or the system prompt
		if p.Role == "user" && strings.TrimSpace(p.Text) != "" {
			jobs = append(jobs, job{p, true})
		}
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, g.cfg.Concurrency)
	safetyLevel := 0 // 0 none/safe, 1 controversial, 2 unsafe
	safetyCats := map[string]bool{}
	for _, j := range jobs {
		wg.Add(1)
		go func(j job) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				mu.Lock()
				v.Failed = true
				mu.Unlock()
				return
			}
			if j.safety {
				r, err := g.chk.safety(ctx, j.piece)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					v.Failed = true
					g.Logf("privacy-guard: safety checker failed: %v", err)
					return
				}
				lvl := map[string]int{"Safe": 0, "Controversial": 1, "Unsafe": 2}[r.Level]
				if lvl > safetyLevel {
					safetyLevel = lvl
				}
				if lvl > 0 {
					for _, c := range r.Categories {
						safetyCats[c] = true
					}
				}
				return
			}
			r, err := g.chk.privacy(ctx, j.piece)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				v.Failed = true
				g.Logf("privacy-guard: privacy checker failed: %v", err)
				return
			}
			if r.Hit {
				for _, c := range r.Categories {
					cats[c] = true
				}
			}
		}(j)
	}
	wg.Wait()

	v.Safety = []string{"Safe", "Controversial", "Unsafe"}[safetyLevel]
	if !hasJobsOf(jobs, true) {
		v.Safety = ""
	}
	v.SafetyCats = sortedKeys(safetyCats)
	v.Elapsed = g.now().Sub(start)

	// 1. harmful request in a blocked category → refuse
	if safetyLevel == 2 {
		var blocked []string
		for _, c := range v.SafetyCats {
			if g.cfg.block[strings.ToLower(c)] {
				blocked = append(blocked, c)
			}
			if isSelfHarm(c) && g.cfg.block[strings.ToLower(c)] {
				v.SelfHarm = true
			}
		}
		if len(blocked) > 0 {
			v.Decision = DecisionRefuse
			v.Categories = blocked
			return v
		}
	}
	// Qwen3Guard also recognises personal data (category PII) – counts as a privacy hit
	for _, c := range v.SafetyCats {
		if isPII(c) {
			cats["pii"] = true
		}
	}
	v.Categories = sortedKeys(cats)
	switch {
	case len(v.Categories) > 0:
		v.Decision = DecisionLocal
	case v.Failed:
		v.Decision = DecisionLocal
		v.Categories = []string{"check-failed"}
	case v.Unreadable:
		v.Decision = DecisionLocal
		v.Categories = []string{"unreadable"}
	default:
		v.Decision = DecisionExternal
	}
	// images and speech have no local alternative: refuse instead of answering locally
	if v.Decision == DecisionLocal && (endpoint == EndpointImage || endpoint == EndpointSpeech) {
		v.Decision = DecisionRefuse
	}
	// a body the guard did not get cannot be rewritten to the local model either
	if v.Decision == DecisionLocal && unreadable {
		v.Decision = DecisionRefuse
	}
	return v
}

// job is one checker call (privacy or safety) for one piece.
type job struct {
	piece  Piece
	safety bool
}

func hasJobsOf(jobs []job, safety bool) bool {
	for _, j := range jobs {
		if j.safety == safety {
			return true
		}
	}
	return false
}

func isSelfHarm(c string) bool {
	c = strings.ToLower(c)
	return strings.Contains(c, "suicide") || strings.Contains(c, "self-harm")
}

func isPII(c string) bool {
	c = strings.ToLower(c)
	return c == "pii" || strings.Contains(c, "personally identifiable")
}

// act turns a verdict into the action (enforce mode only).
func (g *Guard) act(endpoint string, body parsed, v Verdict, isTitle, lastIsUser bool) Result {
	switch v.Decision {
	case DecisionRefuse:
		return Result{Response: refusal(endpoint, body, refusalText(endpoint, v))}
	case DecisionLocal:
		if body == nil { // cannot happen (unreadable → refuse), defensive
			return Result{Response: refusal(endpoint, body, refusalText(endpoint, v))}
		}
		toLocal(body, g.cfg)
		res := Result{Body: mustJSON(body)}
		if !isTitle && lastIsUser {
			res.Notice = &Notice{Text: noticeText(v)}
		}
		return res
	}
	return Result{}
}

// toLocal rewrites a request to the local answer model: model, no fallbacks, no tools that send data outside.
func toLocal(body parsed, cfg *Config) {
	body["model"] = cfg.AnswerModel
	delete(body, "fallbacks")
	delete(body, "cache_control") // Anthropic prompt caching (LibreChat addParams) – unknown to vLLM
	tools, _ := body["tools"].([]any)
	if tools != nil {
		kept := make([]any, 0, len(tools))
		removed := map[string]bool{}
		for _, t := range tools {
			name := toolName(t)
			if cfg.removeTools[strings.ToLower(name)] {
				removed[name] = true
				continue
			}
			kept = append(kept, t)
		}
		if len(kept) == 0 {
			delete(body, "tools")
			delete(body, "tool_choice")
			delete(body, "parallel_tool_calls")
		} else {
			body["tools"] = kept
			if tc, ok := body["tool_choice"].(map[string]any); ok && removed[toolName(tc)] {
				delete(body, "tool_choice")
			}
		}
	}
}

// toolName: chat format {"type":"function","function":{"name":…}}, responses format {"type":"function","name":…}
// or built-in tools {"type":"web_search"}.
func toolName(t any) string {
	m, _ := t.(map[string]any)
	if m == nil {
		return ""
	}
	if fn, ok := m["function"].(map[string]any); ok {
		if n, ok := fn["name"].(string); ok {
			return n
		}
	}
	if n, ok := m["name"].(string); ok {
		return n
	}
	typ, _ := m["type"].(string)
	if typ != "function" {
		return typ
	}
	return ""
}

func (g *Guard) logVerdict(endpoint string, v Verdict, isTitle bool) {
	kind := endpoint
	if isTitle {
		kind = "title"
	}
	cats := strings.Join(slugs(v.Categories), ",")
	if cats == "" {
		cats = "-"
	}
	sc := strings.Join(slugs(v.SafetyCats), ",")
	if sc == "" {
		sc = "-"
	}
	safety := strings.ToLower(v.Safety)
	if safety == "" {
		safety = "-"
	}
	g.Logf("privacy-guard mode=%s decision=%s endpoint=%s categories=%s safety=%s safety_categories=%s failed=%t ms=%d",
		g.cfg.Mode, v.Decision, kind, cats, safety, sc, v.Failed, v.Elapsed.Milliseconds())
}

// Notice is the first line of a locally answered reply; it is added once (first text of the answer).
type Notice struct {
	Text string
	done atomic.Bool
}

// Take returns true exactly once.
func (n *Notice) Take() bool { return n != nil && n.done.CompareAndSwap(false, true) }

// ApplyToBody adds the notice to a non-streaming reply (chat or responses format); errors of the local model become
// a German message. Returns the new body and whether it changed.
func (n *Notice) ApplyToBody(status int, body []byte) ([]byte, bool) {
	if n == nil || len(body) == 0 {
		return body, false
	}
	m, err := parseJSON(body)
	if err != nil {
		return body, false
	}
	if status >= 400 {
		m["error"] = map[string]any{"message": localUnavailable, "type": "privacy_guard_local_unavailable"}
		return mustJSON(m), true
	}
	if choices, ok := m["choices"].([]any); ok && len(choices) > 0 {
		if c0, ok := choices[0].(map[string]any); ok {
			if msg, ok := c0["message"].(map[string]any); ok {
				if s, ok := msg["content"].(string); ok && n.Take() {
					msg["content"] = n.Text + s
					return mustJSON(m), true
				}
			}
		}
	}
	if out, ok := m["output"].([]any); ok {
		for _, item := range out {
			im, _ := item.(map[string]any)
			if im == nil || im["type"] != "message" {
				continue
			}
			parts, _ := im["content"].([]any)
			for _, p := range parts {
				pm, _ := p.(map[string]any)
				if pm != nil && pm["type"] == "output_text" {
					if s, ok := pm["text"].(string); ok && n.Take() {
						pm["text"] = n.Text + s
						return mustJSON(m), true
					}
				}
			}
		}
	}
	return body, false
}

// Texts shown to the user (German)
const (
	localUnavailable = "Das lokale Modell ist gerade nicht erreichbar. Deine Anfrage enthielt schützenswerte Daten und " +
		"wurde deshalb nicht nach außen gesendet. Bitte versuche es später noch einmal."
	selfHarmText = "Es klingt, als ginge es dir gerade nicht gut. Damit musst du nicht allein bleiben: Die Telefonseelsorge " +
		"ist rund um die Uhr kostenlos und anonym erreichbar unter 0800 111 0 111 oder 0800 111 0 222, auch per Chat " +
		"auf online.telefonseelsorge.de. Wenn du in akuter Gefahr bist, ruf bitte den Notruf 112 an. " +
		"Sprich auch gern mit einem Menschen, dem du vertraust."
)

var labels = map[string]string{
	"iban": "IBAN", "credit_card": "Kartennummer", "email": "E-Mail-Adresse", "phone": "Telefonnummer",
	"private_key": "privater Schlüssel", "api_key": "API-Schlüssel", "password": "Passwort",
	"name": "Namen", "address": "Adresse", "birth_date": "Geburtsdatum", "id_number": "Ausweis- oder Kundennummer",
	"bank": "Bankdaten", "health": "Gesundheitsdaten", "salary": "Gehaltsdaten", "child": "Daten über Kinder",
	"photo_of_person": "Foto einer Person", "document_image": "Foto eines Dokuments", "internal_system": "interne Systemdaten",
	"confidential": "vertrauliche Inhalte", "other": "personenbezogene Daten", "pii": "personenbezogene Daten",
	"violent": "Gewalt", "non-violent illegal acts": "illegale Handlungen", "sexual content or sexual acts": "sexuelle Inhalte",
	"suicide & self-harm": "Suizid oder Selbstverletzung", "unethical acts": "unethisches Handeln",
	"politically sensitive topics": "politisch heikle Themen", "copyright violation": "Urheberrecht",
	"jailbreak": "Umgehungsversuch (Jailbreak)",
}

func label(c string) string {
	if l, ok := labels[strings.ToLower(c)]; ok {
		return l
	}
	return c
}

func labelList(cats []string) string {
	seen := map[string]bool{}
	var out []string
	for _, c := range cats {
		l := label(c)
		if !seen[l] {
			seen[l] = true
			out = append(out, l)
		}
	}
	return strings.Join(out, ", ")
}

func noticeText(v Verdict) string {
	if len(v.Categories) == 1 && (v.Categories[0] == "check-failed" || v.Categories[0] == "unreadable") {
		return "⚠️ Lokal beantwortet – die Datenschutzprüfung war nicht möglich, deshalb hat deine Anfrage das Haus nicht verlassen.\n\n"
	}
	return fmt.Sprintf("⚠️ Lokal beantwortet – deine Anfrage enthielt %s. Sie hat das Haus nicht verlassen.\n\n", labelList(v.Categories))
}

func refusalText(endpoint string, v Verdict) string {
	if v.SelfHarm {
		return selfHarmText
	}
	if v.Safety == "Unsafe" && len(v.Categories) > 0 && !isPrivacyCategory(v.Categories[0]) {
		return fmt.Sprintf("Diese Anfrage kann ich nicht bearbeiten – die Sicherheitsprüfung von KIRA hat sie abgelehnt (%s).",
			labelList(v.Categories))
	}
	if v.Unreadable && (len(v.Categories) == 0 || v.Categories[0] == "unreadable") {
		return "Diese Anfrage konnte nicht auf personenbezogene Daten geprüft werden (zu groß oder nicht lesbar) und " +
			"wurde deshalb nicht gesendet."
	}
	what := "Bilder"
	if endpoint == EndpointSpeech {
		what = "Sprachausgabe"
	}
	if len(v.Categories) == 1 && v.Categories[0] == "check-failed" {
		return fmt.Sprintf("Die Datenschutzprüfung ist gerade nicht erreichbar. %s gibt es nur über externe Anbieter, "+
			"deshalb wurde die Anfrage nicht gesendet.", what)
	}
	if endpoint == EndpointImage || endpoint == EndpointSpeech {
		return fmt.Sprintf("Diese Anfrage enthält %s. %s gibt es nur über externe Anbieter, deshalb wurde sie nicht gesendet.",
			labelList(v.Categories), what)
	}
	return fmt.Sprintf("Diese Anfrage enthält %s und konnte nicht lokal beantwortet werden.", labelList(v.Categories))
}

func isPrivacyCategory(c string) bool {
	for _, p := range privacyCategories {
		if p == c {
			return true
		}
	}
	switch c {
	case "iban", "credit_card", "pii", "check-failed", "unreadable":
		return true
	}
	return false
}

// slugs: short names for the log (Qwen3Guard names → violent, illegal …)
func slugs(cats []string) []string {
	m := map[string]string{"violent": "violent", "non-violent illegal acts": "illegal", "sexual content or sexual acts": "sexual",
		"suicide & self-harm": "self-harm", "unethical acts": "unethical", "politically sensitive topics": "political",
		"copyright violation": "copyright", "jailbreak": "jailbreak", "pii": "pii", "personally identifiable information": "pii"}
	out := make([]string, 0, len(cats))
	for _, c := range cats {
		if s, ok := m[strings.ToLower(c)]; ok {
			out = append(out, s)
		} else {
			out = append(out, strings.ReplaceAll(strings.ToLower(c), " ", "-"))
		}
	}
	return out
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err) // cannot happen for values parsed from JSON
	}
	return b
}
