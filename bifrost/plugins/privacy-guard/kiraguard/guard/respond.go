package guard

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"
)

// refusal builds the reply for a refused request in the format the client expects: a normal assistant message for chat
// and responses (also as a stream), an error for images and speech (they have no text answer).
func refusal(endpoint string, body parsed, text string) *Response {
	model := "kira-privacy-guard"
	stream := false
	if body != nil {
		if s := body.str("model"); s != "" {
			model = s
		}
		stream, _ = body["stream"].(bool)
	}
	now := time.Now().Unix()
	switch endpoint {
	case EndpointChat:
		if stream {
			var b bytes.Buffer
			sse(&b, "", map[string]any{"id": "kira-guard", "object": "chat.completion.chunk", "created": now, "model": model,
				"choices": []any{map[string]any{"index": 0, "delta": map[string]any{"role": "assistant", "content": text}, "finish_reason": nil}}})
			sse(&b, "", map[string]any{"id": "kira-guard", "object": "chat.completion.chunk", "created": now, "model": model,
				"choices": []any{map[string]any{"index": 0, "delta": map[string]any{}, "finish_reason": "stop"}},
				"usage":   map[string]any{"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
			b.WriteString("data: [DONE]\n\n")
			return &Response{Status: 200, ContentType: "text/event-stream", Body: b.Bytes()}
		}
		return jsonResponse(200, map[string]any{"id": "kira-guard", "object": "chat.completion", "created": now, "model": model,
			"choices": []any{map[string]any{"index": 0, "message": map[string]any{"role": "assistant", "content": text},
				"finish_reason": "stop"}},
			"usage": map[string]any{"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}})
	case EndpointResponses:
		msg := map[string]any{"type": "message", "id": "msg_kira_guard", "status": "completed", "role": "assistant",
			"content": []any{map[string]any{"type": "output_text", "text": text, "annotations": []any{}}}}
		resp := func(status string, output []any) map[string]any {
			return map[string]any{"id": "resp_kira_guard", "object": "response", "created_at": now, "status": status,
				"model": model, "output": output,
				"usage": map[string]any{"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}}
		}
		if !stream {
			return jsonResponse(200, resp("completed", []any{msg}))
		}
		var b bytes.Buffer
		seq := 0
		ev := func(typ string, data map[string]any) {
			data["type"] = typ
			data["sequence_number"] = seq
			seq++
			sse(&b, typ, data)
		}
		empty := map[string]any{"type": "message", "id": "msg_kira_guard", "status": "in_progress", "role": "assistant", "content": []any{}}
		part := map[string]any{"type": "output_text", "text": "", "annotations": []any{}}
		done := map[string]any{"type": "output_text", "text": text, "annotations": []any{}}
		ev("response.created", map[string]any{"response": resp("in_progress", []any{})})
		ev("response.output_item.added", map[string]any{"output_index": 0, "item": empty})
		ev("response.content_part.added", map[string]any{"item_id": "msg_kira_guard", "output_index": 0, "content_index": 0, "part": part})
		ev("response.output_text.delta", map[string]any{"item_id": "msg_kira_guard", "output_index": 0, "content_index": 0, "delta": text})
		ev("response.output_text.done", map[string]any{"item_id": "msg_kira_guard", "output_index": 0, "content_index": 0, "text": text})
		ev("response.content_part.done", map[string]any{"item_id": "msg_kira_guard", "output_index": 0, "content_index": 0, "part": done})
		ev("response.output_item.done", map[string]any{"output_index": 0, "item": msg})
		ev("response.completed", map[string]any{"response": resp("completed", []any{msg})})
		return &Response{Status: 200, ContentType: "text/event-stream", Body: b.Bytes()}
	}
	// images, speech: no text answer possible → error with the German explanation (LibreChat shows the message)
	return jsonResponse(400, map[string]any{"error": map[string]any{"message": text, "type": "privacy_guard_refused",
		"code": "privacy_guard"}})
}

func sse(b *bytes.Buffer, event string, data any) {
	raw, _ := json.Marshal(data)
	if event != "" {
		fmt.Fprintf(b, "event: %s\n", event)
	}
	fmt.Fprintf(b, "data: %s\n\n", raw)
}

func jsonResponse(status int, v any) *Response {
	raw, _ := json.Marshal(v)
	return &Response{Status: status, ContentType: "application/json", Body: raw}
}
