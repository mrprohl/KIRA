package guard

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// privacyPrompt is the instruction of the privacy checker (a general Qwen model with structured output).
const privacyPrompt = `You check whether a text may be sent to an external AI provider (Anthropic, OpenAI).
Decide whether the text or image contains PERSONAL DATA or SECRET DATA.

Personal data: data about an identifiable private person – name together with other details, postal address,
phone number, e-mail address, date of birth, ID/tax/social-security/insurance/customer/contract number, bank or card
data, health data, salary, data about children, photos of identifiable persons, photos or scans of documents
(ID card, letters, invoices, certificates).
Secret data: passwords, API keys, tokens, private keys, access data, internal host names or IP addresses together with
access data, documents marked as confidential or internal.

NOT a hit: public figures, companies and authorities in general questions; general knowledge; code without secrets;
clearly fictitious example data (Max Mustermann, example.com); the user's request to write a text without real data.

The text may be German. Answer only with the JSON object.`

var privacyCategories = []string{"name", "address", "phone", "email", "birth_date", "id_number", "bank", "health",
	"salary", "child", "photo_of_person", "document_image", "password", "api_key", "private_key", "internal_system",
	"confidential", "other"}

// Piece is one part of a request that is checked on its own (one message, a prompt, an instruction …).
type Piece struct {
	Role   string   // system, user, assistant, tool, prompt
	Text   string   // text (empty if only images)
	Images []string // image URLs (data: or https:)
	Files  int      // attached files the checkers cannot read
}

func (p Piece) hash() string {
	h := sha256.New()
	h.Write([]byte(p.Text))
	for _, im := range p.Images {
		h.Write([]byte{0})
		h.Write([]byte(im))
	}
	return hex.EncodeToString(h.Sum(nil))
}

// PrivacyResult / SafetyResult of one piece
type PrivacyResult struct {
	Hit        bool
	Categories []string
}

type SafetyResult struct {
	Level      string   // Safe, Controversial, Unsafe
	Categories []string // Qwen3Guard categories (original names)
}

// checker calls the two vLLM checkers and caches the results per piece (hash → result, 24 h, in memory only).
type checker struct {
	cfg    *Config
	client *http.Client

	mu    sync.Mutex
	cache map[string]cacheEntry
}

type cacheEntry struct {
	at      time.Time
	privacy *PrivacyResult
	safety  *SafetyResult
}

const (
	cacheTTL = 24 * time.Hour
	cacheMax = 50000
)

func newChecker(cfg *Config, client *http.Client) *checker {
	if client == nil {
		client = &http.Client{}
	}
	return &checker{cfg: cfg, client: client, cache: map[string]cacheEntry{}}
}

func (c *checker) cached(key string) (cacheEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.cache[key]
	if ok && time.Since(e.at) > cacheTTL {
		delete(c.cache, key)
		return cacheEntry{}, false
	}
	return e, ok
}

func (c *checker) store(key string, update func(*cacheEntry)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.cache) >= cacheMax { // simple bound: start over (results are cheap to compute again)
		c.cache = map[string]cacheEntry{}
	}
	e := c.cache[key]
	update(&e)
	e.at = time.Now()
	c.cache[key] = e
}

// chatCall posts an OpenAI chat completion to a vLLM server and returns the text of the answer.
func (c *checker) chatCall(ctx context.Context, baseURL string, body map[string]any) (string, error) {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.cfg.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.cfg.apiKey)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d from %s: %s", resp.StatusCode, baseURL, truncate(string(data), 200))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &out); err != nil || len(out.Choices) == 0 {
		return "", fmt.Errorf("unexpected answer from %s: %s", baseURL, truncate(string(data), 200))
	}
	return out.Choices[0].Message.Content, nil
}

// privacy checks one piece with the privacy checker (structured JSON output).
func (c *checker) privacy(ctx context.Context, p Piece) (*PrivacyResult, error) {
	key := "p:" + p.hash()
	if e, ok := c.cached(key); ok && e.privacy != nil {
		return e.privacy, nil
	}
	content := []map[string]any{{"type": "text", "text": "TEXT TO CHECK:\n\n" + p.Text}}
	for _, im := range p.Images {
		content = append(content, map[string]any{"type": "image_url", "image_url": map[string]any{"url": im}})
	}
	schema := map[string]any{
		"type": "object",
		"properties": map[string]any{
			"personal_data": map[string]any{"type": "boolean"},
			"secret":        map[string]any{"type": "boolean"},
			"categories":    map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": privacyCategories}},
		},
		"required":             []string{"personal_data", "secret", "categories"},
		"additionalProperties": false,
	}
	text, err := c.chatCall(ctx, c.cfg.PrivacyURL, map[string]any{
		"model":       c.cfg.PrivacyModel,
		"messages":    []map[string]any{{"role": "system", "content": privacyPrompt}, {"role": "user", "content": content}},
		"temperature": 0,
		"max_tokens":  200,
		"response_format": map[string]any{"type": "json_schema",
			"json_schema": map[string]any{"name": "privacy_check", "schema": schema, "strict": true}},
		"chat_template_kwargs": map[string]any{"enable_thinking": false},
	})
	if err != nil {
		return nil, err
	}
	res, err := parsePrivacy(text)
	if err != nil {
		return nil, err
	}
	c.store(key, func(e *cacheEntry) { e.privacy = res })
	return res, nil
}

func parsePrivacy(text string) (*PrivacyResult, error) {
	text = strings.TrimSpace(text)
	if i := strings.Index(text, "{"); i > 0 { // tolerate text around the object
		text = text[i:]
	}
	if j := strings.LastIndex(text, "}"); j >= 0 {
		text = text[:j+1]
	}
	var v struct {
		Personal   bool     `json:"personal_data"`
		Secret     bool     `json:"secret"`
		Categories []string `json:"categories"`
	}
	if err := json.Unmarshal([]byte(text), &v); err != nil {
		return nil, fmt.Errorf("privacy checker: no valid JSON: %s", truncate(text, 120))
	}
	res := &PrivacyResult{Hit: v.Personal || v.Secret}
	seen := map[string]bool{}
	for _, cat := range v.Categories {
		cat = strings.ToLower(strings.TrimSpace(cat))
		if cat != "" && !seen[cat] {
			seen[cat] = true
			res.Categories = append(res.Categories, cat)
		}
	}
	if res.Hit && len(res.Categories) == 0 {
		if v.Secret {
			res.Categories = []string{"confidential"}
		} else {
			res.Categories = []string{"other"}
		}
	}
	if !res.Hit {
		res.Categories = nil
	}
	return res, nil
}

var (
	reSafety     = regexp.MustCompile(`(?i)Safety:\s*(Safe|Unsafe|Controversial)`)
	reCategories = regexp.MustCompile(`(?i)Categories:\s*(.+)`)
)

// safety checks one piece with Qwen3Guard-Gen (answer: "Safety: …" and "Categories: …").
func (c *checker) safety(ctx context.Context, p Piece) (*SafetyResult, error) {
	key := "s:" + p.hash()
	if e, ok := c.cached(key); ok && e.safety != nil {
		return e.safety, nil
	}
	text, err := c.chatCall(ctx, c.cfg.SafetyURL, map[string]any{
		"model":       c.cfg.SafetyModel,
		"messages":    []map[string]any{{"role": "user", "content": p.Text}},
		"temperature": 0,
		"max_tokens":  64,
	})
	if err != nil {
		return nil, err
	}
	res, err := parseSafety(text)
	if err != nil {
		return nil, err
	}
	c.store(key, func(e *cacheEntry) { e.safety = res })
	return res, nil
}

func parseSafety(text string) (*SafetyResult, error) {
	m := reSafety.FindStringSubmatch(text)
	if m == nil {
		return nil, fmt.Errorf("safety checker: unexpected answer: %s", truncate(text, 120))
	}
	res := &SafetyResult{Level: strings.Title(strings.ToLower(m[1]))} //nolint:staticcheck // ASCII only
	if c := reCategories.FindStringSubmatch(text); c != nil {
		for _, cat := range strings.Split(c[1], ",") {
			cat = strings.TrimSpace(cat)
			if cat != "" && !strings.EqualFold(cat, "None") {
				res.Categories = append(res.Categories, cat)
			}
		}
	}
	return res, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
