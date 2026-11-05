package store

import (
	"encoding/json"
	"fmt"
)

// Supplier 是 supplier 表里的一行。
type Supplier struct {
	ID         int64
	Code       string
	Name       string
	AuthConfig map[string]any
	APIBase    string
	Status     string
}

// LoadSupplier 按 code 取供应源。找不到返回 nil,nil。
func LoadSupplier(db *DB, code string) (*Supplier, error) {
	if db == nil {
		return nil, nil
	}
	rows, err := db.Rows(fmt.Sprintf(
		"SELECT id, code, name, auth_config::text, coalesce(api_base,''), status FROM supplier WHERE code=%s;",
		Quote(code)))
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	r := rows[0]
	s := &Supplier{Code: r["code"], Name: r["name"], APIBase: r["api_base"], Status: r["status"]}
	fmt.Sscanf(r["id"], "%d", &s.ID)
	if r["auth_config"] != "" {
		_ = json.Unmarshal([]byte(r["auth_config"]), &s.AuthConfig)
	}
	if s.AuthConfig == nil {
		s.AuthConfig = map[string]any{}
	}
	return s, nil
}

// EnsureSupplier 确保供应源行存在（集成测试用），返回它的 id。
func EnsureSupplier(db *DB, code, name string) (int64, error) {
	s, err := LoadSupplier(db, code)
	if err != nil {
		return 0, err
	}
	if s != nil {
		return s.ID, nil
	}
	short := code
	if len(short) > 3 {
		short = short[:3]
	}
	sql := fmt.Sprintf(
		"INSERT INTO supplier (code, name, short_name, country_code, default_currency, timezone, "+
			"status, api_base, auth_config, capability, sync_policy, connector_version) "+
			"VALUES (%s, %s, %s, 'CN', 'CNY', 'Asia/Shanghai', 'active', NULL, '{}'::jsonb, "+
			"'{}'::jsonb, '{}'::jsonb, 'adapter-v1') RETURNING id;",
		Quote(code), Quote(name), Quote(upper(short)))
	v, err := db.Scalar(sql)
	if err != nil {
		return 0, err
	}
	var id int64
	fmt.Sscanf(v, "%d", &id)
	return id, nil
}

func upper(s string) string {
	out := []rune(s)
	for i, r := range out {
		if r >= 'a' && r <= 'z' {
			out[i] = r - 32
		}
	}
	return string(out)
}
