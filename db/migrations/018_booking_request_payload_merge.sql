-- =====================================================================================
-- 018 · 预订请求报文改成「合并」，不再「覆盖」
--
-- 问题：
--   fn_create_bookings() 往 booking.request_payload 写的是**我们打算发出去的请求**
--   （order_no / quantity / components / snapshot），
--   fn_request_booking(p_request) 往同一列写的是**接入层实际发出去的那一份**。
--   原来的写法是覆盖：`request_payload = COALESCE(p_request, request_payload)`。
--   p_request 的默认值是 '{}'::jsonb 而不是 NULL，所以「不传报文」也会把整列洗掉。
--
--   后果不是「少几个字段」那么轻：
--   套装（017）那条链路上，request_payload 里的 quantity 是**套数**、
--   admission_quantity 是**入场份数**，两者不同 —— 一次预订买 1 套、发 3 张入场名额。
--   这份报文被洗掉之后，「预订的单位是套还是份」这件事在库里就没处可查了，
--   对账时只能靠猜。事实不许因为一次调用就没了。
--
-- 改法：
--   改成合并（jsonb 的 || 是顶层键覆盖），我们写的事实留着，
--   接入层这次发出去的报文盖在上面。
--   同名键以接入层这次发的为准 —— 它是这次请求的真实内容。
--
-- 为什么单开一个迁移：
--   005 是已发布的迁移，账本里记着它的校验和，改它就是内容漂移，引擎会拒绝跑。
--   DDL 只增不改 —— 要改行为就新增一个迁移。
--
-- 不变量：这次改动不新增不变量，但 §5.6 的口径变了，SPEC.md 同步更新。
--   校验方式：套装订单走完 fn_request_booking 之后，
--   request_payload->>'quantity' 仍然是套数，->>'admission_quantity' 仍然是入场份数。
-- =====================================================================================

CREATE OR REPLACE FUNCTION fn_request_booking(p_booking_id BIGINT, p_request JSONB DEFAULT '{}'::jsonb)
RETURNS TABLE (
    booking_id  BIGINT,
    booking_no  TEXT,
    attempt_no  INT,
    status      TEXT
)
LANGUAGE plpgsql AS $$
DECLARE
    v_booking RECORD;
BEGIN
    SELECT b.id, b.booking_no, b.status, b.attempt_count INTO v_booking
      FROM booking b
     WHERE b.id = p_booking_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预订 % 不存在', p_booking_id;
    END IF;

    IF v_booking.status NOT IN ('pending', 'requested') THEN
        RAISE EXCEPTION '预订 % 当前状态 % 不能发起请求（只允许 pending / requested）',
          v_booking.booking_no, v_booking.status;
    END IF;

    IF v_booking.status = 'pending' THEN
        UPDATE booking
           SET status          = 'requested',
               attempt_count   = attempt_count + 1,
               request_payload = booking.request_payload || COALESCE(p_request, '{}'::jsonb),
               next_retry_at   = NULL
         WHERE id = v_booking.id;
    ELSE
        -- 重试：状态不动，尝试次数加一。
        UPDATE booking
           SET attempt_count   = attempt_count + 1,
               request_payload = booking.request_payload || COALESCE(p_request, '{}'::jsonb),
               next_retry_at   = NULL
         WHERE id = v_booking.id;
    END IF;

    booking_id := v_booking.id;
    booking_no := v_booking.booking_no;
    attempt_no := v_booking.attempt_count + 1;
    status     := 'requested';
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_request_booking IS
    '发起预订请求：pending → requested，attempt_count 递增（重试也走这里）。'
    'request_payload 合并而不是覆盖：我们写的事实（套数 / 入场份数 / 成分 / 快照）留着，'
    '接入层这次发出去的报文盖在上面';
