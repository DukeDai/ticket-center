// Package bapi 是 B 端内部运营台的后端。
//
// 定位：票到我们这里就自营，没有分销商自助这一层 —— 所以这是**内部运营台**，
// 不是给外部分销商调用的开放平台。调用方是我们自己的运营人员。
//
// 它做两件事：
//
//	① 身份：谁在操作（b2b_operator + 会话 cookie）。
//	    写操作要能记「谁干的」—— 退款放行走 fn_approve_refund(approved_by)，
//	    改派要往明细快照的 reassignments 里留痕。共用一个密码的话，追责就断了。
//
//	② 读侧：跨渠道的运营视图（v_ops_*）。运营台是跨渠道的 ——
//	    C 端、B 端、企业客户各自的目录与订单都要能看到。
//
// 纪律：
//
//   - 读侧只读读模型（v_ops_*），不在请求链路里 join 主数据、不重算事实
//     （同硬约束 10 的精神）。成本与份数由库里的定价函数与读模型算好，这里只带出来。
//   - 金额一律以字符串出（NUMERIC，Go 没有十进制类型）。
//   - 写路径一律走库里的唯一实现（fn_place_order / fn_record_payment /
//     fn_issue_voucher / fn_request_refund / fn_approve_refund /
//     fn_reassign_order_item），Go 侧只拼参数、只读结果。
//   - 零第三方依赖：HTTP 用 net/http，模板用 html/template，签名用 crypto/hmac。
package bapi

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
	"time"

	"ticket-center/internal/store"
)

// Operator 是一个运营操作员。
type Operator struct {
	ID     int64  `json:"id"`
	Code   string `json:"code"`
	Name   string `json:"name"`
	Role   string `json:"role"`
	Status string `json:"status"`
}

// 角色。
//
// 三档而不是两档：放行退款与改派要记操作人（admin），
// 下单与发起退款是日常操作（operator），只读是看看（viewer）。
const (
	RoleAdmin    = "admin"
	RoleOperator = "operator"
	RoleViewer   = "viewer"
)

// CanWrite 能不能做写操作（下单、发起退款、出券、支付）。
func (o *Operator) CanWrite() bool {
	return o != nil && (o.Role == RoleAdmin || o.Role == RoleOperator)
}

// CanApprove 能不能做要留操作人痕迹的动作（放行退款、改派）。
func (o *Operator) CanApprove() bool {
	return o != nil && o.Role == RoleAdmin
}

// OperatorService 是操作员与凭证的读写入口。
type OperatorService struct {
	db *store.DB
}

// NewOperatorService 构造操作员服务。
func NewOperatorService(db *store.DB) *OperatorService {
	return &OperatorService{db: db}
}

// FindByCode 按 code 找操作员（带凭证哈希，用于校验）。
type operatorRecord struct {
	Operator
	KeyHash     string
	SessionSalt string
	Status      string
}

// Lookup 按 code 找操作员，凭证哈希一并带出。
func (s *OperatorService) Lookup(code string) (*operatorRecord, error) {
	if s.db == nil {
		return nil, fmt.Errorf("查操作员需要数据库连接")
	}
	code = strings.TrimSpace(code)
	if code == "" {
		return nil, fmt.Errorf("缺少操作员 code")
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, code, name, role, status, key_hash, session_salt
           FROM b2b_operator WHERE code = %s;`, store.Quote(code)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("操作员 %s 不存在", code)
	}
	r := rows[0]
	return &operatorRecord{
		Operator: Operator{
			ID:     parseInt64(r["id"]),
			Code:   r["code"],
			Name:   r["name"],
			Role:   r["role"],
			Status: strings.TrimSpace(r["status"]),
		},
		KeyHash:     strings.TrimSpace(r["key_hash"]),
		SessionSalt: strings.TrimSpace(r["session_salt"]),
		Status:      strings.TrimSpace(r["status"]),
	}, nil
}

// Login 校验凭证，成功返回操作员。
//
// 凭证比对用常量时间（crypto/subtle）—— 逐字节早退的比较会泄露前缀长度。
// 这不是「防侧信道攻击到极致」，是「别给自己留一个明显写着『这里可以试』的口子」。
func (s *OperatorService) Login(code, secret string) (*Operator, error) {
	rec, err := s.Lookup(code)
	if err != nil {
		// 不存在与密码错给同一个答复：不给调用方一个能枚举操作员 code 的探针。
		return nil, fmt.Errorf("操作员或凭证不对")
	}
	if rec.Status != "active" {
		return nil, fmt.Errorf("操作员已停用")
	}
	got := hashSecret(secret)
	if subtle.ConstantTimeCompare([]byte(got), []byte(rec.KeyHash)) != 1 {
		return nil, fmt.Errorf("操作员或凭证不对")
	}
	// 登录时间记一下：出问题时能看出「谁在这个点进过台」。
	if err := s.db.Exec(fmt.Sprintf(
		`UPDATE b2b_operator SET last_login_at = now() WHERE id = %s;`,
		store.Quote(rec.ID))); err != nil {
		return nil, store.PLError(err)
	}
	op := rec.Operator
	return &op, nil
}

// hashSecret 是凭证的哈希口径。
//
// sha256 不是密码学上「正确」的密码哈希（那要用 bcrypt/scrypt/argon2），
// 但本项目零第三方依赖，而运营凭证是**高熵随机串**（不是人选的密码）——
// 高熵串用 sha256 没有字典攻击面。凭证由 NewSecret 生成，不许人选。
func hashSecret(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// HashSecret 是凭证哈希的对外读法。
//
// 给 CLI 的「换凭证」用：它要把新凭证的哈希写回库里。
// 只有这一处需要对外 —— 别的调用方不该自己算哈希
// （哈希口径散出去，就会有第二个地方算出不一样的值）。
func HashSecret(secret string) string {
	return hashSecret(secret)
}

// NewSecret 生成一份高熵凭证。
//
// 24 字节随机 = 192 位熵。读成人眼无法准确转录的长度是故意的 ——
// 凭证只在创建时显示一次，抄错就重新生成，不要去猜。
func NewSecret() (string, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成凭证失败：%w", err)
	}
	return "tk_op_" + base64.RawURLEncoding.EncodeToString(buf), nil
}

// NewSalt 生成会话盐。
func NewSalt() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("生成盐失败：%w", err)
	}
	return hex.EncodeToString(buf), nil
}

// Create 创建一个操作员，返回明文凭证（只在这一次显示）。
func (s *OperatorService) Create(code, name, role string) (string, error) {
	if s.db == nil {
		return "", fmt.Errorf("建操作员需要数据库连接")
	}
	code = strings.TrimSpace(code)
	name = strings.TrimSpace(name)
	if code == "" {
		return "", fmt.Errorf("操作员 code 不能为空")
	}
	if name == "" {
		return "", fmt.Errorf("操作员姓名不能为空")
	}
	switch role {
	case RoleAdmin, RoleOperator, RoleViewer:
	default:
		return "", fmt.Errorf("角色只能是 %s / %s / %s，收到 %q",
			RoleAdmin, RoleOperator, RoleViewer, role)
	}
	secret, err := NewSecret()
	if err != nil {
		return "", err
	}
	salt, err := NewSalt()
	if err != nil {
		return "", err
	}
	sql := fmt.Sprintf(
		`INSERT INTO b2b_operator (code, name, key_hash, role, session_salt)
              VALUES (%s, %s, %s, %s, %s);`,
		store.Quote(code), store.Quote(name), store.Quote(hashSecret(secret)),
		store.Quote(role), store.Quote(salt))
	if err := s.db.Exec(sql); err != nil {
		return "", store.PLError(err)
	}
	return secret, nil
}

// List 列出全部操作员。
//
// 带出状态：停用的人列出来却看不出他停了，列表就骗人。
func (s *OperatorService) List() ([]Operator, error) {
	if s.db == nil {
		return nil, fmt.Errorf("列操作员需要数据库连接")
	}
	rows, err := s.db.Rows(
		`SELECT id, code, name, role, status FROM b2b_operator ORDER BY id;`)
	if err != nil {
		return nil, store.PLError(err)
	}
	out := make([]Operator, 0, len(rows))
	for _, r := range rows {
		out = append(out, Operator{
			ID:     parseInt64(r["id"]),
			Code:   r["code"],
			Name:   r["name"],
			Role:   r["role"],
			Status: strings.TrimSpace(r["status"]),
		})
	}
	return out, nil
}

// -------------------------------------------------------------------------------------
// 会话
// -------------------------------------------------------------------------------------

// 会话有效期。
//
// 运营台是内部工具，但会话照样要过期 —— 浏览器关掉不登出是常态，
// 一直有效的 cookie 等于把凭证长期摊在磁盘上。
const sessionTTL = 8 * time.Hour

// sessionCookie 是会话 cookie 的名字。
const sessionCookie = "tc_ops_session"

// IssueSession 给操作员签一份会话。
//
// 签名用 HMAC-SHA256，密钥是「凭证哈希 + 会话盐」：
//   - 凭证哈希是机密的（只有库里有哈希，不在库里的是明文）；
//   - 会话盐让「换盐 ⇒ 旧会话全失效」成为可能（撤销操作员时用得上）。
//
// 会话内容是「操作员 id | 签发时刻 | 过期时刻」，整体做 base64url 编码后签名。
// 不含密钥，所以改盐就改不了已签发的会话。
func IssueSession(rec *operatorRecord, now time.Time) (string, error) {
	exp := now.Add(sessionTTL)
	payload := fmt.Sprintf("%d|%d|%d", rec.ID, now.Unix(), exp.Unix())
	enc := base64.RawURLEncoding.EncodeToString([]byte(payload))
	mac := hmac.New(sha256.New, []byte(rec.KeyHash+":"+rec.SessionSalt))
	mac.Write([]byte(enc))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return enc + "." + sig, nil
}

// VerifySession 校验会话并回填操作员。
//
// 验签不通过 → 拒绝。验签通过但操作员已停用 → 拒绝（停用要立刻生效，
// 不能等到会话自然过期）。
func (s *OperatorService) VerifySession(token string, now time.Time) (*Operator, error) {
	parts := strings.Split(strings.TrimSpace(token), ".")
	if len(parts) != 2 {
		return nil, fmt.Errorf("会话格式不对")
	}
	enc, sig := parts[0], parts[1]
	// 先查操作员：签名密钥依赖它的 key_hash 与 session_salt。
	// 令牌里带着操作员 id，但 id 是明文可改的 —— 所以 id 只用来定位，
	// 真正的凭据是签名对不上。
	id, err := parseSessionPayload(enc)
	if err != nil {
		return nil, err
	}
	rows, err := s.db.Rows(fmt.Sprintf(
		`SELECT id, code, name, role, status, key_hash, session_salt
           FROM b2b_operator WHERE id = %s;`, store.Quote(id)))
	if err != nil {
		return nil, store.PLError(err)
	}
	if len(rows) == 0 {
		return nil, fmt.Errorf("会话对应的操作员不存在")
	}
	r := rows[0]
	rec := &operatorRecord{
		Operator: Operator{
			ID:     parseInt64(r["id"]),
			Code:   r["code"],
			Name:   r["name"],
			Role:   r["role"],
			Status: strings.TrimSpace(r["status"]),
		},
		KeyHash:     strings.TrimSpace(r["key_hash"]),
		SessionSalt: strings.TrimSpace(r["session_salt"]),
		Status:      strings.TrimSpace(r["status"]),
	}
	expected := hmac.New(sha256.New, []byte(rec.KeyHash+":"+rec.SessionSalt))
	expected.Write([]byte(enc))
	want := base64.RawURLEncoding.EncodeToString(expected.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(want), []byte(sig)) != 1 {
		return nil, fmt.Errorf("会话签名不对")
	}
	if rec.Status != "active" {
		return nil, fmt.Errorf("操作员已停用")
	}
	exp, err := sessionExpiry(enc)
	if err != nil {
		return nil, err
	}
	if now.After(exp) {
		return nil, fmt.Errorf("会话已过期")
	}
	op := rec.Operator
	return &op, nil
}

// parseSessionPayload 从令牌里读出操作员 id 与过期时刻。
func parseSessionPayload(enc string) (int64, error) {
	raw, err := base64.RawURLEncoding.DecodeString(enc)
	if err != nil {
		return 0, fmt.Errorf("会话格式不对")
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 3 {
		return 0, fmt.Errorf("会话格式不对")
	}
	id, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || id <= 0 {
		return 0, fmt.Errorf("会话格式不对")
	}
	return id, nil
}

// sessionExpiry 读出令牌的过期时刻。
func sessionExpiry(enc string) (time.Time, error) {
	raw, err := base64.RawURLEncoding.DecodeString(enc)
	if err != nil {
		return time.Time{}, fmt.Errorf("会话格式不对")
	}
	parts := strings.Split(string(raw), "|")
	if len(parts) != 3 {
		return time.Time{}, fmt.Errorf("会话格式不对")
	}
	unix, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("会话格式不对")
	}
	return time.Unix(unix, 0), nil
}

// parseInt64 读库里的整数字段。
func parseInt64(s string) int64 {
	n, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n
}
