// Package guard is the logic of the KIRA privacy guard: it checks a request that is about to leave the house
// (pattern check, privacy checker, safety checker on vLLM), decides (refuse / answer locally / external) and
// rewrites the request or builds the reply. It only uses the standard library, so it can be tested without Bifrost;
// the Bifrost adapter is ../main.go.
package guard

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Modes
const (
	ModeObserve = "observe" // decide and log, change nothing (checks run in the background)
	ModeEnforce = "enforce" // refuse / answer locally
)

// Config is the plugin configuration from bifrost.json ("plugins" → "config"); secrets come from the environment.
type Config struct {
	Mode            string   `json:"mode"`
	PrivacyURL      string   `json:"privacy_url"`      // vLLM base URL of the privacy checker, e.g. http://10.0.0.50:8101
	PrivacyModel    string   `json:"privacy_model"`    // served model name, e.g. kira-privacy
	SafetyURL       string   `json:"safety_url"`       // vLLM base URL of the safety checker (Qwen3Guard-Gen)
	SafetyModel     string   `json:"safety_model"`     // served model name, e.g. kira-safety
	AnswerModel     string   `json:"answer_model"`     // Bifrost model ID for local answers, e.g. vllm/kira-answer
	TitleAlias      string   `json:"title_alias"`      // model name LibreChat uses for titles, e.g. kira/title
	TitleModel      string   `json:"title_model"`      // external title model, e.g. anthropic/claude-haiku-5-5
	APIKeyEnv       string   `json:"api_key_env"`      // environment variable with the vLLM API key
	GuardedKeyEnvs  []string `json:"guarded_key_envs"` // environment variables with the virtual keys that are checked
	TimeoutSeconds  int      `json:"timeout_seconds"`
	BlockCategories []string `json:"block_categories"` // Qwen3Guard categories that are refused
	LogCategories   []string `json:"log_categories"`   // Qwen3Guard categories that are only counted
	RemoveTools     []string `json:"remove_tools"`     // tools removed from locally answered requests
	Concurrency     int      `json:"concurrency"`      // parallel checker calls per request
	MaxChunkChars   int      `json:"max_chunk_chars"`  // text per checker call

	apiKey      string
	guardedKeys map[string]bool
	timeout     time.Duration
	block, log  map[string]bool
	removeTools map[string]bool
}

// ParseConfig reads the configuration (JSON) and resolves the secrets with getenv.
func ParseConfig(raw []byte, getenv func(string) string) (*Config, error) {
	c := &Config{}
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, c); err != nil {
			return nil, fmt.Errorf("privacy-guard: invalid configuration: %w", err)
		}
	}
	if c.Mode == "" {
		c.Mode = ModeObserve
	}
	if c.Mode != ModeObserve && c.Mode != ModeEnforce {
		return nil, fmt.Errorf("privacy-guard: mode must be %q or %q, not %q", ModeObserve, ModeEnforce, c.Mode)
	}
	for name, v := range map[string]string{"privacy_url": c.PrivacyURL, "safety_url": c.SafetyURL, "answer_model": c.AnswerModel} {
		if v == "" {
			return nil, fmt.Errorf("privacy-guard: %s is missing", name)
		}
	}
	c.PrivacyURL = strings.TrimRight(c.PrivacyURL, "/")
	c.SafetyURL = strings.TrimRight(c.SafetyURL, "/")
	if c.PrivacyModel == "" {
		c.PrivacyModel = "kira-privacy"
	}
	if c.SafetyModel == "" {
		c.SafetyModel = "kira-safety"
	}
	if c.APIKeyEnv == "" {
		c.APIKeyEnv = "VLLM_API_KEY"
	}
	c.apiKey = getenv(c.APIKeyEnv)
	if len(c.GuardedKeyEnvs) == 0 {
		c.GuardedKeyEnvs = []string{"VK_LIBRECHAT"}
	}
	c.guardedKeys = map[string]bool{}
	for _, env := range c.GuardedKeyEnvs {
		if v := strings.TrimSpace(getenv(env)); v != "" {
			c.guardedKeys[v] = true
		}
	}
	if len(c.guardedKeys) == 0 {
		return nil, fmt.Errorf("privacy-guard: none of %v is set – no virtual key to check", c.GuardedKeyEnvs)
	}
	if c.TimeoutSeconds <= 0 {
		c.TimeoutSeconds = 8
	}
	c.timeout = time.Duration(c.TimeoutSeconds) * time.Second
	if c.BlockCategories == nil {
		c.BlockCategories = []string{"Violent", "Non-violent Illegal Acts", "Sexual Content or Sexual Acts", "Suicide & Self-Harm", "Jailbreak"}
	}
	if c.LogCategories == nil {
		c.LogCategories = []string{"Unethical Acts", "Politically Sensitive Topics", "Copyright Violation"}
	}
	c.block, c.log = lowerSet(c.BlockCategories), lowerSet(c.LogCategories)
	if c.RemoveTools == nil {
		c.RemoveTools = []string{"web_search", "image_gen_oai", "image_edit_oai", "dalle", "flux", "stable-diffusion", "image_generation"}
	}
	c.removeTools = lowerSet(c.RemoveTools)
	if c.Concurrency <= 0 {
		c.Concurrency = 8
	}
	if c.MaxChunkChars <= 0 {
		c.MaxChunkChars = 8000
	}
	return c, nil
}

func lowerSet(list []string) map[string]bool {
	m := make(map[string]bool, len(list))
	for _, s := range list {
		m[strings.ToLower(strings.TrimSpace(s))] = true
	}
	return m
}

// Guarded reports whether requests with this virtual key are checked.
func (c *Config) Guarded(key string) bool { return key != "" && c.guardedKeys[key] }
