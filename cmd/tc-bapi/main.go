// Command tc-bapi 是 B 端内部运营台的服务。
//
// 它同时提供 RESTful API 与网页界面：
//
//	网页    GET  /login          登录页
//	       GET  /console         运营台（总览 / 订单 / 履约缺口 / 供给形态 /
//	                              退款 / 核销 / 源与结算 / 库存预占 / 待改派）
//	       GET  /static/…        静态资源
//
//	API     POST /api/v1/auth/login            登录（签发会话 cookie）
//	       POST /api/v1/auth/logout           登出
//	       GET  /api/v1/auth/me               当前操作员
//	       GET  /api/v1/channels               渠道总览
//	       GET  /api/v1/products               商品目录
//	       GET  /api/v1/orders                 订单列表
//	       GET  /api/v1/orders/{id}            订单详情
//	       GET  /api/v1/fulfillment/gaps       履约漏斗
//	       GET  /api/v1/supply-forms           供给形态对照
//	       GET  /api/v1/refunds                退款台账
//	       GET  /api/v1/redemptions            核销记录
//	       GET  /api/v1/inventory/holds        库存预占
//	       GET  /api/v1/suppliers/health       源健康度
//	       GET  /api/v1/settlement/gaps        结算缺口
//	       GET  /api/v1/reassign/candidates    待改派清单
//	       GET  /api/v1/operators              操作员列表
//
//	写侧    POST /api/v1/orders                                 下单
//	       POST /api/v1/orders/{id}/payments                    支付入账
//	       POST /api/v1/bookings/{id}/vouchers                  出券
//	       POST /api/v1/refunds                                 发起退款
//	       POST /api/v1/refunds/{id}/approval                   放行退款
//	       POST /api/v1/orders/{id}/items/{item}/reassign       改派
//
// 用法：
//
//	tc-bapi --db ticket_center --addr :8090
//
// 环境变量：
//
//	TC_BAPI_ADDR      监听地址（默认 :8090）
//	TC_BAPI_SECURE    设为 1 时会话 cookie 带 Secure 标记（生产走 HTTPS 时开）
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"ticket-center/internal/bapi"
	"ticket-center/internal/store"
)

func main() {
	dbName := flag.String("db", envOr("PGDATABASE", "ticket_center"), "数据库名")
	addr := flag.String("addr", envOr("TC_BAPI_ADDR", ":8090"), "监听地址")
	secure := flag.Bool("secure", os.Getenv("TC_BAPI_SECURE") == "1",
		"会话 cookie 带 Secure 标记（生产走 HTTPS 时开）")
	flag.Parse()

	db := store.New(*dbName)
	// 起服之前先探一次库：库不可达就别装成服务正常。
	if _, err := db.Scalar("SELECT 1;"); err != nil {
		fmt.Fprintf(os.Stderr, "数据库不可达（--db %s）：%v\n", *dbName, err)
		os.Exit(1)
	}
	// 运营读模型在迁移 035 里。先确认视图在，再起服 ——
	// 缺视图就起来的话，每个页面都是 500，错误还散在各处。
	if err := requireOpsViews(db); err != nil {
		fmt.Fprintf(os.Stderr, "运营读模型不可用（--db %s）：%v\n", *dbName, err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           bapi.New(db, bapi.Options{Secure: *secure}),
		ReadHeaderTimeout: 10 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("B 端运营台起在 %s（库 %s）", *addr, *dbName)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("服务退出：%v", err)
		}
	}()

	<-stop
	log.Println("收到停止信号，正在收尾……")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("收尾没干净：%v", err)
	}
}

// requireOpsViews 确认运营读模型的视图都在。
//
// 少一个视图的表现是「某个页面 500，其他页面正常」——
// 那种问题排查起来最费时间。所以在起服时一次说清楚缺哪个。
func requireOpsViews(db *store.DB) error {
	views := []string{
		"v_ops_channel_overview",
		"v_ops_product_catalog",
		"v_ops_order_list",
		"v_ops_fulfillment_gap",
		"v_ops_supply_forms",
		"v_ops_refund_ledger",
		"v_ops_redemption_log",
		"v_ops_inventory_hold",
		"v_ops_supplier_health",
		"v_ops_settlement_gap",
		"v_ops_reassign_candidates",
	}
	var missing []string
	for _, v := range views {
		ok, err := db.TableExists(v)
		if err != nil {
			return fmt.Errorf("查视图 %s 时出错：%w", v, err)
		}
		if !ok {
			missing = append(missing, v)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("缺这些视图：%v（先跑 tc-connect migrate）", missing)
	}
	return nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
