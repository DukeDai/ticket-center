-- =====================================================================================
-- 003 交易侧状态机与领域事件
--
-- 状态机以前只活在 SPEC.md 的图里，谁 UPDATE 一下 sales_order.status 都行 ——
-- 「订单从 paid 直接跳 fulfilled」在库里是合法的，客诉时才发现对不上。
--
-- 这一份迁移把状态机变成机制：
--   ① state_transition：合法流转的唯一来源（表里写死，代码不许另排一份）；
--   ② 触发器 fn_guard_state_transition：非法流转直接报错，改不动；
--   ③ 触发器 fn_emit_state_event：状态一变就往 event_outbox 写领域事件，
--      「状态改了但事件丢了」从此不可能发生（SPEC.md §6）。
--
-- 不变量在 v_invariant_checks_tx 里：状态可达、订单与预订/凭证对得上。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 合法流转表
--
-- from_status = '' 表示「刚创建」这一条边（INSERT 时落在这个状态）。
-- event_type 为 NULL 的流转不发事件。
-- -------------------------------------------------------------------------------------
CREATE TABLE state_transition (
    aggregate_type TEXT NOT NULL,
    from_status    TEXT NOT NULL,
    to_status      TEXT NOT NULL,
    event_type     TEXT,
    CONSTRAINT state_transition_pk PRIMARY KEY (aggregate_type, from_status, to_status)
);

COMMENT ON TABLE state_transition IS '交易侧状态机的合法流转（唯一来源）：状态只能沿表里的边走';

INSERT INTO state_transition (aggregate_type, from_status, to_status, event_type) VALUES
-- 订单（SPEC.md §5.1）
('order','','created','OrderPlaced'),
('order','created','awaiting_payment','OrderAwaitingPayment'),
('order','created','expired','OrderExpired'),
('order','created','cancelled','OrderCancelled'),
('order','awaiting_payment','paid','OrderPaid'),
('order','awaiting_payment','expired','OrderExpired'),
('order','awaiting_payment','cancelled','OrderCancelled'),
('order','paid','booking_pending','OrderBookingPending'),
('order','paid','confirmed','OrderConfirmed'),
('order','paid','failed','OrderFailed'),
('order','paid','cancelled','OrderCancelled'),
('order','paid','refunding','RefundRequested'),
('order','booking_pending','confirmed','OrderConfirmed'),
('order','booking_pending','partially_fulfilled','OrderConfirmed'),
('order','booking_pending','fulfilled','OrderConfirmed'),
('order','booking_pending','failed','OrderFailed'),
('order','booking_pending','cancelled','OrderCancelled'),
('order','confirmed','fulfilled','OrderFulfilled'),
('order','confirmed','partially_fulfilled','OrderPartiallyFulfilled'),
('order','confirmed','cancelled','OrderCancelled'),
('order','confirmed','refunding','RefundRequested'),
('order','partially_fulfilled','fulfilled','OrderFulfilled'),
('order','partially_fulfilled','cancelled','OrderCancelled'),
('order','partially_fulfilled','refunding','RefundRequested'),
('order','fulfilled','refunding','RefundRequested'),
('order','failed','refunding','RefundRequested'),
('order','failed','cancelled','OrderCancelled'),
('order','refunding','refunded','OrderRefunded'),
('order','refunding','failed','OrderFailed'),
-- 预订（SPEC.md §5.2）
('booking','','pending','BookingCreated'),
('booking','pending','requested','BookingRequested'),
('booking','pending','cancelled','BookingCancelled'),
('booking','pending','expired','BookingExpired'),
('booking','requested','confirmed','BookingConfirmed'),
('booking','requested','failed','BookingFailed'),
('booking','requested','cancelled','BookingCancelled'),
('booking','requested','expired','BookingExpired'),
('booking','confirmed','ticketed','BookingTicketed'),
('booking','confirmed','partially_cancelled','BookingPartiallyCancelled'),
('booking','confirmed','cancelled','BookingCancelled'),
('booking','ticketed','partially_cancelled','BookingPartiallyCancelled'),
('booking','ticketed','cancelled','BookingCancelled'),
('booking','failed','pending','BookingRetryScheduled'),
-- 凭证（SPEC.md §5.3）
('voucher','','pending','VoucherCreated'),
('voucher','pending','issued','VoucherIssued'),
('voucher','pending','void','VoucherVoided'),
('voucher','pending','expired','VoucherExpired'),
('voucher','pending','refunded','VoucherRefunded'),
('voucher','issued','used','VoucherRedeemed'),
('voucher','issued','void','VoucherVoided'),
('voucher','issued','expired','VoucherExpired'),
('voucher','issued','refunded','VoucherRefunded'),
('voucher','void','refunded','VoucherRefunded'),
('voucher','expired','refunded','VoucherRefunded'),
-- 订单明细（没有对外事件，只是状态不许乱跳）
('order_item','','pending',NULL),
('order_item','pending','booking',NULL),
('order_item','pending','confirmed',NULL),
('order_item','pending','ticketed',NULL),
('order_item','pending','failed',NULL),
('order_item','pending','cancelled',NULL),
('order_item','booking','confirmed',NULL),
('order_item','booking','ticketed',NULL),
('order_item','booking','failed',NULL),
('order_item','booking','cancelled',NULL),
('order_item','confirmed','ticketed',NULL),
('order_item','confirmed','cancelled',NULL),
('order_item','confirmed','refunded',NULL),
('order_item','ticketed','refunded',NULL),
('order_item','failed','cancelled',NULL),
('order_item','failed','refunded',NULL),
('order_item','cancelled','refunded',NULL);

-- -------------------------------------------------------------------------------------
-- ② 表名 → 聚合名
--
-- 用聚合名（order / booking / voucher / order_item）而不是表名，
-- 因为 event_outbox.aggregate_type 记的是领域聚合（seed 里的历史事件也是这个口径）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_aggregate_type(p_table TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_table
           WHEN 'sales_order'      THEN 'order'
           WHEN 'sales_order_item' THEN 'order_item'
           WHEN 'booking'          THEN 'booking'
           WHEN 'voucher'          THEN 'voucher'
           ELSE p_table
         END;
$$;

-- 合法流转判定
CREATE FUNCTION fn_state_transition_allowed(p_aggregate TEXT, p_from TEXT, p_to TEXT) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM state_transition st
                  WHERE st.aggregate_type = p_aggregate
                    AND st.from_status  = p_from
                    AND st.to_status    = p_to);
$$;

-- -------------------------------------------------------------------------------------
-- ③ 守卫：非法流转直接报错
--
-- 这是「状态机由机制保证」的落点。改不动，就没法偷偷把订单从 paid 跳到 fulfilled。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_guard_state_transition() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_agg  TEXT;
  v_from TEXT;
  v_to   TEXT;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_agg  := fn_aggregate_type(TG_TABLE_NAME);
  v_from := OLD.status;
  v_to   := NEW.status;

  IF NOT fn_state_transition_allowed(v_agg, v_from, v_to) THEN
    RAISE EXCEPTION '非法状态流转：% % → %（表 %，id=%）',
      v_agg, v_from, v_to, TG_TABLE_NAME, OLD.id
      USING ERRCODE = '23514',
            HINT = '合法流转见 state_transition 表与 SPEC.md §5；不允许跳过中间态';
  END IF;

  RETURN NEW;
END;
$$;

-- -------------------------------------------------------------------------------------
-- ④ 事件：状态一变就进 outbox
--
-- SPEC.md §6：「事件统一经 event_outbox 落库后发布，保证状态已改但事件丢失不发生」。
-- 触发器写在库里，所以不管谁改状态（Go、psql、脚本），事件都不会漏。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_emit_state_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_agg    TEXT;
  v_from   TEXT := '';
  v_to     TEXT;
  v_event  TEXT;
  v_payload JSONB;
BEGIN
  v_agg := fn_aggregate_type(TG_TABLE_NAME);
  v_to  := NEW.status;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
      RETURN NULL;
    END IF;
    v_from := OLD.status;
  END IF;

  SELECT st.event_type INTO v_event
    FROM state_transition st
   WHERE st.aggregate_type = v_agg
     AND st.from_status    = v_from
     AND st.to_status      = v_to;

  -- 没有对应领域事件的流转（例如订单明细）不发事件。
  IF v_event IS NULL THEN
    RETURN NULL;
  END IF;

  v_payload := jsonb_build_object(
    'aggregate_type', v_agg,
    'aggregate_id',   NEW.id,
    'from_status',    NULLIF(v_from, ''),
    'to_status',      v_to);

  IF TG_TABLE_NAME = 'sales_order' THEN
    v_payload := v_payload || jsonb_build_object('order_no', NEW.order_no);
  ELSIF TG_TABLE_NAME = 'booking' THEN
    v_payload := v_payload || jsonb_build_object('booking_no', NEW.booking_no, 'order_id', NEW.order_id);
  ELSIF TG_TABLE_NAME = 'voucher' THEN
    v_payload := v_payload || jsonb_build_object('voucher_no', NEW.voucher_no, 'order_id', NEW.order_id);
  END IF;

  INSERT INTO event_outbox (aggregate_type, aggregate_id, event_type, payload)
  VALUES (v_agg, NEW.id, v_event, v_payload);

  RETURN NULL;
END;
$$;

-- 四张交易表各挂两个触发器：守卫（UPDATE）+ 事件（INSERT / UPDATE）
CREATE TRIGGER trg_order_status_guard BEFORE UPDATE ON sales_order
    FOR EACH ROW EXECUTE FUNCTION fn_guard_state_transition();
CREATE TRIGGER trg_order_status_event AFTER INSERT ON sales_order
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();
CREATE TRIGGER trg_order_status_event_upd AFTER UPDATE ON sales_order
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();

CREATE TRIGGER trg_order_item_status_guard BEFORE UPDATE ON sales_order_item
    FOR EACH ROW EXECUTE FUNCTION fn_guard_state_transition();
CREATE TRIGGER trg_order_item_status_event AFTER INSERT ON sales_order_item
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();
CREATE TRIGGER trg_order_item_status_event_upd AFTER UPDATE ON sales_order_item
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();

CREATE TRIGGER trg_booking_status_guard BEFORE UPDATE ON booking
    FOR EACH ROW EXECUTE FUNCTION fn_guard_state_transition();
CREATE TRIGGER trg_booking_status_event AFTER INSERT ON booking
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();
CREATE TRIGGER trg_booking_status_event_upd AFTER UPDATE ON booking
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();

CREATE TRIGGER trg_voucher_status_guard BEFORE UPDATE ON voucher
    FOR EACH ROW EXECUTE FUNCTION fn_guard_state_transition();
CREATE TRIGGER trg_voucher_status_event AFTER INSERT ON voucher
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();
CREATE TRIGGER trg_voucher_status_event_upd AFTER UPDATE ON voucher
    FOR EACH ROW EXECUTE FUNCTION fn_emit_state_event();

-- -------------------------------------------------------------------------------------
-- ⑤ 交易侧不变量
--
-- v_invariant_checks 拆成两半：供给/定价/展示侧（原有 45 条，原样保留）与
-- 交易侧（这里）。用 ALTER VIEW ... RENAME 把原视图改名后重建总视图，
-- 避免把 45 条不变量抄一遍 —— 抄一遍就会分叉，分叉的门禁等于没有门禁。
-- -------------------------------------------------------------------------------------
ALTER VIEW v_invariant_checks RENAME TO v_invariant_checks_core;

COMMENT ON VIEW v_invariant_checks_core IS '供给/定价/展示侧 45 条业务不变量自检';

CREATE VIEW v_invariant_checks_tx AS
WITH RECURSIVE
edges (aggregate_type, from_status, to_status) AS (
    SELECT aggregate_type, from_status, to_status FROM state_transition
),
-- 从初始状态出发能到达的状态全集。UNION 去重，所以状态图里有环也不会死循环。
reach (aggregate_type, status) AS (
    SELECT e.aggregate_type, e.to_status
      FROM edges e
     WHERE e.from_status = ''
    UNION
    SELECT e.aggregate_type, e.to_status
      FROM reach r
      JOIN edges e ON e.aggregate_type = r.aggregate_type
                 AND e.from_status  = r.status
),
raw (seq, check_name, actual) AS (
    -- 46-49：状态可达。凭空出现的状态（例如直接 UPDATE 出来的 fulfilled）没有来路。
    SELECT 46, '订单状态必须可从初始状态沿合法边到达',
           (SELECT count(*) FROM sales_order o
             WHERE NOT EXISTS (SELECT 1 FROM reach
                                WHERE reach.aggregate_type = 'order' AND reach.status = o.status))
    UNION ALL
    SELECT 47, '订单明细状态必须可从初始状态沿合法边到达',
           (SELECT count(*) FROM sales_order_item oi
             WHERE NOT EXISTS (SELECT 1 FROM reach
                                WHERE reach.aggregate_type = 'order_item' AND reach.status = oi.status))
    UNION ALL
    SELECT 48, '预订状态必须可从初始状态沿合法边到达',
           (SELECT count(*) FROM booking b
             WHERE NOT EXISTS (SELECT 1 FROM reach
                                WHERE reach.aggregate_type = 'booking' AND reach.status = b.status))
    UNION ALL
    SELECT 49, '凭证状态必须可从初始状态沿合法边到达',
           (SELECT count(*) FROM voucher v
             WHERE NOT EXISTS (SELECT 1 FROM reach
                                WHERE reach.aggregate_type = 'voucher' AND reach.status = v.status))
    UNION ALL
    -- 50：订单不能凭空确认 —— 已确认的订单必须有对应状态的预订。
    SELECT 50, '已确认订单必须有 confirmed/ticketed 的预订',
           (SELECT count(*) FROM sales_order o
             WHERE o.status IN ('confirmed','partially_fulfilled','fulfilled')
               AND NOT EXISTS (SELECT 1 FROM booking b
                                WHERE b.order_id = o.id
                                  AND b.status IN ('confirmed','ticketed')))
    UNION ALL
    -- 51：凭证必须挂在真的预订上。
    SELECT 51, '已出票凭证必须挂在 confirmed/ticketed 的预订上',
           (SELECT count(*) FROM voucher v
             WHERE v.status IN ('issued','used')
               AND NOT EXISTS (SELECT 1 FROM booking b
                                WHERE b.id = v.booking_id
                                  AND b.status IN ('confirmed','ticketed')))
    UNION ALL
    -- 52：订单状态与履约状态不打架。
    SELECT 52, '订单状态与履约状态必须一致',
           (SELECT count(*) FROM sales_order o
             WHERE (o.status = 'fulfilled' AND o.fulfillment_status <> 'fulfilled')
                OR (o.status IN ('cancelled','failed','refunded') AND o.fulfillment_status = 'fulfilled'))
    UNION ALL
    -- 53：金额对得上 —— 订单小计 = 明细合计。
    --     注意比的是 subtotal 不是 total：优惠券是在订单层减的（total = subtotal - discount + tax，
    --     那条已由不变量 4 把守）。拿 total 去比明细合计，用了券的订单会被误判成违规。
    SELECT 53, '订单小计必须等于明细合计',
           (SELECT count(*) FROM sales_order o
             WHERE EXISTS (SELECT 1 FROM sales_order_item oi WHERE oi.order_id = o.id)
               AND o.subtotal <> (SELECT sum(oi.total_price) FROM sales_order_item oi WHERE oi.order_id = o.id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_tx IS '交易侧 8 条业务不变量自检（46-53）：状态可达性与订单/预订/凭证的一致性';

CREATE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx;

COMMENT ON VIEW v_invariant_checks IS '全部 53 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
