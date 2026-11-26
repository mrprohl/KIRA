// privacy-guard – Bifrost plugin of KIRA (Go plugin, .so). Checks every LibreChat request before it leaves the house:
// personal/secret data → local answer model (vLLM), harmful requests → refused, clean → external as requested.
// Logic: package guard (tested without Bifrost). This file only connects it to Bifrost's HTTP transport hooks.
// Built together with Bifrost (same version, same Go, same dependencies) by Dockerfile – see kira/PRIVACY-GUARD.md.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/maximhq/bifrost/core/schemas"
	"github.com/maximhq/bifrost/transports/v2/kiraguard/guard"
)

// noticeKey carries the notice of a locally answered request from the pre-hook to the response hooks
// (a string key: Bifrost copies it to the request context that the streaming hooks see).
const noticeKey = "kira-privacy-guard-notice"

const maxMultipart = 64 << 20

var g *guard.Guard

// Init is called once with the "config" object of the plugin entry in bifrost.json.
func Init(config any) error {
	raw, err := json.Marshal(config)
	if err != nil {
		return fmt.Errorf("privacy-guard: configuration: %w", err)
	}
	cfg, err := guard.ParseConfig(raw, os.Getenv)
	if err != nil {
		return err
	}
	g = guard.New(cfg, nil)
	fmt.Fprintf(os.Stderr, "privacy-guard: active, mode=%s, privacy=%s, safety=%s, local answers=%s\n",
		cfg.Mode, cfg.PrivacyURL, cfg.SafetyURL, cfg.AnswerModel)
	return nil
}

func GetName() string { return "privacy-guard" }

func Cleanup() error {
	if g != nil {
		g.Wait()
	}
	return nil
}

// HTTPTransportPreHook checks the request and rewrites it (local model) or answers it (refusal).
func HTTPTransportPreHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest) (*schemas.HTTPResponse, error) {
	if g == nil || req == nil || !strings.EqualFold(req.Method, "POST") || guard.EndpointOf(req.Path) == guard.EndpointNone {
		return nil, nil
	}
	in := guard.Request{
		Path:        req.Path,
		ContentType: req.CaseInsensitiveHeaderLookup("Content-Type"),
		Body:        req.Body,
		VirtualKey:  virtualKey(ctx, req),
	}
	if len(in.Body) == 0 {
		if req.BodySource != nil { // multipart (image edits): read the form to find the prompt
			if rc, err := req.BodySource.Open(); err == nil {
				b, err := io.ReadAll(io.LimitReader(rc, maxMultipart))
				_ = rc.Close()
				if err == nil {
					in.Body = b
				}
			}
		}
		in.BodyMissing = len(in.Body) == 0 // Bifrost passes no body above its size limit – cannot be checked
	}
	res := g.Handle(context.Background(), in)
	if res.Response != nil {
		return &schemas.HTTPResponse{
			StatusCode: res.Response.Status,
			Headers:    map[string]string{"Content-Type": res.Response.ContentType, "X-KIRA-Privacy-Guard": "refused"},
			Body:       res.Response.Body,
		}, nil
	}
	if res.Body != nil {
		req.Body = res.Body
		dropHeader(req.Headers, "Content-Length")
	}
	if res.Notice != nil {
		ctx.SetValue(noticeKey, res.Notice)
	}
	return nil, nil
}

// HTTPTransportPostHook adds the notice to a non-streaming reply.
func HTTPTransportPostHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, resp *schemas.HTTPResponse) error {
	n := noticeOf(ctx)
	if n == nil || resp == nil || len(resp.Body) == 0 {
		return nil
	}
	if b, ok := n.ApplyToBody(resp.StatusCode, resp.Body); ok {
		resp.Body = b
		dropHeader(resp.Headers, "Content-Length")
	}
	return nil
}

// HTTPTransportStreamChunkHook adds the notice in front of the first text of a streamed reply.
func HTTPTransportStreamChunkHook(ctx *schemas.BifrostContext, req *schemas.HTTPRequest, chunk *schemas.BifrostStreamChunk) (*schemas.BifrostStreamChunk, error) {
	n := noticeOf(ctx)
	if n == nil || chunk == nil {
		return chunk, nil
	}
	if cr := chunk.BifrostChatResponse; cr != nil {
		for i := range cr.Choices {
			sc := cr.Choices[i].ChatStreamResponseChoice
			if sc == nil || sc.Delta == nil || sc.Delta.Content == nil || *sc.Delta.Content == "" {
				continue
			}
			if n.Take() {
				s := n.Text + *sc.Delta.Content
				sc.Delta.Content = &s
			}
			break
		}
	}
	if rr := chunk.BifrostResponsesStreamResponse; rr != nil && rr.Type == schemas.ResponsesStreamResponseTypeOutputTextDelta &&
		rr.Delta != nil && *rr.Delta != "" && n.Take() {
		s := n.Text + *rr.Delta
		rr.Delta = &s
	}
	return chunk, nil
}

func noticeOf(ctx *schemas.BifrostContext) *guard.Notice {
	if ctx == nil {
		return nil
	}
	n, _ := ctx.Value(noticeKey).(*guard.Notice)
	return n
}

// virtualKey of the caller: header x-bf-vk, Authorization: Bearer, x-api-key, or what Bifrost resolved.
func virtualKey(ctx *schemas.BifrostContext, req *schemas.HTTPRequest) string {
	if v := strings.TrimSpace(req.CaseInsensitiveHeaderLookup("x-bf-vk")); v != "" {
		return v
	}
	if a := strings.TrimSpace(req.CaseInsensitiveHeaderLookup("Authorization")); len(a) > 7 && strings.EqualFold(a[:7], "bearer ") {
		return strings.TrimSpace(a[7:])
	}
	if v := strings.TrimSpace(req.CaseInsensitiveHeaderLookup("x-api-key")); v != "" {
		return v
	}
	if ctx != nil {
		if v, ok := ctx.Value(schemas.BifrostContextKeyVirtualKey).(string); ok {
			return v
		}
	}
	return ""
}

func dropHeader(h map[string]string, name string) {
	for k := range h {
		if strings.EqualFold(k, name) {
			delete(h, k)
		}
	}
}

func main() {}
