package layertest

import (
	"encoding/json"
	"testing"
)

func TestExtractProductIDs(t *testing.T) {
	raw := []byte(`{"data":{"productList":[{"productID":1,"name":"a"},{"productID":2,"name":"b"}]}}`)
	got := ExtractProductIDs(raw)
	if len(got) != 2 {
		t.Fatalf("取到 %d 个产品 id，期望 2", len(got))
	}
}

func TestExtractProductIDsSingle(t *testing.T) {
	raw := []byte(`{"productID":42,"name":"x"}`)
	got := ExtractProductIDs(raw)
	if len(got) != 1 {
		t.Fatalf("取到 %d 个产品 id，期望 1", len(got))
	}
}

func TestExtractResourceIDs(t *testing.T) {
	raw := []byte(`{"productList":[{"packageList":[{"resourceList":[{"resourceID":900001},{"resourceID":900002}]}]}]}`)
	got := ExtractResourceIDs(raw)
	if len(got) != 2 {
		t.Fatalf("取到 %d 个资源 id，期望 2", len(got))
	}
}

func TestCountPriceRowsNested(t *testing.T) {
	raw := []byte(`{"packageList":[{"resourceList":[{"calendarDetailList":[{"date":"2026-11-16"},{"date":"2026-11-17"}]}]}]}`)
	if got := CountPriceRows(raw); got != 2 {
		t.Errorf("报价行 = %d，期望 2", got)
	}
}

func TestBuildNormalizePayload(t *testing.T) {
	detail := []byte(`{"productList":[{"productID":1,"packageList":[{"resourceList":[{"resourceID":2}]}]}]}`)
	price := []byte(`{"productID":1,"packageList":[{"resourceList":[{"calendarDetailList":[{"date":"2026-11-16"}]}]}]}`)
	payload := BuildNormalizePayload(detail, price)
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		t.Fatalf("拼出的载荷不是合法 JSON：%v", err)
	}
	if len(m["catalog"].([]any)) != 1 {
		t.Errorf("catalog 长度不对：%v", m["catalog"])
	}
	if len(m["prices"].([]any)) != 1 {
		t.Errorf("prices 长度不对：%v", m["prices"])
	}
}

func TestDefaultDateRange(t *testing.T) {
	start := DefaultStartDate()
	end := DefaultEndDate(start)
	if start >= end {
		t.Errorf("起止日期不对：%s → %s", start, end)
	}
}
