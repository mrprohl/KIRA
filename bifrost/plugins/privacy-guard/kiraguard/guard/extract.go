package guard

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"mime/multipart"
	"strings"
)

// Endpoint kinds the guard looks at
const (
	EndpointNone      = ""
	EndpointChat      = "chat"      // /v1/chat/completions
	EndpointResponses = "responses" // /v1/responses
	EndpointImage     = "image"     // /v1/images/generations, /v1/images/edits, /v1/images/variations
	EndpointSpeech    = "speech"    // /v1/audio/speech (text to speech)
)

// EndpointOf maps the request path to the kind of request.
func EndpointOf(path string) string {
	p := strings.TrimRight(strings.ToLower(path), "/")
	switch {
	case strings.HasSuffix(p, "/chat/completions"):
		return EndpointChat
	case strings.HasSuffix(p, "/responses"):
		return EndpointResponses
	case strings.HasSuffix(p, "/images/generations"), strings.HasSuffix(p, "/images/edits"), strings.HasSuffix(p, "/images/variations"):
		return EndpointImage
	case strings.HasSuffix(p, "/audio/speech"):
		return EndpointSpeech
	}
	return EndpointNone
}

// parsed is a JSON request body as a generic map (numbers stay json.Number, so nothing changes when it is written back).
type parsed map[string]any

func parseJSON(body []byte) (parsed, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	var m map[string]any
	if err := dec.Decode(&m); err != nil {
		return nil, err
	}
	return m, nil
}

func (p parsed) str(key string) string {
	s, _ := p[key].(string)
	return s
}

// extract returns the pieces of a request and whether its last message comes from the user (only then the notice is
// shown – not in intermediate steps of tool calls).
func extract(endpoint string, body parsed) (pieces []Piece, lastIsUser bool) {
	switch endpoint {
	case EndpointChat:
		msgs, _ := body["messages"].([]any)
		for i, m := range msgs {
			mm, _ := m.(map[string]any)
			if mm == nil {
				continue
			}
			role, _ := mm["role"].(string)
			p := Piece{Role: role}
			p.Text, p.Images, p.Files = contentOf(mm["content"])
			if calls, ok := mm["tool_calls"].([]any); ok { // arguments the model passed to tools
				for _, c := range calls {
					if fn, ok := c.(map[string]any)["function"].(map[string]any); ok {
						if args, ok := fn["arguments"].(string); ok {
							p.Text = joinText(p.Text, args)
						}
					}
				}
			}
			if p.Text != "" || len(p.Images) > 0 || p.Files > 0 {
				pieces = append(pieces, p)
			}
			if i == len(msgs)-1 {
				lastIsUser = role == "user"
			}
		}
	case EndpointResponses:
		if s := body.str("instructions"); s != "" {
			pieces = append(pieces, Piece{Role: "system", Text: s})
		}
		switch in := body["input"].(type) {
		case string:
			pieces = append(pieces, Piece{Role: "user", Text: in})
			lastIsUser = true
		case []any:
			for i, item := range in {
				mm, _ := item.(map[string]any)
				if mm == nil {
					continue
				}
				role, _ := mm["role"].(string)
				typ, _ := mm["type"].(string)
				p := Piece{Role: role}
				switch {
				case typ == "function_call_output":
					p.Role = "tool"
					p.Text, p.Images, p.Files = contentOf(mm["output"])
				case typ == "function_call":
					p.Role = "assistant"
					p.Text, _ = mm["arguments"].(string)
				default:
					p.Text, p.Images, p.Files = contentOf(mm["content"])
				}
				if p.Text != "" || len(p.Images) > 0 || p.Files > 0 {
					pieces = append(pieces, p)
				}
				if i == len(in)-1 {
					lastIsUser = role == "user" && typ != "function_call_output"
				}
			}
		}
	case EndpointImage:
		pieces = append(pieces, Piece{Role: "user", Text: body.str("prompt")})
		lastIsUser = true
	case EndpointSpeech:
		pieces = append(pieces, Piece{Role: "user", Text: body.str("input")})
		lastIsUser = true
	}
	return pieces, lastIsUser
}

// contentOf collects text and image URLs from a message content (string or list of parts, chat or responses format);
// files counts attached files the checkers cannot read (e.g. a PDF as base64) – they count as not checkable.
func contentOf(v any) (text string, images []string, files int) {
	switch c := v.(type) {
	case string:
		return c, nil, 0
	case []any:
		for _, part := range c {
			pm, _ := part.(map[string]any)
			if pm == nil {
				continue
			}
			for _, k := range []string{"text", "input_text", "output_text", "refusal"} {
				if s, ok := pm[k].(string); ok {
					text = joinText(text, s)
				}
			}
			switch iu := pm["image_url"].(type) {
			case string:
				images = append(images, iu)
			case map[string]any:
				if u, ok := iu["url"].(string); ok {
					images = append(images, u)
				}
			}
			if typ, _ := pm["type"].(string); typ == "file" || typ == "input_file" {
				files++
			}
		}
	}
	return text, images, files
}

func joinText(a, b string) string {
	if a == "" {
		return b
	}
	if b == "" {
		return a
	}
	return a + "\n" + b
}

// multipartPrompt reads the field "prompt" of a multipart form (images/edits).
func multipartPrompt(contentType string, body []byte) (string, bool) {
	_, params, err := mime.ParseMediaType(contentType)
	if err != nil || params["boundary"] == "" {
		return "", false
	}
	r := multipart.NewReader(bytes.NewReader(body), params["boundary"])
	for {
		part, err := r.NextPart()
		if err != nil {
			return "", false
		}
		if part.FormName() == "prompt" {
			b, err := io.ReadAll(io.LimitReader(part, 1<<20))
			return string(b), err == nil
		}
	}
}

// chunks splits a piece into pieces of at most n characters (images stay with the first one).
func chunks(p Piece, n int) []Piece {
	r := []rune(p.Text)
	if len(r) <= n {
		return []Piece{p}
	}
	var out []Piece
	for i := 0; i < len(r); i += n {
		q := Piece{Role: p.Role, Text: string(r[i:min(i+n, len(r))])}
		if i == 0 {
			q.Images = p.Images
		}
		out = append(out, q)
	}
	return out
}
