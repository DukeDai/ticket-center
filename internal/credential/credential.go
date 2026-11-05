// Package credential 负责凭证解析。
//
// 解析顺序（硬约束）：
//  1. 环境变量（首选）
//  2. supplier.auth_config（数据库里的 jsonb，次选）
//
// 凭证**不入库、不进仓库、不进日志**；本包的取值接口不回显明文，
// 错误信息只报「缺哪个环境变量」，不报值。
package credential

import (
	"fmt"
	"os"
	"sort"
	"strings"

	"ticket-center/internal/apperr"
)

// Spec 声明一个凭证项的口径。
type Spec struct {
	Env           string `json:"env"`
	AuthConfigKey string `json:"auth_config_key"`
	Required      bool   `json:"required"`
	Desc          string `json:"desc"`
}

// Resolver 按「环境变量优先 → auth_config」解析凭证。
type Resolver struct {
	SupplierCode string
	Spec         map[string]Spec
	AuthConfig   map[string]any
	// Lookup 覆盖环境变量读取（测试用）；nil 时用 os.LookupEnv。
	Lookup func(string) (string, bool)
}

// Credentials 凭证容器。取值不打印、不序列化、不写库。
type Credentials struct {
	supplierCode string
	values       map[string]string
	sources      map[string]string
	envNames     map[string]string
}

// NewResolver 构造解析器。
func NewResolver(supplierCode string, spec map[string]Spec, authConfig map[string]any) *Resolver {
	return &Resolver{SupplierCode: supplierCode, Spec: spec, AuthConfig: authConfig}
}

func (r *Resolver) lookup(name string) (string, bool) {
	if r.Lookup != nil {
		return r.Lookup(name)
	}
	return os.LookupEnv(name)
}

// Resolve 解析凭证。strict=true 时缺任何必填项即报错。
func (r *Resolver) Resolve(strict bool) (*Credentials, error) {
	values := map[string]string{}
	sources := map[string]string{}
	envNames := map[string]string{}
	var missing []apperr.MissingCredential

	names := make([]string, 0, len(r.Spec))
	for n := range r.Spec {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, name := range names {
		spec := r.Spec[name]
		envName := spec.Env
		if envName == "" {
			envName = "(未配置 env 名)"
		}
		envNames[name] = envName

		if envName != "(未配置 env 名)" {
			if v, ok := r.lookup(envName); ok && v != "" {
				values[name] = v
				sources[name] = "env:" + envName
				continue
			}
		}
		key := spec.AuthConfigKey
		if key == "" {
			key = name
		}
		if raw, ok := r.AuthConfig[key]; ok && raw != nil {
			if s, ok := raw.(string); ok && s != "" {
				values[name] = s
				sources[name] = "supplier.auth_config." + key
				continue
			}
		}
		if spec.Required {
			missing = append(missing, apperr.MissingCredential{
				Name: name, Env: envName, AuthConfigKey: key,
			})
		}
	}
	if len(missing) > 0 && strict {
		return nil, &apperr.MissingCredentials{SupplierCode: r.SupplierCode, Missing: missing}
	}
	return &Credentials{
		supplierCode: r.SupplierCode,
		values:       values,
		sources:      sources,
		envNames:     envNames,
	}, nil
}

// Get 取值，不存在返回 ok=false。
func (c *Credentials) Get(name string) (string, bool) {
	v, ok := c.values[name]
	return v, ok
}

// Require 取值，缺失时返回 MissingCredentials（明确指出环境变量名）。
func (c *Credentials) Require(name string) (string, error) {
	if v, ok := c.values[name]; ok {
		return v, nil
	}
	envName := c.envNames[name]
	if envName == "" {
		envName = "(未配置 env 名)"
	}
	return "", &apperr.MissingCredentials{
		SupplierCode: c.supplierCode,
		Missing: []apperr.MissingCredential{{
			Name: name, Env: envName, AuthConfigKey: name,
		}},
	}
}

// SourceOf 该凭证来自环境变量还是 auth_config。
func (c *Credentials) SourceOf(name string) string { return c.sources[name] }

// EnvName 该凭证对应的环境变量名。
func (c *Credentials) EnvName(name string) string { return c.envNames[name] }

// Names 已解析出的凭证名（排序）。
func (c *Credentials) Names() []string {
	out := make([]string, 0, len(c.values))
	for n := range c.values {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Describe 只描述「有哪些、从哪来」，不含值。
func (c *Credentials) Describe() []string {
	out := make([]string, 0, len(c.values))
	for _, n := range c.Names() {
		out = append(out, fmt.Sprintf("%s←%s", n, c.sources[n]))
	}
	return out
}

// String 刻意不输出明文。
func (c *Credentials) String() string {
	return fmt.Sprintf("Credentials[%s]{%s}", c.supplierCode, strings.Join(c.Names(), ","))
}
