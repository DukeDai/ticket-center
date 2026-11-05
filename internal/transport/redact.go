package transport

import (
	"bytes"
	"encoding/json"
	"net/url"
	"strings"
)

// secretKeys 归档与日志中必须脱敏的字段名（小写、下划线归一后比对）。
var secretKeys = map[string]bool{
	"token": true, "accesstoken": true, "access_token": true,
	"refreshtoken": true, "refresh_token": true,
	"key": true, "apikey": true, "api_key": true,
	"secret": true, "password": true, "passwd": true, "pwd": true,
	"sign": true, "signature": true, "authorization": true, "auth": true,
	"cookie": true, "set-cookie": true,
}

const mask = "***"

func isSecret(name string) bool {
	return secretKeys[strings.ToLower(strings.ReplaceAll(name, "-", "_"))]
}

// Redact 递归脱敏任意 JSON 结构。命中敏感字段名的值替换为 "***"。
func Redact(v any) any {
	return redact(v, 0)
}

func redact(v any, depth int) any {
	if depth > 10 {
		return "..."
	}
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, val := range t {
			if isSecret(k) {
				out[k] = mask
				continue
			}
			out[k] = redact(val, depth+1)
		}
		return out
	case []any:
		out := make([]any, len(t))
		for i, val := range t {
			out[i] = redact(val, depth+1)
		}
		return out
	default:
		return v
	}
}

// RedactMap 脱敏一个 map（便捷包装）。
func RedactMap(m map[string]any) map[string]any {
	if m == nil {
		return nil
	}
	out, _ := redact(m, 0).(map[string]any)
	return out
}

// RedactURL 脱敏 URL 里的敏感 query 参数（携程把 token 放在 URL 上）。
func RedactURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	if u.RawQuery == "" {
		return raw
	}
	q := u.Query()
	for k := range q {
		if isSecret(k) {
			q.Set(k, mask)
		}
	}
	u.RawQuery = q.Encode()
	return u.String()
}

// RedactJSON 脱敏一段 JSON 字节；不是合法 JSON 时原样返回（调用方决定怎么办）。
func RedactJSON(b []byte) []byte {
	if len(b) == 0 {
		return b
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return b
	}
	out, err := json.Marshal(redact(v, 0))
	if err != nil {
		return b
	}
	return out
}

// MarshalRedacted 把任意结构脱敏后转 JSON 字节。
func MarshalRedacted(v any) []byte {
	raw, err := json.Marshal(v)
	if err != nil {
		return []byte("null")
	}
	return RedactJSON(raw)
}

// RedactHeaders 脱敏 HTTP 头（Authorization / Cookie 等）。
func RedactHeaders(h map[string]string) map[string]string {
	if h == nil {
		return nil
	}
	out := make(map[string]string, len(h))
	for k, v := range h {
		if isSecret(k) {
			out[k] = mask
			continue
		}
		out[k] = v
	}
	return out
}

// decodeJSON 解析 JSON 字节。
func decodeJSON(b []byte, v any) error {
	return json.NewDecoder(bytes.NewReader(b)).Decode(v)
}
