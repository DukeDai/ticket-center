package transport

import (
	"encoding/json"
	"testing"
)

func TestRedactMasksSecrets(t *testing.T) {
	in := map[string]any{
		"token":   "SECRET-TOKEN",
		"api_key": "SECRET-KEY",
		"safe":    "visible",
		"nested":  map[string]any{"refresh_token": "SECRET-REFRESH", "keep": 1},
		"list":    []any{map[string]any{"password": "SECRET-PW"}},
	}
	out := RedactMap(in)
	if out["token"] != mask {
		t.Errorf("token 未脱敏：%v", out["token"])
	}
	if out["api_key"] != mask {
		t.Errorf("api_key 未脱敏：%v", out["api_key"])
	}
	if out["safe"] != "visible" {
		t.Errorf("业务字段被误改：%v", out["safe"])
	}
	nested := out["nested"].(map[string]any)
	if nested["refresh_token"] != mask || nested["keep"] != 1 {
		t.Errorf("嵌套脱敏异常：%v", nested)
	}
	list := out["list"].([]any)
	if list[0].(map[string]any)["password"] != mask {
		t.Errorf("数组内脱敏异常：%v", list)
	}
}

func TestRedactURL(t *testing.T) {
	got := RedactURL("https://example.com/openservice?aid=123&icode=ABC&token=SECRET")
	if got == "" {
		t.Fatal("返回空串")
	}
	if contains(got, "SECRET") {
		t.Errorf("URL 里的 token 未脱敏：%s", got)
	}
	if !contains(got, "aid=123") || !contains(got, "icode=ABC") {
		t.Errorf("非敏感参数被误改：%s", got)
	}
}

func TestRedactJSON(t *testing.T) {
	raw := []byte(`{"token":"abc","data":{"key":"def","n":1}}`)
	out := string(RedactJSON(raw))
	if contains(out, "abc") || contains(out, "def") {
		t.Errorf("JSON 脱敏失败：%s", out)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("脱敏后不是合法 JSON：%v", err)
	}
	if m["data"].(map[string]any)["n"] != float64(1) {
		t.Errorf("业务字段被误改：%s", out)
	}
}

func TestRedactJSONInvalid(t *testing.T) {
	raw := []byte(`not json`)
	if string(RedactJSON(raw)) != string(raw) {
		t.Error("非 JSON 输入应原样返回")
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
