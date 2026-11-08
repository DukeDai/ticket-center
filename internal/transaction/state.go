// Package transaction 是交易域的读侧接口：状态机的合法流转、领域事件。
//
// 状态机的判定本身在库里（state_transition 表 + 触发器），
// 这个包只负责把答案读出来给 CLI 和测试用 —— 不在这里另排一份流转，
// 否则两处各改各的，门禁就废了。
package transaction

import (
	"fmt"
	"strconv"

	"ticket-center/internal/store"
)

// Transition 是一条合法流转。
type Transition struct {
	Aggregate string
	From      string
	To        string
	EventType string
}

// Event 是 outbox 里的一条领域事件。
type Event struct {
	ID            int64
	AggregateType string
	AggregateID   int64
	EventType     string
	Payload       string
	CreatedAt     string
}

// Transitions 列出全部合法流转。
func Transitions(db *store.DB) ([]Transition, error) {
	rows, err := db.Rows(`SELECT aggregate_type, from_status, to_status, COALESCE(event_type, '')
                             FROM state_transition
                            ORDER BY aggregate_type, from_status, to_status;`)
	if err != nil {
		return nil, err
	}
	out := make([]Transition, 0, len(rows))
	for _, r := range rows {
		out = append(out, Transition{
			Aggregate: r["aggregate_type"],
			From:      r["from_status"],
			To:        r["to_status"],
			EventType: r["event_type"],
		})
	}
	return out, nil
}

// Allowed 判断一条流转是否合法。
//
// 这是库里守卫触发器的只读版本：不碰数据就能知道答案，
// 用来在写库之前先拦一道（省一次往返，也省一次报错）。
func Allowed(db *store.DB, aggregate, from, to string) (bool, error) {
	v, err := db.Scalar(fmt.Sprintf(
		"SELECT fn_state_transition_allowed(%s, %s, %s)::int;",
		store.Quote(aggregate), store.Quote(from), store.Quote(to)))
	if err != nil {
		return false, err
	}
	return v == "1", nil
}

// Events 列出某个聚合的领域事件（按发生顺序）。
func Events(db *store.DB, aggregateType string, aggregateID int64) ([]Event, error) {
	rows, err := db.Rows(fmt.Sprintf(
		`SELECT id, aggregate_type, aggregate_id, event_type, payload::text, created_at::text
           FROM event_outbox
          WHERE aggregate_type = %s AND aggregate_id = %s
          ORDER BY id;`,
		store.Quote(aggregateType), store.Quote(aggregateID)))
	if err != nil {
		return nil, err
	}
	out := make([]Event, 0, len(rows))
	for _, r := range rows {
		out = append(out, Event{
			ID:            parseInt(r["id"]),
			AggregateType: r["aggregate_type"],
			AggregateID:   parseInt(r["aggregate_id"]),
			EventType:     r["event_type"],
			Payload:       r["payload"],
			CreatedAt:     r["created_at"],
		})
	}
	return out, nil
}

// parseInt 解析整数；解析不了就返回 0（事件 id 不会是 0，解析失败说明数据有问题）。
func parseInt(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0
	}
	return n
}
