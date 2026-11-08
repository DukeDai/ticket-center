// Package config 加载并校验传输层配置。
//
// 源差异（端点、接口编码、凭证口径、错误码映射）全部来自配置文件，
// 代码里不出现「if supplier == 'xxx'」这类按源分支。
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"ticket-center/internal/credential"
)

// File 是配置文件根结构。
type File struct {
	Sources map[string]*Source `json:"sources"`
}

// Source 单个源的配置。
type Source struct {
	Status           string                     `json:"status"`
	Confirmed        bool                       `json:"confirmed"`
	Protocol         string                     `json:"protocol"`
	ProtocolNote     string                     `json:"protocol_note"`
	Direction        string                     `json:"direction"`
	Endpoints        Endpoints                  `json:"endpoints"`
	Credentials      map[string]credential.Spec `json:"credentials"`
	Token            TokenSpec                  `json:"token"`
	Interfaces       map[string]Interface       `json:"interfaces"`
	Probes           Probes                     `json:"probes"`
	ErrorCodes       map[string]string          `json:"error_codes"`
	ErrorLabels      map[string]string          `json:"error_labels"`
	IdempotentCodes  []string                   `json:"idempotent_codes"`
	AuthErrorCodes   map[string]string          `json:"auth_error_codes"`
	RefreshableCodes []string                   `json:"refreshable_codes"`
	ConfirmedFacts   map[string]string          `json:"confirmed_facts"`
	NeedFromBusiness []string                   `json:"need_from_business"`
	Auth             AuthSpec                   `json:"auth"`
}

// TokenSpec 令牌相关字段名与有效期口径。
type TokenSpec struct {
	AccessField  string `json:"access_field"`
	RefreshField string `json:"refresh_field"`
	ExpiresField string `json:"expires_field"`
	ExpiresUnit  string `json:"expires_unit"`
	SkewSeconds  int    `json:"skew_seconds"`
	ErrCodeField string `json:"err_code_field"`
	ErrMsgField  string `json:"err_msg_field"`
}

// AuthSpec 认证形态描述。
type AuthSpec struct {
	Scheme    string `json:"scheme"`
	Confirmed bool   `json:"confirmed"`
}

// Interface 一个业务接口的描述。
type Interface struct {
	Section          string `json:"section"`
	Summary          string `json:"summary"`
	ICodeProd        string `json:"icode_prod"`
	ICodeSandbox     string `json:"icode_sandbox"`
	Note             string `json:"note"`
	IdempotencyField string `json:"idempotency_field"`
}

// Endpoints 端点表。不同源的环境键可能不同，这里做宽松解析。
type Endpoints struct {
	Prod    map[string]string            `json:"prod"`
	Sandbox map[string]string            `json:"sandbox"`
	Extra   map[string]map[string]string `json:"-"`
}

// UnmarshalJSON 解析端点表：prod / sandbox 之外的环境键进 Extra，
// `_comment` 之类的说明键忽略。
func (e *Endpoints) UnmarshalJSON(b []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	e.Prod = map[string]string{}
	e.Sandbox = map[string]string{}
	e.Extra = map[string]map[string]string{}
	for env, payload := range raw {
		switch env {
		case "_comment":
			continue
		case "prod", "sandbox":
			m := map[string]string{}
			if err := json.Unmarshal(payload, &m); err != nil {
				return fmt.Errorf("端点 %s 解析失败: %w", env, err)
			}
			if env == "prod" {
				e.Prod = m
			} else {
				e.Sandbox = m
			}
		default:
			m := map[string]string{}
			if err := json.Unmarshal(payload, &m); err != nil {
				return fmt.Errorf("端点 %s 解析失败: %w", env, err)
			}
			e.Extra[env] = m
		}
	}
	return nil
}

// ForEnv 取某环境的端点表。
func (e Endpoints) ForEnv(env string) map[string]string {
	switch env {
	case "prod":
		return e.Prod
	case "sandbox":
		return e.Sandbox
	}
	if m, ok := e.Extra[env]; ok {
		return m
	}
	return e.Prod
}

// Load 从文件读取配置并做结构校验。
func Load(path string) (*File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取配置失败 %s: %w", path, err)
	}
	var f File
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("解析配置失败 %s: %w", path, err)
	}
	if len(f.Sources) == 0 {
		return nil, fmt.Errorf("配置 %s 没有任何源", path)
	}
	for code, s := range f.Sources {
		if err := s.validate(code); err != nil {
			return nil, err
		}
	}
	return &f, nil
}

func (s *Source) validate(code string) error {
	if len(s.Credentials) == 0 {
		return fmt.Errorf("源 %s 未声明凭证口径", code)
	}
	if len(s.Endpoints.Prod) == 0 && len(s.Endpoints.Sandbox) == 0 && len(s.Endpoints.Extra) == 0 {
		return fmt.Errorf("源 %s 未声明端点结构", code)
	}
	for name, spec := range s.Credentials {
		if spec.Required && spec.Env == "" {
			return fmt.Errorf("源 %s 的凭证 %s 未声明环境变量名", code, name)
		}
	}
	return nil
}

// Codes 列出已注册的源编码。
func (f *File) Codes() []string {
	out := make([]string, 0, len(f.Sources))
	for c := range f.Sources {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// Get 取一个源配置。
func (f *File) Get(code string) (*Source, error) {
	s, ok := f.Sources[code]
	if !ok {
		return nil, fmt.Errorf("未知源 %s；已注册：%s", code, strings.Join(f.Codes(), ", "))
	}
	return s, nil
}

// Probes 是各接口的探针请求体。`_comment` 之类的说明键忽略。
type Probes map[string]map[string]any

// UnmarshalJSON 解析探针表。
func (p *Probes) UnmarshalJSON(b []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	out := Probes{}
	for op, payload := range raw {
		if op == "_comment" {
			continue
		}
		m := map[string]any{}
		if err := json.Unmarshal(payload, &m); err != nil {
			return fmt.Errorf("探针 %s 解析失败: %w", op, err)
		}
		out[op] = m
	}
	*p = out
	return nil
}

// Probe 取某接口的探针请求体。
func (s *Source) Probe(op string) map[string]any {
	m, ok := s.Probes[op]
	if !ok {
		return map[string]any{}
	}
	return m
}

// ICode 取某接口在某环境的 ICODE。缺失时返回空串（由调用方决定如何报错）。
func (s *Source) ICode(name, env string) string {
	iface, ok := s.Interfaces[name]
	if !ok {
		return ""
	}
	if env == "sandbox" && iface.ICodeSandbox != "" {
		return iface.ICodeSandbox
	}
	return iface.ICodeProd
}

// MissingICode 列出当前环境缺 ICODE 的接口。
func (s *Source) MissingICode(env string) []string {
	var out []string
	for name := range s.Interfaces {
		if s.ICode(name, env) == "" {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}
