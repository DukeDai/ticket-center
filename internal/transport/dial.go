package transport

import (
	"net"
	"time"
)

// netDialTimeout 建立带超时的 TCP 连接（仅用于连通性探测）。
func netDialTimeout(addr string, timeout time.Duration) (net.Conn, error) {
	return net.DialTimeout("tcp", addr, timeout)
}
