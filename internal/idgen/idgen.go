// Package idgen 生成请求级唯一标识（UUID v4）。
//
// 用途：源侧日志追踪。**不是业务幂等键** —— 业务幂等靠 distributorOrderID 这类
// 业务字段（见 docs/connector-contract.md §9.6）。
package idgen

import (
	"crypto/rand"
	"encoding/hex"
)

// UUID 返回一个 UUID v4 字符串。
func UUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand 失败属于系统级异常，这里退化为时间戳派生（仅影响追踪位）
		return "fallback-" + hex.EncodeToString([]byte(timeNow()))
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant
	return hex.EncodeToString(b[0:4]) + "-" + hex.EncodeToString(b[4:6]) + "-" +
		hex.EncodeToString(b[6:8]) + "-" + hex.EncodeToString(b[8:10]) + "-" +
		hex.EncodeToString(b[10:16])
}
