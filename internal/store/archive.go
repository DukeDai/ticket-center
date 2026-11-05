package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"ticket-center/internal/transport"
)

// Archiver 把真实报文归档到 supplier_raw_payload（落库前脱敏）。
type Archiver struct {
	db         *DB
	supplierID int64
	enabled    bool
}

// NewArchiver 构造归档器。supplierID<=0 或 db==nil 时归档自动关闭。
func NewArchiver(db *DB, supplierID int64, enabled bool) *Archiver {
	return &Archiver{db: db, supplierID: supplierID, enabled: enabled && db != nil && supplierID > 0}
}

// Enabled 归档是否开启。
func (a *Archiver) Enabled() bool { return a.enabled }

// Record 写一条归档。
func (a *Archiver) Record(entityType, entityRef, direction string, request, response any,
	httpStatus int, latencyMS int, traceID string) error {
	if !a.enabled {
		return nil
	}
	if direction == "" {
		direction = "inbound"
	}
	sql := fmt.Sprintf(
		"INSERT INTO supplier_raw_payload "+
			"(supplier_id, entity_type, entity_ref, direction, request, response, http_status, latency_ms, trace_id, occurred_at) "+
			"VALUES (%d, %s, %s, %s, %s, %s, %s, %s, %s, now())",
		a.supplierID,
		Quote(entityType), Quote(entityRef), Quote(direction),
		quoteJSON(request), quoteJSON(response),
		Quote(httpStatus), Quote(latencyMS), Quote(traceID))
	return a.db.Exec(sql)
}

// quoteJSON 把任意结构脱敏后转成 jsonb 字面量。
func quoteJSON(v any) string {
	if v == nil {
		return "NULL"
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return "NULL"
	}
	return Quote(string(transport.RedactJSON(raw))) + "::jsonb"
}

// Idempotency 是业务幂等存储（idempotency_record）。
//
// 同一逻辑请求的所有重试复用同一 key：同 key 同内容 → 回放缓存；
// 同 key 不同内容 → 冲突（说明调用方用错了 key）。
type Idempotency struct {
	db      *DB
	enabled bool
}

// NewIdempotency 构造幂等存储。
func NewIdempotency(db *DB, enabled bool) *Idempotency {
	return &Idempotency{db: db, enabled: enabled && db != nil}
}

// Enabled 幂等是否开启。
func (i *Idempotency) Enabled() bool { return i.enabled }

// Begin 登记一次幂等请求。
//
// 返回 ("replay", cached) 表示命中缓存；("new", nil) 表示首次。
func (i *Idempotency) Begin(scope, key string, payload any) (string, any, error) {
	if !i.enabled {
		return "new", nil, nil
	}
	h := RequestHash(payload)
	rows, err := i.db.Rows(fmt.Sprintf(
		"SELECT request_hash, response, status FROM idempotency_record WHERE scope=%s AND idempotency_key=%s;",
		Quote(scope), Quote(key)))
	if err != nil {
		return "", nil, err
	}
	if len(rows) > 0 {
		row := rows[0]
		if row["request_hash"] != h {
			return "", nil, fmt.Errorf("幂等键 %s 已用于不同的请求内容（scope=%s）", key, scope)
		}
		switch row["status"] {
		case "done":
			var cached any
			if row["response"] != "" {
				var m any
				if err := json.Unmarshal([]byte(row["response"]), &m); err == nil {
					cached = m
				}
			}
			return "replay", cached, nil
		case "in_progress":
			return "", nil, fmt.Errorf("幂等键 %s 正在处理中（scope=%s）", key, scope)
		}
	}
	sql := fmt.Sprintf(
		"INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status) "+
			"VALUES (%s, %s, %s, 'in_progress') "+
			"ON CONFLICT (scope, idempotency_key) DO UPDATE SET status='in_progress', request_hash=EXCLUDED.request_hash;",
		Quote(scope), Quote(key), Quote(h))
	if err := i.db.Exec(sql); err != nil {
		return "", nil, err
	}
	return "new", nil, nil
}

// Complete 标记幂等请求完成并缓存响应。
func (i *Idempotency) Complete(scope, key string, response any) error {
	if !i.enabled {
		return nil
	}
	sql := fmt.Sprintf("UPDATE idempotency_record SET status='done', response=%s WHERE scope=%s AND idempotency_key=%s;",
		quoteJSON(response), Quote(scope), Quote(key))
	return i.db.Exec(sql)
}

// Fail 标记幂等请求失败（允许重试）。
func (i *Idempotency) Fail(scope, key string) error {
	if !i.enabled {
		return nil
	}
	return i.db.Exec(fmt.Sprintf(
		"UPDATE idempotency_record SET status='failed' WHERE scope=%s AND idempotency_key=%s;",
		Quote(scope), Quote(key)))
}

// RequestHash 请求指纹：同一个幂等键必须对应同一份请求内容。
func RequestHash(payload any) string {
	raw, err := json.Marshal(payload)
	if err != nil {
		raw = []byte(fmt.Sprintf("%v", payload))
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}
