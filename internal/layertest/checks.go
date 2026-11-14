package layertest

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ticket-center/internal/apperr"
	"ticket-center/internal/config"
	"ticket-center/internal/coverage"
	"ticket-center/internal/mock"
	"ticket-center/internal/normalize"
	"ticket-center/internal/registry"
	"ticket-center/internal/store"
	"ticket-center/internal/supplier"
	"ticket-center/internal/supplier/globaltix"
	"ticket-center/internal/supplier/tripcom"
	"ticket-center/internal/transport"
)

// Check 是一条自检断言。
type Check struct {
	Name   string `json:"name"`
	Status Status `json:"status"`
	Detail string `json:"detail"`
}

// OfflineChecks 不外呼也能验的能力：配置完整性 / 归一化 / 组合表达式 / 脱敏。
func OfflineChecks(cfg *config.File, rules *normalize.Rules, fixturesDir string) []Check {
	var checks []Check

	// O1 配置完整性
	var problems []string
	for code, s := range cfg.Sources {
		if len(s.Credentials) == 0 {
			problems = append(problems, code+" 未声明凭证口径")
		}
		if len(s.Endpoints.Prod) == 0 && len(s.Endpoints.Sandbox) == 0 && len(s.Endpoints.Extra) == 0 {
			problems = append(problems, code+" 未声明端点结构")
		}
	}
	if len(problems) == 0 {
		checks = append(checks, Check{"O1 配置完整性", StatusPass,
			fmt.Sprintf("%d 个源的配置结构完整", len(cfg.Sources))})
	} else {
		checks = append(checks, Check{"O1 配置完整性", StatusFail, strings.Join(problems, "；")})
	}

	// O2 归一化自检（用 fixture 的真实报文结构）
	total := 0
	var o2err string
	for key, rule := range rules.Sources {
		path := filepath.Join(fixturesDir, rule.Fixture)
		raw, err := os.ReadFile(path)
		if err != nil {
			o2err = err.Error()
			break
		}
		res, err := rules.Normalize(key, raw)
		if err != nil {
			o2err = err.Error()
			break
		}
		for _, v := range res.Variants {
			if len(v.Coverage.Axes) == 0 {
				o2err = fmt.Sprintf("源变体 %s 无覆盖声明", v.ExternalID)
				break
			}
		}
		if o2err != "" {
			break
		}
		total += len(res.Variants)
	}
	if o2err != "" {
		checks = append(checks, Check{"O2 归一化自检", StatusFail, o2err})
	} else {
		checks = append(checks, Check{"O2 归一化自检", StatusPass,
			fmt.Sprintf("%d 个源变体全部带覆盖声明", total)})
	}

	// O3 组合表达式解析（GlobalTix 已核实的语法）
	parts := globaltix.ParseMappingExpression("80041201-8004120101|2+80041201-8004120102|2")
	ok3 := len(parts) == 2 && parts[0].Qty == 2 && parts[0].SKU == "80041201-8004120101"
	raw3, _ := json.Marshal(parts)
	checks = append(checks, Check{"O3 组合表达式解析", statusFor(ok3),
		"A|2+B|1 → " + string(raw3)})

	// O4 脱敏：凭证绝不能进归档/日志
	blob := map[string]any{
		"token":  "SECRET-TOKEN",
		"nested": map[string]any{"api_key": "SECRET-KEY"},
		"safe":   "visible",
		"list":   []any{map[string]any{"password": "SECRET-PW"}},
	}
	masked := transport.RedactMap(blob)
	nested, _ := masked["nested"].(map[string]any)
	list, _ := masked["list"].([]any)
	first, _ := list[0].(map[string]any)
	ok4 := masked["token"] == "***" && nested["api_key"] == "***" &&
		masked["safe"] == "visible" && first["password"] == "***"
	checks = append(checks, Check{"O4 凭证脱敏", statusFor(ok4),
		"token/key/password → ***，业务字段原样保留"})

	return checks
}

// MockEnvVars 是 mock 模式用的假凭证（只存在于内存里）。
var MockEnvVars = map[string]string{
	"TRIPCOM_AID": "12345",
	"TRIPCOM_SID": "45678",
	"TRIPCOM_KEY": "MOCK-SECRET-KEY",
}

// MockProtocolChecks 用协议级 mock 验证适配器链路本身是对的（无需商务授权）。
//
// 覆盖：取 token / uuid 唯一 / 错误四分类 / 退避重试 / 幂等命中 / 报文归档脱敏 /
// 归一化 → 覆盖映射 → 路由 / token 自动刷新 / 业务幂等不重复外呼。
func MockProtocolChecks(ctx context.Context, cfg *config.File, rules *normalize.Rules,
	archiveDB, canonicalDB *store.DB, fixturesDir string) []Check {

	var checks []Check
	srv, err := mock.New(filepath.Join(fixturesDir, "trip_com_catalog.json"))
	if err != nil {
		return []Check{{"M0 mock 启动", StatusFail, err.Error()}}
	}
	defer srv.Close()

	// 端点指向本地 mock，并加几个测试专用接口
	clone := *cfg
	clone.Sources = map[string]*config.Source{}
	for k, v := range cfg.Sources {
		c := *v
		clone.Sources[k] = &c
	}
	tripCfg := clone.Sources["trip_com"]
	tripCfg.Interfaces = map[string]config.Interface{}
	for k, v := range cfg.Sources["trip_com"].Interfaces {
		tripCfg.Interfaces[k] = v
	}
	for name, icode := range map[string]string{
		"testRetry": "TESTRETRY01",
		"testFatal": "TESTFATAL01",
		"testIdem":  "TESTIDEM01",
		"testAuth":  "TESTAUTH01",
	} {
		tripCfg.Interfaces[name] = config.Interface{
			Section: "TEST", Summary: "mock 自检专用", ICodeSandbox: icode, ICodeProd: icode,
		}
	}

	port, err := registry.Build("trip_com", &clone, registry.Options{
		Env: "sandbox", DB: archiveDB, EnvVars: MockEnvVars,
		RequireCredentials: false, Archive: true, Idempotency: true,
		EndpointOverride: map[string]map[string]string{"sandbox": srv.Endpoints()},
	})
	if err != nil {
		return []Check{{"M0 适配器构造", StatusFail, err.Error()}}
	}
	adapter, ok := port.(*tripcom.Adapter)
	if !ok {
		return []Check{{"M0 适配器类型", StatusFail, "不是 tripcom.Adapter"}}
	}

	// M1 取 token
	if _, err := adapter.Authenticate(ctx); err != nil {
		checks = append(checks, Check{"M1 取 token", StatusFail, err.Error()})
	} else {
		_, _, tokenReqs, _ := srv.State().Snapshot()
		checks = append(checks, Check{"M1 取 token", statusFor(tokenReqs == 1),
			fmt.Sprintf("authorize 调用 %d 次", tokenReqs)})
	}

	// M2 query 参数齐全 + uuid 每请求唯一
	if _, err := adapter.GetCategories(ctx); err != nil {
		checks = append(checks, Check{"M2 请求参数", StatusFail, err.Error()})
	} else if _, err := adapter.GetCategories(ctx); err != nil {
		checks = append(checks, Check{"M2 请求参数", StatusFail, err.Error()})
	} else {
		_, requests, _, _ := srv.State().Snapshot()
		var svc []mock.Request
		for _, r := range requests {
			if strings.HasSuffix(r.Path, "serviceproxy.ashx") {
				svc = append(svc, r)
			}
		}
		qOK := true
		uuids := map[string]bool{}
		for _, r := range svc {
			if r.Query["aid"] == "" || r.Query["sid"] == "" || r.Query["icode"] == "" || r.Query["token"] == "" {
				qOK = false
			}
			uuids[r.Query["uuid"]] = true
		}
		unique := len(uuids) == len(svc)
		checks = append(checks, Check{"M2 请求参数", statusFor(qOK && unique && len(svc) == 2),
			fmt.Sprintf("query 齐全=%v；uuid 唯一=%v（%d 次业务调用）", qOK, unique, len(svc))})
	}

	// M3 retriable → 退避重试后成功
	srv.State().ResetCalls("TESTRETRY01")
	if _, err := adapter.Call(ctx, "testRetry", map[string]any{}, ""); err != nil {
		checks = append(checks, Check{"M3 retriable 重试", StatusFail, err.Error()})
	} else {
		n := srv.State().Calls("TESTRETRY01")
		checks = append(checks, Check{"M3 retriable 重试", statusFor(n == 3),
			fmt.Sprintf("前 2 次 S0001 → 第 3 次成功，共调 %d 次", n)})
	}

	// M4 fatal → 不重试，立即失败
	srv.State().ResetCalls("TESTFATAL01")
	err = callExpectError(ctx, adapter, "testFatal")
	ae, isAppErr := err.(*apperr.Error)
	checks = append(checks, Check{"M4 fatal 不重试",
		statusFor(isAppErr && ae.Class == apperr.ClassFatal && srv.State().Calls("TESTFATAL01") == 1),
		fmt.Sprintf("B0005 库存不足 → %s，只调 %d 次", classOf(err), srv.State().Calls("TESTFATAL01"))})

	// M5 auth → 不当可重试错误；最多刷新 token 后再试 1 次
	srv.State().ResetCalls("TESTAUTH01")
	err = callExpectError(ctx, adapter, "testAuth")
	ae, isAppErr = err.(*apperr.Error)
	checks = append(checks, Check{"M5 auth 不无限重试",
		statusFor(isAppErr && ae.Class == apperr.ClassAuth && srv.State().Calls("TESTAUTH01") <= 2),
		fmt.Sprintf("V0003 → %s，共调 %d 次（刷新后最多再试 1 次）",
			classOf(err), srv.State().Calls("TESTAUTH01"))})

	// M6 B0010 = 幂等命中，不是失败
	res, err := adapter.Call(ctx, "testIdem", map[string]any{}, "")
	if err != nil {
		checks = append(checks, Check{"M6 幂等命中识别", StatusFail, err.Error()})
	} else {
		checks = append(checks, Check{"M6 幂等命中识别", statusFor(res.IdempotentHit),
			"B0010 重复下单 → " + map[bool]string{true: "识别为幂等命中，不当失败", false: "未识别"}[res.IdempotentHit]})
	}

	// M7 报文归档 + 脱敏
	if archiveDB == nil {
		checks = append(checks, Check{"M7 报文归档脱敏", StatusSkip, "未配置归档库"})
	} else {
		rows, qerr := archiveDB.Rows("SELECT entity_type, request::text, response::text FROM supplier_raw_payload " +
			"ORDER BY id DESC LIMIT 20;")
		if qerr != nil {
			checks = append(checks, Check{"M7 报文归档脱敏", StatusFail, qerr.Error()})
		} else {
			leaked := 0
			for _, r := range rows {
				blob := r["request"] + r["response"]
				if strings.Contains(blob, "MOCK-SECRET-KEY") || strings.Contains(blob, "MOCK-ACCESS-TOKEN") {
					leaked++
				}
			}
			checks = append(checks, Check{"M7 报文归档脱敏", statusFor(len(rows) > 0 && leaked == 0),
				fmt.Sprintf("归档 %d 条；凭证泄露 %d 条", len(rows), leaked)})
		}
	}

	// M8 归一化 → 覆盖映射 → 路由
	search, err := adapter.ListProducts(ctx, nil)
	if err != nil {
		checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail, err.Error()})
	} else {
		ids := ExtractProductIDs(search)
		if len(ids) == 0 {
			checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail, "目录层未返回产品 id"})
		} else {
			pid := IDString(ids[0])
			detail, err := adapter.GetProduct(ctx, pid)
			if err != nil {
				checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail, err.Error()})
			} else {
				start := DefaultStartDate()
				price, err := adapter.GetPriceCalendar(ctx, pid, start, DefaultEndDate(start))
				if err != nil {
					checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail, err.Error()})
				} else {
					payload := BuildNormalizePayload(detail, price)
					result, err := rules.Normalize("trip_com", payload)
					if err != nil {
						checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail, err.Error()})
					} else {
						canonical, cerr := coverage.LoadCanonical(canonicalDB)
						if cerr != nil {
							checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail,
								"读规范库失败: " + cerr.Error()})
						} else {
							hitKeys := []string{}
							for _, sv := range result.Variants {
								// 覆盖判定走库里的 fn_variant_covered —— 这条规则只有一份实现。
								verdicts, verr := coverage.Judge(canonicalDB, coverage.JSON(sv.Coverage), canonical)
								if verr != nil {
									checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail,
										"判定覆盖失败: " + verr.Error()})
									continue
								}
								for _, v := range verdicts {
									if v.CanFulfil {
										hitKeys = append(hitKeys, v.Key)
									}
								}
							}
							hitKeys = dedupSorted(hitKeys)
							cands, cerr := RoutingCandidates(canonicalDB, hitKeys)
							if cerr != nil {
								checks = append(checks, Check{"M8 归一化→映射→路由", StatusFail,
									"读路由候选失败: " + cerr.Error()})
							} else {
								withRoute := 0
								for _, k := range hitKeys {
									if len(cands[k]) > 0 {
										withRoute++
									}
								}
								checks = append(checks, Check{"M8 归一化→映射→路由",
									statusFor(len(result.Variants) > 0 && len(hitKeys) > 0),
									fmt.Sprintf("源变体 %d → 命中规范变体 %d（规范库 %d 条）→ 有路由候选 %d",
										len(result.Variants), len(hitKeys), len(canonical), withRoute)})
							}
						}
					}
				}
			}
		}
	}

	// M9 token 过期 → 自动刷新后重试
	_, _, _, beforeRefresh := srv.State().Snapshot()
	srv.State().ExpireNextToken()
	if _, err := adapter.GetCategories(ctx); err != nil {
		checks = append(checks, Check{"M9 token 自动刷新", StatusFail, err.Error()})
	} else {
		_, _, _, afterRefresh := srv.State().Snapshot()
		checks = append(checks, Check{"M9 token 自动刷新", statusFor(afterRefresh == beforeRefresh+1),
			fmt.Sprintf("业务返回 1004 → 自动 refresh %d 次 → 重试成功", afterRefresh-beforeRefresh)})
	}

	// M10 业务幂等：同一 distributorOrderID 重复下单 → 第二次命中本地幂等，不重复外呼
	before := srv.State().Calls(mock.ICodeBook)
	key := fmt.Sprintf("MOCK-IDEMPOTENCY-%d", time.Now().UnixNano())
	body := map[string]any{
		"basicOrder": map[string]any{"productID": 21081935, "poiID": 1,
			"amount": 558.0, "packageID": 810001, "orderResourceList": []any{}},
		"contact":       map[string]any{"name": "测试", "mobile": map[string]any{"mobileNumber": "13800000000"}},
		"passengerList": []any{}, "currency": "CNY", "locale": "zh-CN",
	}
	if _, err := adapter.CreateBooking(ctx, body, key); err != nil {
		checks = append(checks, Check{"M10 业务幂等", StatusFail, err.Error()})
	} else if _, err := adapter.CreateBooking(ctx, body, key); err != nil {
		checks = append(checks, Check{"M10 业务幂等", StatusFail, err.Error()})
	} else {
		after := srv.State().Calls(mock.ICodeBook)
		checks = append(checks, Check{"M10 业务幂等", statusFor(after-before == 1),
			fmt.Sprintf("同一 distributorOrderID 调 2 次，源侧只收到 %d 次", after-before)})
	}

	return checks
}

func callExpectError(ctx context.Context, adapter *tripcom.Adapter, op string) error {
	_, err := adapter.Call(ctx, op, map[string]any{}, "")
	return err
}

func classOf(err error) string {
	if ae, ok := err.(*apperr.Error); ok {
		return string(ae.Class)
	}
	if err == nil {
		return "无异常"
	}
	return "非适配器错误"
}

// PortOf 断言一个适配器实现了端口（编译期检查）。
var _ supplier.Port = (*tripcom.Adapter)(nil)
