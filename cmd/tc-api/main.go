// Command tc-api 是 C 端的只读 API 服务。
//
// 它只读 C 端读模型（c_product_card / v_c_listing_feed / v_c_variant_feed /
// v_c_variant_composition / c_variant_calendar），**不在请求链路里 join 主数据**，
// 也不重算任何事实（见 internal/capi 的包注释）。
//
// 端点：
//
//	GET /healthz
//	GET /api/v1/products?channel_id=&locale=&limit=&offset=
//	GET /api/v1/products/{product_id}/variants?channel_id=
//	GET /api/v1/variants/{variant_id}/composition?channel_id=
//	GET /api/v1/variants/{variant_id}/calendar?channel_id=&from=&to=
//
// 用法：
//
//	tc-api --db ticket_center --addr :8080
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

	"ticket-center/internal/capi"
	"ticket-center/internal/store"
)

func main() {
	dbName := flag.String("db", envOr("PGDATABASE", "ticket_center"), "数据库名")
	addr := flag.String("addr", envOr("TC_API_ADDR", ":8080"), "监听地址")
	flag.Parse()

	db := store.New(*dbName)
	// 起服之前先探一次库：库不可达就别装成服务正常。
	if _, err := db.Scalar("SELECT 1;"); err != nil {
		fmt.Fprintf(os.Stderr, "数据库不可达（--db %s）：%v\n", *dbName, err)
		os.Exit(1)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           capi.New(db),
		ReadHeaderTimeout: 10 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		log.Printf("C 端只读 API 起在 %s（库 %s）", *addr, *dbName)
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

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
