package credential

import (
	"testing"

	"ticket-center/internal/apperr"
)

func spec() map[string]Spec {
	return map[string]Spec{
		"aid":  {Env: "TEST_AID", AuthConfigKey: "aid", Required: true},
		"sid":  {Env: "TEST_SID", AuthConfigKey: "sid", Required: true},
		"key":  {Env: "TEST_KEY", AuthConfigKey: "key", Required: true},
		"opt":  {Env: "TEST_OPT", AuthConfigKey: "opt", Required: false},
	}
}

func TestEnvWinsOverAuthConfig(t *testing.T) {
	r := NewResolver("trip_com", spec(), map[string]any{"aid": "from-db"})
	r.Lookup = func(k string) (string, bool) {
		if k == "TEST_AID" {
			return "from-env", true
		}
		return "", false
	}
	creds, err := r.Resolve(false)
	if err != nil {
		t.Fatalf("解析失败：%v", err)
	}
	v, _ := creds.Get("aid")
	if v != "from-env" {
		t.Errorf("环境变量应优先，实际取到 %q", v)
	}
	if creds.SourceOf("aid") != "env:TEST_AID" {
		t.Errorf("来源标记不对：%s", creds.SourceOf("aid"))
	}
}

func TestFallbackToAuthConfig(t *testing.T) {
	r := NewResolver("trip_com", spec(), map[string]any{"aid": "from-db", "sid": "db-sid"})
	r.Lookup = func(k string) (string, bool) { return "", false }
	creds, err := r.Resolve(false)
	if err != nil {
		t.Fatalf("解析失败：%v", err)
	}
	v, ok := creds.Get("aid")
	if !ok || v != "from-db" {
		t.Errorf("应回落到 auth_config，实际 %q", v)
	}
	if creds.SourceOf("aid") != "supplier.auth_config.aid" {
		t.Errorf("来源标记不对：%s", creds.SourceOf("aid"))
	}
}

func TestMissingCredentialsListEnvNames(t *testing.T) {
	r := NewResolver("trip_com", spec(), nil)
	r.Lookup = func(k string) (string, bool) { return "", false }
	_, err := r.Resolve(true)
	m, ok := apperr.AsMissing(err)
	if !ok {
		t.Fatalf("期望 MissingCredentials，得到 %T：%v", err, err)
	}
	if len(m.Missing) != 3 {
		t.Errorf("缺失项 = %d，期望 3", len(m.Missing))
	}
	if m.Missing[0].Env != "TEST_AID" {
		t.Errorf("没报出环境变量名：%+v", m.Missing[0])
	}
	if m.SupplierCode != "trip_com" {
		t.Errorf("供应商码不对：%s", m.SupplierCode)
	}
}

func TestRequireReportsEnvName(t *testing.T) {
	r := NewResolver("trip_com", spec(), nil)
	r.Lookup = func(k string) (string, bool) { return "", false }
	creds, _ := r.Resolve(false)
	_, err := creds.Require("key")
	m, ok := apperr.AsMissing(err)
	if !ok {
		t.Fatalf("期望 MissingCredentials，得到 %T", err)
	}
	if m.Missing[0].Env != "TEST_KEY" {
		t.Errorf("环境变量名不对：%+v", m.Missing[0])
	}
}

func TestDescribeHidesValues(t *testing.T) {
	r := NewResolver("trip_com", spec(), nil)
	r.Lookup = func(k string) (string, bool) {
		if k == "TEST_AID" {
			return "secret-value", true
		}
		return "", false
	}
	creds, _ := r.Resolve(false)
	for _, d := range creds.Describe() {
		if d == "aid←env:TEST_AID" {
			continue
		}
		t.Errorf("Describe 泄露了内容：%s", d)
	}
	if s := creds.String(); s == "" {
		t.Error("String 不应为空")
	}
}
