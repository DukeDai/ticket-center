package transport

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"ticket-center/internal/apperr"
)

// newTestClient 造一个不真的 sleep 的客户端（退避行为可断言）。
func newTestClient() *Client {
	c := NewClient()
	c.Sleep = func(time.Duration) {}
	c.BackoffBase = time.Millisecond
	c.BackoffCap = 10 * time.Millisecond
	return c
}

func TestDoRetriesRetriable(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls < 3 {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer srv.Close()

	c := newTestClient()
	resp, err := c.Do(context.Background(), Request{Method: "GET", URL: srv.URL})
	if err != nil {
		t.Fatalf("应重试后成功，却报错：%v", err)
	}
	if resp.Status != 200 {
		t.Errorf("状态码 %d", resp.Status)
	}
	if calls != 3 {
		t.Errorf("调用次数 = %d，期望 3（失败 2 次 + 成功 1 次）", calls)
	}
}

func TestDoDoesNotRetryFatal(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusBadRequest)
	}))
	defer srv.Close()

	c := newTestClient()
	_, err := c.Do(context.Background(), Request{Method: "GET", URL: srv.URL})
	ae, ok := err.(*apperr.Error)
	if !ok {
		t.Fatalf("期望适配器错误，得到 %T：%v", err, err)
	}
	if ae.Class != apperr.ClassFatal {
		t.Errorf("分类 = %s，期望 fatal", ae.Class)
	}
	if calls != 1 {
		t.Errorf("fatal 不该重试，却调了 %d 次", calls)
	}
}

func TestDoDoesNotRetryAuth(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	c := newTestClient()
	_, err := c.Do(context.Background(), Request{Method: "GET", URL: srv.URL})
	ae, ok := err.(*apperr.Error)
	if !ok {
		t.Fatalf("期望适配器错误，得到 %T", err)
	}
	if ae.Class != apperr.ClassAuth {
		t.Errorf("分类 = %s，期望 auth", ae.Class)
	}
	if calls != 1 {
		t.Errorf("auth 不该重试，却调了 %d 次", calls)
	}
}

func TestDoRateLimitIsRetriable(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := newTestClient()
	if _, err := c.Do(context.Background(), Request{Method: "GET", URL: srv.URL}); err != nil {
		t.Fatalf("429 应重试后成功：%v", err)
	}
	if calls != 2 {
		t.Errorf("调用次数 = %d，期望 2", calls)
	}
}

func TestDoUsesCustomClassifier(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"success":false,"errcode":"B0005"}`))
	}))
	defer srv.Close()

	c := newTestClient()
	_, err := c.Do(context.Background(), Request{
		Method: "GET", URL: srv.URL,
		Classify: func(resp *Response) *apperr.Error {
			var env struct {
				Success bool   `json:"success"`
				ErrCode string `json:"errcode"`
			}
			_ = resp.JSON(&env)
			if env.Success {
				return nil
			}
			return &apperr.Error{Class: apperr.ClassFatal, Code: env.ErrCode, Message: "库存不足"}
		},
	})
	ae, ok := err.(*apperr.Error)
	if !ok {
		t.Fatalf("期望适配器错误，得到 %T", err)
	}
	if ae.Code != "B0005" || ae.Class != apperr.ClassFatal {
		t.Errorf("分类/码不对：%s / %s", ae.Class, ae.Code)
	}
	if calls != 1 {
		t.Errorf("fatal 不该重试，却调了 %d 次", calls)
	}
}

func TestProbe(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	c := newTestClient()
	res := c.Probe("127.0.0.1", 1, 200*time.Millisecond)
	if res.OK {
		t.Skip("本机 1 端口可连接，跳过失败用例")
	}
}
