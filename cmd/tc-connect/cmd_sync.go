// 目录同步作业：抓 → 归一化 → 落库。
//
// 它是 `tc-connect jobs` 的**一个分支**，不是另一条命令
// （spec/20-jobs.md §5.27 的表：`| tc-connect jobs | 唯一入口（§5.25）；同步作业是它的一个分支`）。
//
// **为什么不做成独立子命令**：作业调度有唯一入口（硬约束 39）——
// 作业在库里但没有人调它，作业就只是库里一个没人跑函数。同一个 cron 调一条命令，
// 凭证过期、预占过期、目录同步、读模型刷新一次跑完，
// 少一条命令就少一处「谁负责跑」的答案。
//
// **为什么要 --sync 才跑**：同步作业要连外部源、要凭证；
// 而凭证过期、预占过期、读模型刷新是纯库内维护 ——
// 让前者依赖后者的运行环境，等于把「某个源没配 API key」
// 变成「每 5 分钟的库维护作业失败一次」。两者分开走各自的 cron 行，
// 间隔仍然是运维的决定（硬约束 39：间隔不写在代码里）。
//
// 口径在 spec/20-jobs.md §5.27，实现在 internal/sync。
package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"ticket-center/internal/config"
	"ticket-center/internal/normalize"
	"ticket-center/internal/store"
	"ticket-center/internal/sync"
)

// syncFlags 是同步分支的开关。
//
// 它们只在 `jobs --sync` 时有意义；不带 --sync 就一个都不读。
type syncFlags struct {
	supplier string
	env      string
	timeout  time.Duration
	start    string
	end      string
}

// runSyncBranch 跑一遍目录同步作业。
//
// **失败非零退出**：重试交给调度器按自己的策略决定。
// 作业本身是幂等的（幂等边界是现有的唯一键），重跑一遍不会多落什么。
//
// 一个源失败**不**中断其余的源 —— 中断的话，
// 「第一个源坏了，后面五个源永远同步不上」会成为常态。
// 全部跑完再统一返回失败。
func runSyncBranch(db *store.DB, flags syncFlags) error {
	root := findRoot()
	configPath := filepath.Join(root, "configs", "api_config.json")
	rulesPath := filepath.Join(root, "configs", "mapping_rules.json")

	cfg, err := config.Load(configPath)
	if err != nil {
		return err
	}
	rules, err := normalize.LoadRules(rulesPath)
	if err != nil {
		return err
	}

	codes := syncTargets(cfg, flags.supplier)
	if len(codes) == 0 {
		return fmt.Errorf("没有要同步的源：配置里一个已确认的源都没有")
	}

	failed := 0
	for _, code := range codes {
		ledger, err := sync.Run(context.Background(), code, sync.Options{
			DB:      db,
			Config:  cfg,
			Rules:   rules,
			Env:     flags.env,
			EnvVars: envVars(),
			Timeout: flags.timeout,
			Start:   flags.start,
			End:     flags.end,
		})
		if err != nil {
			failed++
			fmt.Printf("源 %s 同步失败：%v\n", code, err)
			continue
		}
		fmt.Printf("源 %s 同步完成：扫 %d 条，新建 %d，更新 %d，跳过 %d，失败 %d。\n",
			code, ledger.Stats.Scanned, ledger.Stats.Created, ledger.Stats.Updated,
			ledger.Stats.Skipped, ledger.Stats.Failed)
	}

	if failed > 0 {
		return fmt.Errorf("%d 个源同步失败", failed)
	}
	return nil
}

// syncTargets 决定这次同步哪些源。
//
// **默认只同步配置里「已确认」的源** —— 不写死清单（写死就成了第二份口径：
// 加一个源要改两处，而且改漏一处没人知道），而是读配置里那份确认状态。
//
// 为什么只同步已确认的源：没确认的源端点是**没定的**
// （硬约束 13：没有公开文档的接口不许编造）。硬跑它们只会每次报
// 「接口细节待确认」—— 那是噪音，不是信号：它把「该源还没接通」说成
// 「同步作业坏了」。
//
// 指定 --supplier 时**只跑那一个**，且不要求它已确认：
// 运维点名要跑哪个源，就是要跑它（调试与排障用）。
func syncTargets(cfg *config.File, only string) []string {
	if only != "" {
		return []string{only}
	}
	out := make([]string, 0, len(cfg.Sources))
	for _, code := range cfg.Codes() {
		src, err := cfg.Get(code)
		if err != nil {
			continue
		}
		if !src.Confirmed {
			continue
		}
		out = append(out, code)
	}
	return out
}

// envVars 收集进程环境作为凭证来源。
//
// **凭证只从环境变量读**（硬约束 12）：没有凭证就明确报「缺哪个环境变量」，
// 不猜、不硬编码、不用假值糊过去。
func envVars() map[string]string {
	out := map[string]string{}
	for _, kv := range os.Environ() {
		i := strings.Index(kv, "=")
		if i <= 0 {
			continue
		}
		out[kv[:i]] = kv[i+1:]
	}
	return out
}
