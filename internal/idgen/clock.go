package idgen

import "time"

func timeNow() string { return time.Now().UTC().Format(time.RFC3339Nano) }
