package bapi

import (
	"io/fs"
	"net/http"
	"strings"
)

// handleStatic 提供静态资源（CSS 等）。
//
// 资源在二进制里（go:embed），部署时不用带文件。
// 路径要从 web/static 底下取 —— 不能让请求路径直接拼进 fs 的路径，
// 否则 "/static/../web/templates/console.html" 能把模板读出去。
func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	sub, err := fs.Sub(webFS, "web/static")
	if err != nil {
		internalErr(w, "静态资源不可用")
		return
	}
	name := strings.TrimPrefix(r.URL.Path, "/static/")
	if name == "" || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	data, err := fs.ReadFile(sub, name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", contentType(name))
	// 资源在二进制里，没有文件时间，也没有 Range 支持的必要 ——
	// 运营台的静态资源只有一份 CSS。
	w.Write(data)
}

// handleRoot 是根路径：已登录去运营台，没登录去登录页。
func (s *Server) handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		s.handleNotFound(w, r)
		return
	}
	if c, err := r.Cookie(sessionCookie); err == nil && strings.TrimSpace(c.Value) != "" {
		if op, err := s.ops.VerifySession(c.Value, s.nowFn()); err == nil && op != nil {
			http.Redirect(w, r, "/console", http.StatusSeeOther)
			return
		}
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

// contentType 按扩展名给静态资源定类型。
//
// 只认自己用到的几种，不读系统 mime 数据库 ——
// 那会让同一个文件在不同机器上返回不同的类型。
func contentType(name string) string {
	switch {
	case strings.HasSuffix(name, ".css"):
		return "text/css; charset=utf-8"
	case strings.HasSuffix(name, ".js"):
		return "application/javascript; charset=utf-8"
	case strings.HasSuffix(name, ".svg"):
		return "image/svg+xml"
	case strings.HasSuffix(name, ".png"):
		return "image/png"
	case strings.HasSuffix(name, ".ico"):
		return "image/x-icon"
	default:
		return "application/octet-stream"
	}
}
