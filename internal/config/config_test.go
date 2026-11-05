package config

import (
	"path/filepath"
	"testing"
)

func configPath(t *testing.T) string {
	t.Helper()
	p := filepath.Join("..", "..", "configs", "api_config.json")
	return p
}

func TestLoadRealConfig(t *testing.T) {
	f, err := Load(configPath(t))
	if err != nil {
		t.Fatalf("加载配置失败：%v", err)
	}
	if len(f.Sources) != 7 {
		t.Errorf("源数量 = %d，期望 7", len(f.Sources))
	}
}

func TestTripComEndpoints(t *testing.T) {
	f, err := Load(configPath(t))
	if err != nil {
		t.Fatalf("加载配置失败：%v", err)
	}
	s, err := f.Get("trip_com")
	if err != nil {
		t.Fatal(err)
	}
	sandbox := s.Endpoints.ForEnv("sandbox")
	if sandbox["authorize"] == "" || sandbox["refresh"] == "" || sandbox["service"] == "" {
		t.Errorf("沙箱端点不全：%v", sandbox)
	}
	prod := s.Endpoints.ForEnv("prod")
	if prod["service"] != "https://sopenservice.ctrip.com/openservice/serviceproxy.ashx" {
		t.Errorf("生产业务端点不对：%s", prod["service"])
	}
}

func TestTripComICodes(t *testing.T) {
	f, _ := Load(configPath(t))
	s, _ := f.Get("trip_com")
	if len(s.Interfaces) != 21 {
		t.Errorf("接口数 = %d，期望 21", len(s.Interfaces))
	}
	for name := range s.Interfaces {
		if s.ICode(name, "sandbox") == "" && name != "getIdByQueryId" {
			t.Errorf("接口 %s 缺沙箱 ICODE", name)
		}
	}
	// getIdByQueryId 规格未给任何 ICODE，必须靠配置标注「待确认」
	if s.ICode("getIdByQueryId", "sandbox") != "" {
		t.Error("getIdByQueryId 不该有 ICODE（规格未给）")
	}
	// 已知三个接口规格未给生产 ICODE
	missing := s.MissingICode("prod")
	if len(missing) != 3 {
		t.Errorf("缺生产 ICODE 的接口 = %v，期望 3 个", missing)
	}
}

func TestErrorCodeClasses(t *testing.T) {
	f, _ := Load(configPath(t))
	s, _ := f.Get("trip_com")
	cases := map[string]string{
		"S0001": "retriable", "S0002": "retriable",
		"B0005": "fatal", "B0008": "fatal", "B0042": "fatal",
		"V0003": "auth",
	}
	for code, want := range cases {
		if got := s.ErrorCodes[code]; got != want {
			t.Errorf("错误码 %s 分类 = %s，期望 %s", code, got, want)
		}
	}
	if len(s.IdempotentCodes) == 0 {
		t.Error("未声明幂等命中码")
	}
}

func TestGlobalTixHasNoInventedEndpoints(t *testing.T) {
	f, _ := Load(configPath(t))
	s, _ := f.Get("globaltix")
	if s.Confirmed {
		t.Error("GlobalTix 不应标记为已确认")
	}
	for _, env := range []string{"prod", "sandbox"} {
		for k, v := range s.Endpoints.ForEnv(env) {
			if v != "" {
				t.Errorf("GlobalTix %s.%s 不应有端点（未公开文档）：%s", env, k, v)
			}
		}
	}
	if len(s.NeedFromBusiness) == 0 {
		t.Error("应列出需要商务提供什么")
	}
}

func TestUnknownSource(t *testing.T) {
	f, _ := Load(configPath(t))
	if _, err := f.Get("nope"); err == nil {
		t.Error("未知源应报错")
	}
}

func TestProbesSkipComment(t *testing.T) {
	f, _ := Load(configPath(t))
	s, _ := f.Get("trip_com")
	if len(s.Probe("listProducts")) == 0 {
		t.Error("listProducts 探针不应为空")
	}
	if len(s.Probe("getCurrencies")) != 0 {
		t.Error("getCurrencies 探针应为空对象")
	}
}
