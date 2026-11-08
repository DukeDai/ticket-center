// Package registry 是适配器注册表：supplier.code → 适配器实例。
//
// 这里是**唯一**允许出现 source code 的地方（一张注册表），不是业务代码里的按源分支：
// 新增一个源 = 在 configs/api_config.json 加一段 + （若协议特殊）在本文件注册一个类。
//
// 凭证解析顺序：**环境变量优先**，其次 supplier.auth_config（数据库里的 jsonb）。
// 两者都拿不到 → 报 MissingCredentials，明确指出缺哪个环境变量。
package registry

import (
	"fmt"
	"os"
	"sort"

	"ticket-center/internal/config"
	"ticket-center/internal/credential"
	"ticket-center/internal/store"
	"ticket-center/internal/supplier"
	"ticket-center/internal/supplier/globaltix"
	"ticket-center/internal/supplier/pending"
	"ticket-center/internal/supplier/tripcom"
	"ticket-center/internal/transport"
)

// builder 构造一个源的适配器。
type builder func(base *supplier.Base) supplier.Port

// specialized 需要专门实现的源（协议特殊）。
var specialized = map[string]builder{
	"trip_com":  func(b *supplier.Base) supplier.Port { return tripcom.New(b) },
	"globaltix": func(b *supplier.Base) supplier.Port { return globaltix.New(b) },
}

// SourceInfo 描述一个源的注册情况。
type SourceInfo struct {
	Code      string `json:"code"`
	Status    string `json:"status"`
	Confirmed bool   `json:"confirmed"`
	Protocol  string `json:"protocol"`
	Adapter   string `json:"adapter"`
	Note      string `json:"note"`
}

// List 列出所有已注册的源。
func List(cfg *config.File) []SourceInfo {
	out := make([]SourceInfo, 0, len(cfg.Sources))
	for _, code := range cfg.Codes() {
		s := cfg.Sources[code]
		adapter := "pending.Adapter"
		if _, ok := specialized[code]; ok {
			switch code {
			case "trip_com":
				adapter = "tripcom.Adapter"
			case "globaltix":
				adapter = "globaltix.Adapter"
			}
		}
		out = append(out, SourceInfo{
			Code: code, Status: s.Status, Confirmed: s.Confirmed,
			Protocol: s.Protocol, Adapter: adapter, Note: s.ProtocolNote,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Code < out[j].Code })
	return out
}

// Options 构造适配器的可选项。
type Options struct {
	Env string
	DB  *store.DB
	// EnvVars 覆盖环境变量读取（测试用）；nil 时用 os.LookupEnv。
	EnvVars map[string]string
	// RequireCredentials=false 时允许缺凭证构造（用于跑不需要凭证的检查）。
	RequireCredentials bool
	// Archive / Idempotency 开关。
	Archive     bool
	Idempotency bool
	// EndpointOverride 覆盖某环境的端点表（mock 模式用）。
	EndpointOverride map[string]map[string]string
}

// Build 构造一个源的适配器实例。
func Build(code string, cfg *config.File, opts Options) (supplier.Port, error) {
	src, err := cfg.Get(code)
	if err != nil {
		return nil, err
	}
	if opts.Env == "" {
		opts.Env = "prod"
	}
	if override, ok := opts.EndpointOverride[opts.Env]; ok {
		// 复制一份，避免污染共享配置
		clone := *src
		clone.Endpoints = config.Endpoints{
			Prod:    src.Endpoints.Prod,
			Sandbox: src.Endpoints.Sandbox,
			Extra:   src.Endpoints.Extra,
		}
		if clone.Endpoints.Prod == nil {
			clone.Endpoints.Prod = map[string]string{}
		}
		if clone.Endpoints.Sandbox == nil {
			clone.Endpoints.Sandbox = map[string]string{}
		}
		for k, v := range override {
			if opts.Env == "sandbox" {
				clone.Endpoints.Sandbox[k] = v
			} else {
				clone.Endpoints.Prod[k] = v
			}
		}
		src = &clone
	}

	authConfig := map[string]any{}
	var supplierID int64
	if opts.DB != nil {
		row, err := store.LoadSupplier(opts.DB, code)
		if err != nil {
			return nil, err
		}
		if row != nil {
			supplierID = row.ID
			authConfig = row.AuthConfig
		}
	}

	resolver := credential.NewResolver(code, src.Credentials, authConfig)
	if opts.EnvVars != nil {
		resolver.Lookup = func(k string) (string, bool) {
			v, ok := opts.EnvVars[k]
			return v, ok
		}
	}
	creds, err := resolver.Resolve(opts.RequireCredentials)
	if err != nil {
		return nil, err
	}

	client := transport.NewClient()

	var archiver *store.Archiver
	if opts.DB != nil {
		archiver = store.NewArchiver(opts.DB, supplierID, opts.Archive)
	}
	idem := store.NewIdempotency(opts.DB, opts.Idempotency)

	base := &supplier.Base{
		Code: code, Cfg: src, Creds: creds, Client: client,
		Archiver: archiver, Idem: idem, Env: opts.Env,
	}
	if b, ok := specialized[code]; ok {
		return b(base), nil
	}
	return pending.New(base), nil
}

// EnvLookup 返回一个从固定 map 读环境变量的 Lookup（测试用）。
func EnvLookup(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) {
		v, ok := m[k]
		return v, ok
	}
}

// OSEnvLookup 读真实环境变量。
func OSEnvLookup(k string) (string, bool) { return os.LookupEnv(k) }

var _ = fmt.Sprintf
