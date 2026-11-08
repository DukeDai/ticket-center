-- =====================================================================================
-- 009 库存预占与防超卖
--
-- 到这一步为止，票的整个生命周期（下单 → 履约 → 核销 → 退款）都通了，
-- 但有一件事是空的：**库存**。
--
-- 现在的下单（fn_place_order）只管钱：算价、落单、落明细。
-- 它不问「这个场次还剩几张票」。于是最后一张票可以被两个客户同时买走 ——
-- 超卖。票卖出去收不回来，多卖一张就是实打实的亏损 + 客诉 + 平台罚款。
--
-- 这一段的口径写死在这里：
--
--   1. **可售数只有一个实现**（fn_available_qty）：
--      源侧可售（票种级库存快照 → 场次级可用性缓存 → 不知道）
--      减去「我们多承诺出去的那部分」（源侧还没算进去的已售 + 还占着没兑现的预占）。
--   2. **不知道就不猜**：没有源侧数据时放行，但把「卖的时候不知道还剩多少」记进明细快照。
--      明知不够还卖 = 超卖，当场报错。
--   3. **并发靠锁**：按源场次加行锁（升序），两个并发订单不会各卖各的最后一张。
--   4. **预留是事实**：每条订单明细都有一条预占记录，量对得上；卖的时候看到的可售数
--      写进明细快照（硬约束 7），事后能复算。
--   5. **购物车预占有 TTL**：结算前占住，超时自动释放（fn_expire_holds）。
--   6. **订单关闭就把承诺放掉**：取消 / 超时未付 / 退款成功，预占都要释放
--      （fn_release_holds_for_order）。不放掉 = 票白白少卖一张。
--
-- 为什么不写进 004：004 已经在库里应用过了，改它等于内容漂移。
-- 「DDL 只增不改」这条规矩自己也得守 —— 所以 fn_place_order 在这里整体替换一次
-- （口径与 006 替换 fn_record_payment 是同一个套路）。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- ① 表结构补齐
--
-- supplier_session_id：预占占的是**源侧场次**的库存（源侧场次才是有库存数字的东西），
--                      规范场次只是我们对齐后的口径。
-- consumed_quantity：一张预占可以被吃掉一部分（购物车 3 张、订单 2 张），
--                    额度账要记得住已经兑现了多少。
--
-- 事实不许因为源数据被删就消失：所以是 SET NULL，不是 CASCADE。
-- -------------------------------------------------------------------------------------
ALTER TABLE inventory_hold
    ADD COLUMN supplier_session_id BIGINT REFERENCES supplier_session(id) ON DELETE SET NULL;

ALTER TABLE inventory_hold
    ADD COLUMN consumed_quantity INTEGER NOT NULL DEFAULT 0;

ALTER TABLE inventory_hold
    ADD COLUMN release_reason TEXT;

ALTER TABLE inventory_hold
    ADD CONSTRAINT inventory_hold_consumed_ck
    CHECK (consumed_quantity >= 0 AND consumed_quantity <= quantity);

-- voided：卖出去了，承诺又被撤销（订单取消 / 超时未付 / 退款成功）。
-- 和 released 分开是因为两件事不是一回事：
--   released = 还没卖就放掉了（购物车放弃）；
--   voided   = 卖过了又收回去了（退款），源侧那边也得退票。
-- 额度账上 consumed_quantity 都等于 quantity，区别在「这张票到底卖没卖过」。
ALTER TABLE inventory_hold
    DROP CONSTRAINT inventory_hold_status_check;

ALTER TABLE inventory_hold
    ADD CONSTRAINT inventory_hold_status_check
    CHECK (status IN ('active','consumed','released','expired','voided'));

CREATE INDEX ix_hold_supplier_session ON inventory_hold (supplier_session_id)
     WHERE status IN ('active','consumed');

COMMENT ON COLUMN inventory_hold.supplier_session_id IS '预占占的是哪个源侧场次的库存（源场次才有库存数字）';
COMMENT ON COLUMN inventory_hold.consumed_quantity IS '这张预占里已经兑现（被订单吃掉）的量';
COMMENT ON COLUMN inventory_hold.release_reason IS '预占为什么被释放/过期/作废（排查用）';

-- -------------------------------------------------------------------------------------
-- ② 可售数的唯一实现
--
-- 源侧可售从哪儿来：
--   1. inventory_snapshot（票种级，最新一条）—— 精确；
--   2. availability_cache（场次级，没过期才算数）—— 粗；
--   3. 都没有 —— 不知道。
--
-- 然后减去「我们已经多承诺出去的量」。这里有个坑，值得写清楚：
--
-- **不能直接把已卖出的量从源侧可售里减掉。**
-- 源侧的快照反映的是源侧自己的卖出情况 —— 我们通过它卖出去的那几张，
-- 源侧同步过来之后就已经从 available_qty 里扣掉了。这时候再减一遍就是重复扣，
-- 卖得越多扣得越多，最后系统会以为一张都卖不出去（卖到一半就停）。
--
-- 正确的减法是减「**源侧还没算进去的那部分**」：
--
--   多承诺量 = max(我们已兑现的量 − 源侧报的已售量, 0) + 还占着没兑现的预占量
--
-- 源侧同步一次，源侧的已售量追上来，多承诺量就自动回到 0 —— 口径自愈，不漂移。
-- 源侧还没同步的那一段（我们卖了但源侧不知道），多承诺量正好挡住超卖。
--
-- 缓存口径没有「已售」这一栏，所以我们卖出的量全部按「源侧还不知道」算 —— 保守，
-- 方向是对的：少卖可以再放开，多卖收不回来。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_available_qty(
    p_supplier_session_id BIGINT,
    p_ticket_type_id      BIGINT DEFAULT NULL
)
RETURNS TABLE (
    known         BOOLEAN,
    available_qty INTEGER,
    committed_qty INTEGER,
    remaining_qty INTEGER,
    sold_qty      INTEGER,
    held_qty      INTEGER,
    source_status TEXT,
    snapshot_at   TIMESTAMPTZ
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_avail    INTEGER;
    v_sold     INTEGER;
    v_status   TEXT;
    v_at       TIMESTAMPTZ;
    v_cnt      INTEGER;
    v_found    BOOLEAN := FALSE;
    v_our_sold INTEGER := 0;
    v_our_held INTEGER := 0;
    v_unref    INTEGER := 0;
BEGIN
    IF p_supplier_session_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::int, 0::int, 0::int, 0::int, 0::int,
                            NULL::text, NULL::timestamptz;
        RETURN;
    END IF;

    -- 精确优先：票种级库存快照。
    -- 一个源票种只取最新一条；一个规范票种可能对应好几个源票种（映射表），要加总。
    WITH latest AS (
        SELECT DISTINCT ON (i.supplier_ticket_type_id)
               i.supplier_ticket_type_id, i.available_qty, i.sold_qty, i.status, i.captured_at
          FROM inventory_snapshot i
         WHERE i.supplier_session_id = p_supplier_session_id
           AND i.supplier_ticket_type_id IS NOT NULL
         ORDER BY i.supplier_ticket_type_id, i.captured_at DESC, i.id DESC
    )
    SELECT count(*),
           COALESCE(sum(l.available_qty), 0),
           COALESCE(sum(l.sold_qty), 0),
           COALESCE((array_agg(l.status ORDER BY l.captured_at DESC))[1], ''),
           max(l.captured_at)
      INTO v_cnt, v_avail, v_sold, v_status, v_at
      FROM latest l
     WHERE p_ticket_type_id IS NULL
        OR EXISTS (SELECT 1
                     FROM ticket_type_mapping ttm
                    WHERE ttm.supplier_ticket_type_id = l.supplier_ticket_type_id
                      AND ttm.ticket_type_id = p_ticket_type_id);

    IF v_cnt > 0 THEN
        v_found := TRUE;
    END IF;

    -- 兜底：场次级快照（票种为空的那些行 = 整个场次的合计）
    IF NOT v_found THEN
        SELECT COALESCE(i.available_qty, 0), COALESCE(i.sold_qty, 0),
               i.status, i.captured_at
          INTO v_avail, v_sold, v_status, v_at
          FROM inventory_snapshot i
         WHERE i.supplier_session_id = p_supplier_session_id
           AND i.supplier_ticket_type_id IS NULL
         ORDER BY i.captured_at DESC, i.id DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
        END IF;
    END IF;

    -- 粗略兜底：场次级可用性缓存（过期的不算数）
    IF NOT v_found THEN
        SELECT COALESCE(ac.available_qty, 0), 0,
               COALESCE(ac.status, ''), ac.fetched_at
          INTO v_avail, v_sold, v_status, v_at
          FROM availability_cache ac
         WHERE ac.supplier_session_id = p_supplier_session_id
           AND ac.expires_at > now()
         ORDER BY ac.fetched_at DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
        END IF;
    END IF;

    -- 我们在这个源场次上的承诺：已兑现的（consumed）+ 还占着的（active）。
    -- voided / released / expired 都不再占库存 —— 承诺已经撤销了。
    SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
           COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
      INTO v_our_sold, v_our_held
      FROM inventory_hold h
     WHERE h.supplier_session_id = p_supplier_session_id
       AND (p_ticket_type_id IS NULL OR h.ticket_type_id = p_ticket_type_id);

    -- 源侧还没算进去的已售：源侧报了已售量就减掉它对不上的那部分，
    -- 源侧没报（缓存口径）就全算成「还不知道」。
    IF v_found AND v_sold IS NOT NULL THEN
        v_unref := GREATEST(v_our_sold - v_sold, 0);
    ELSE
        v_unref := v_our_sold;
    END IF;

    known         := v_found;
    available_qty := CASE WHEN v_found THEN v_avail END;
    committed_qty := v_unref + v_our_held;
    remaining_qty := CASE WHEN v_found THEN GREATEST(v_avail - v_unref - v_our_held, 0) END;
    sold_qty      := v_our_sold;
    held_qty      := v_our_held;
    source_status := CASE WHEN v_found THEN v_status END;
    snapshot_at   := CASE WHEN v_found THEN v_at END;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_available_qty(BIGINT, BIGINT)
    IS '可售数的唯一实现：源侧可售（票种级快照 → 场次级缓存 → 不知道）减去源侧还没算进去的已售与还占着的预占';

-- -------------------------------------------------------------------------------------
-- ③ 预留：加锁 + 算 + 拦
--
-- fn_reserve_qty 是「要卖几张」和「还剩几张」之间唯一的桥：
-- 它先锁源场次（两个并发订单抢最后一张时，一个等另一个算完），
-- 再算可售，明知不够就当场报错。
--
-- 「不知道」不拦：没有源侧数据时我们不知道还剩几张，硬拦等于把系统堵死。
-- 不知道就放行，但把「不知道」记下来（写进订单明细快照）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_reserve_qty(
    p_supplier_session_id BIGINT,
    p_ticket_type_id      BIGINT,
    p_quantity            INTEGER,
    p_label               TEXT DEFAULT ''
)
RETURNS TABLE (
    known         BOOLEAN,
    available_qty INTEGER,
    committed_qty INTEGER,
    remaining_qty INTEGER,
    sold_qty      INTEGER,
    held_qty      INTEGER,
    source_status TEXT,
    snapshot_at   TIMESTAMPTZ
)
LANGUAGE plpgsql AS $$
DECLARE
    v_avail RECORD;
BEGIN
    -- 锁源场次：不锁的话两个事务会同时看到「还剩 1 张」，然后各卖一张。
    IF p_supplier_session_id IS NOT NULL THEN
        PERFORM 1 FROM supplier_session ss
         WHERE ss.id = p_supplier_session_id
         FOR UPDATE;
    END IF;

    SELECT * INTO v_avail
      FROM fn_available_qty(p_supplier_session_id, p_ticket_type_id);

    -- 明知不够还卖 = 超卖，当场报错。
    IF v_avail.known AND v_avail.remaining_qty < p_quantity THEN
        RAISE EXCEPTION '库存不足%s：源场次 % 只剩 % 张，要 % 张（源侧状态 %）',
          CASE WHEN p_label = '' THEN '' ELSE '（' || p_label || '）' END,
          p_supplier_session_id, v_avail.remaining_qty, p_quantity, v_avail.source_status;
    END IF;

    RETURN QUERY SELECT v_avail.known, v_avail.available_qty, v_avail.committed_qty,
                        v_avail.remaining_qty, v_avail.sold_qty, v_avail.held_qty,
                        v_avail.source_status, v_avail.snapshot_at;
END;
$$;

COMMENT ON FUNCTION fn_reserve_qty(BIGINT, BIGINT, INTEGER, TEXT)
    IS '预留的唯一实现：锁源场次 → 算可售 → 明知不够当场报错';

-- -------------------------------------------------------------------------------------
-- ④ 购物车预占
--
-- 结算之前先占住（TTL 默认 15 分钟），购物车里的票就不会被别人先买走。
--
-- 幂等键是预占号（硬约束 8）：同一个预占号重放一次还是那张预占，
-- 同一个预占号配另一份内容报错（不能把两次不同的预占混成一张）。
--
-- 选源走 fn_price_variant —— 和下单同一套。预占和下单选出来的源不一样，
-- 就会出现「按 A 源的价格卖、按 B 源占库存」。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_hold_inventory(
    p_hold_no     TEXT,
    p_channel_id  BIGINT,
    p_variant_id  BIGINT,
    p_quantity    INTEGER,
    p_visit_date  DATE,
    p_cart_id     BIGINT DEFAULT NULL,
    p_ttl_seconds INTEGER DEFAULT 900
)
RETURNS TABLE (
    hold_id       BIGINT,
    hold_no       TEXT,
    known         BOOLEAN,
    available_qty INTEGER,
    committed_qty INTEGER,
    remaining_qty INTEGER,
    sold_qty      INTEGER,
    held_qty      INTEGER,
    source_status TEXT,
    created       BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_scope      TEXT;
    v_hash       TEXT;
    v_existing   RECORD;
    v_price      RECORD;
    v_price_row  RECORD;
    v_supplier_id BIGINT;
    v_sup_sess   BIGINT;
    v_avail      RECORD;
    v_hold_id    BIGINT;
BEGIN
    IF p_hold_no IS NULL OR btrim(p_hold_no) = '' THEN
        RAISE EXCEPTION '缺少预占号：预占必须幂等';
    END IF;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION '预占数量不合法：%', p_quantity;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM channel c WHERE c.id = p_channel_id AND c.status = 'active') THEN
        RAISE EXCEPTION '渠道 % 不存在或不是 active', p_channel_id;
    END IF;

    -- 幂等：抢键
    v_scope := 'hold:' || p_channel_id::text;
    v_hash  := md5(p_variant_id::text || '|' || p_quantity::text || '|' || p_visit_date::text
                   || '|' || COALESCE(p_cart_id::text, '') || '|' || p_ttl_seconds::text);

    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_hold_no, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        SELECT ir.request_hash, ir.response INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_hold_no;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔请求（预占 %）',
              p_hold_no, COALESCE(v_existing.response->>'hold_no', '?');
        END IF;

        SELECT h.id, h.hold_no INTO v_hold_id, p_hold_no
          FROM inventory_hold h
         WHERE h.hold_no = p_hold_no;

        IF v_hold_id IS NULL THEN
            RAISE EXCEPTION '预占 % 正在处理中，稍后重试', p_hold_no;
        END IF;

        SELECT * INTO v_avail
          FROM fn_available_qty(
                 (SELECT h.supplier_session_id FROM inventory_hold h WHERE h.id = v_hold_id),
                 (SELECT h.ticket_type_id FROM inventory_hold h WHERE h.id = v_hold_id));

        hold_id       := v_hold_id;
        hold_no       := p_hold_no;
        known         := v_avail.known;
        available_qty := v_avail.available_qty;
        committed_qty := v_avail.committed_qty;
        remaining_qty := v_avail.remaining_qty;
        sold_qty      := v_avail.sold_qty;
        held_qty      := v_avail.held_qty;
        source_status := v_avail.source_status;
        created       := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 选源：和下单走同一套（fn_price_variant 是选源 + 定价的唯一实现）
    SELECT * INTO v_price
      FROM fn_price_variant(p_variant_id, p_visit_date, p_channel_id, p_channel_id);

    IF NOT FOUND THEN
        RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算）',
          p_variant_id, p_visit_date;
    END IF;

    -- 规范场次与票种（从价格日历借 id，不借金额）
    SELECT pc.session_id, pc.ticket_type_id INTO v_price_row
      FROM price_calendar pc
     WHERE pc.product_variant_id = p_variant_id
       AND pc.date = p_visit_date
       AND pc.status = 'active'
       AND (pc.channel_id = p_channel_id OR pc.channel_id IS NULL)
     ORDER BY (pc.channel_id IS NOT NULL) DESC, pc.id DESC
     LIMIT 1;

    -- 场次是 NOT NULL 的：没有场次就没法预占（库存挂在场次上）
    IF v_price_row.session_id IS NULL THEN
        RAISE EXCEPTION '变体 % 在 % 没有场次，无法预占', p_variant_id, p_visit_date;
    END IF;

    -- 源侧场次：库存数字挂在源场次上
    SELECT pss.supplier_session_id INTO v_sup_sess
      FROM product_session_source pss
     WHERE pss.product_session_id IS NOT DISTINCT FROM v_price_row.session_id
       AND pss.supplier_product_id = v_price.supplier_product_id
     LIMIT 1;

    SELECT sp.supplier_id INTO v_supplier_id
      FROM supplier_product sp
     WHERE sp.id = v_price.supplier_product_id;

    -- 预留：锁 → 算 → 明知不够就报错
    SELECT * INTO v_avail
      FROM fn_reserve_qty(v_sup_sess, v_price_row.ticket_type_id, p_quantity,
                           '变体 ' || p_variant_id::text || ' ' || p_visit_date::text);

    INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                supplier_id, product_variant_id, supplier_session_id,
                                quantity, consumed_quantity, status, cart_id, expires_at)
    VALUES (p_hold_no, p_channel_id, v_price_row.session_id, v_price_row.ticket_type_id,
            v_supplier_id, p_variant_id, v_sup_sess,
            p_quantity, 0, 'active', p_cart_id,
            now() + make_interval(secs => p_ttl_seconds))
    RETURNING id INTO v_hold_id;

    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('hold_id', v_hold_id, 'hold_no', p_hold_no)
     WHERE scope = v_scope AND idempotency_key = p_hold_no;

    -- 预占已经落库，重新算一次：返回的是「这张预占占住之后」的数，
    -- 跟幂等重放时返回的口径一致。
    SELECT * INTO v_avail
      FROM fn_available_qty(v_sup_sess, v_price_row.ticket_type_id);

    hold_id       := v_hold_id;
    hold_no       := p_hold_no;
    known         := v_avail.known;
    available_qty := v_avail.available_qty;
    committed_qty := v_avail.committed_qty;
    remaining_qty := v_avail.remaining_qty;
    sold_qty      := v_avail.sold_qty;
    held_qty      := v_avail.held_qty;
    source_status := v_avail.source_status;
    created       := true;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_hold_inventory(TEXT, BIGINT, BIGINT, INTEGER, DATE, BIGINT, INTEGER)
    IS '购物车预占的唯一实现：预占号是幂等键，明知库存不够当场报错';

-- -------------------------------------------------------------------------------------
-- ⑤ 释放与过期
--
-- 释放是幂等的：已经释放过的再释放一次不报错（购物车清空、用户改数量、
-- 作业重跑都走这一条路）。
--
-- 过期是作业入口：购物车占着的票到了 TTL 就该放掉，
-- 不放掉就等于我们凭空少卖了一张票。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_release_hold(
    p_hold_no TEXT,
    p_reason  TEXT DEFAULT NULL
)
RETURNS TABLE (
    hold_id  BIGINT,
    hold_no  TEXT,
    status   TEXT,
    released BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_hold RECORD;
    v_did  BOOLEAN := FALSE;
BEGIN
    SELECT h.id, h.hold_no, h.status INTO v_hold
      FROM inventory_hold h
     WHERE h.hold_no = p_hold_no
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '预占 % 不存在', p_hold_no;
    END IF;

    IF v_hold.status = 'active' THEN
        UPDATE inventory_hold
           SET status         = 'released',
               released_at    = now(),
               release_reason = COALESCE(p_reason, 'released')
         WHERE id = v_hold.id;
        v_did := TRUE;
    END IF;

    SELECT h.status INTO v_hold.status FROM inventory_hold h WHERE h.id = v_hold.id;

    hold_id  := v_hold.id;
    hold_no  := v_hold.hold_no;
    status   := v_hold.status;
    -- released 说的是「这一次调用有没有真的放掉它」，不是「它现在是不是 released」。
    -- 重复释放不报错，也不该报告成又放了一次。
    released := v_did;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_release_hold(TEXT, TEXT)
    IS '释放预占的唯一实现：幂等，已释放的再释放不报错，也不重复报告释放';

CREATE FUNCTION fn_expire_holds(p_limit INTEGER DEFAULT 500)
RETURNS TABLE (
    expired_count INTEGER
)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    WITH due AS (
        SELECT h.id
          FROM inventory_hold h
         WHERE h.status = 'active'
           AND h.expires_at <= now()
         ORDER BY h.expires_at, h.id
         LIMIT GREATEST(p_limit, 1)
    ), upd AS (
        UPDATE inventory_hold h
           SET status         = 'expired',
               released_at    = now(),
               release_reason = 'ttl_expired'
          FROM due d
         WHERE h.id = d.id
        RETURNING h.id
    )
    SELECT count(*) INTO v_count FROM upd;

    expired_count := v_count;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_expire_holds(INTEGER)
    IS '预占 TTL 过期作业的唯一实现：把到期的活跃预占放掉（幂等，可反复跑）';

-- -------------------------------------------------------------------------------------
-- ⑥ 订单关闭 → 释放承诺
--
-- 订单被取消、超时未付、退款成功 —— 这三种情况下我们对源侧的承诺都没了，
-- 票要放回池子里。不放掉 = 我们凭空少卖一张票，而且永远少卖。
--
-- 为什么用触发器而不是改 fn_complete_refund：
--   - 007 已经应用过了，改它等于内容漂移；
--   - 而且「订单不成了 → 库存承诺要撤」这条规则本来就不该只挂在退款那一个入口上
--     （取消、超时是同一个后果）。
--
-- voided（卖出过又收回）而不是 released（没卖就放掉）：
-- 额度账上 consumed_quantity 仍然等于 quantity —— 票确实卖过，这是事实，
-- 不能因为退了钱就说没卖过。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_release_holds_for_order()
RETURNS TRIGGER AS $$
DECLARE
    v_reason TEXT;
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    v_reason := CASE NEW.status
                    WHEN 'cancelled' THEN 'order_cancelled'
                    WHEN 'expired'   THEN 'order_expired'
                    WHEN 'refunded'  THEN 'order_refunded'
                    ELSE NULL
                END;

    IF v_reason IS NULL THEN
        RETURN NEW;
    END IF;

    UPDATE inventory_hold h
       SET status         = 'voided',
           released_at    = now(),
           release_reason = v_reason
     WHERE h.order_id = NEW.id
       AND h.status IN ('active','consumed');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_release_holds_on_order_close
    AFTER UPDATE OF status ON sales_order
    FOR EACH ROW
    EXECUTE FUNCTION fn_release_holds_for_order();

COMMENT ON FUNCTION fn_release_holds_for_order()
    IS '订单取消/超时/退款成功时释放它的库存预占（触发器，不靠自觉）';

-- -------------------------------------------------------------------------------------
-- ⑦ 下单写路径（含库存校验）
--
-- fn_place_order 的整体替换。只有两处与 004 不同：
--   1. 落单前按源场次加锁并校验可售（§③b）；
--   2. 落明细时把当时看到的可售数写进明细快照，落明细后给每条明细写一条预占记录（§④c）。
--
-- 其余（幂等、定价唯一来源、快照、实名）逐字沿用 004 —— 口径不许在这里偷偷改。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_place_order(
    p_channel_id      BIGINT,
    p_idempotency_key TEXT,
    p_items           JSONB,
    p_customer_id     BIGINT DEFAULT NULL,
    p_contact         JSONB DEFAULT '{}'::jsonb,
    p_buyer_note      TEXT DEFAULT NULL,
    p_holders         JSONB DEFAULT '[]'::jsonb
)
RETURNS TABLE (
    order_id       BIGINT,
    order_no       TEXT,
    order_status   TEXT,
    order_currency TEXT,
    order_subtotal NUMERIC,
    order_total    NUMERIC,
    created        BOOLEAN
)
LANGUAGE plpgsql AS $$
DECLARE
    v_scope        TEXT;
    v_hash         TEXT;
    v_existing     RECORD;
    v_order        RECORD;
    v_item         JSONB;
    v_resolved     JSONB := '[]'::jsonb;   -- 解析好的明细，落库时再取
    v_items        JSONB := '[]'::jsonb;   -- 已落库的明细（带 order_item_id）
    v_pricing      JSONB := '[]'::jsonb;   -- 定价快照（订单级）
    v_line         JSONB;
    v_req          RECORD;
    v_holder       JSONB;
    v_item_id      BIGINT;
    v_holders      INT;
    v_variant      BIGINT;
    v_qty          INT;
    v_date         DATE;
    v_price        RECORD;
    v_price_row    RECORD;
    v_listing_id   BIGINT;
    v_supplier_id  BIGINT;
    v_basis        TEXT;
    v_unit_price   NUMERIC;
    v_unit_cost    NUMERIC;
    v_total_price  NUMERIC;
    v_snapshot     JSONB;
    v_currency     TEXT;
    v_subtotal     NUMERIC := 0;
    v_cost_total   NUMERIC := 0;
    v_order_id     BIGINT;
    v_order_no     TEXT;
    v_detail       JSONB;
    v_inserted     INT;
    -- 库存预占（009）：逐项的源侧场次与当时看到的可售数
    v_sessions     JSONB := '[]'::jsonb;
    v_avail        JSONB := '[]'::jsonb;
    v_session_ids  BIGINT[];
    v_sup_sess     BIGINT;
    v_ord          BIGINT;
    v_avail_row    RECORD;
    v_hold_id      BIGINT;
    v_hold_no      TEXT;
BEGIN
    -- ---------------------------------------------------------------------------------
    -- ① 参数与前置检查
    -- ---------------------------------------------------------------------------------
    IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
        RAISE EXCEPTION '缺少幂等键：下单必须幂等';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION '下单明细不能为空';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM channel c WHERE c.id = p_channel_id AND c.status = 'active') THEN
        RAISE EXCEPTION '渠道 % 不存在或不是 active', p_channel_id;
    END IF;

    IF p_customer_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM customer cu WHERE cu.id = p_customer_id) THEN
        RAISE EXCEPTION '客户 % 不存在', p_customer_id;
    END IF;

    v_scope := 'order:' || p_channel_id::text;
    v_hash  := md5(p_channel_id::text || '|' || p_items::text || '|'
                   || COALESCE(p_contact::text, '{}') || '|' || COALESCE(p_buyer_note, '')
                   || '|' || COALESCE(p_holders::text, '[]'));

    -- ---------------------------------------------------------------------------------
    -- ② 幂等：抢键
    --
    -- 抢键用 INSERT ... ON CONFLICT DO NOTHING，不用「先查后插」：
    -- 先查后插在并发下会双双通过检查，然后双双落单。
    -- ---------------------------------------------------------------------------------
    INSERT INTO idempotency_record (scope, idempotency_key, request_hash, status)
    VALUES (v_scope, p_idempotency_key, v_hash, 'in_progress')
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF NOT FOUND THEN
        -- 键已被占用：要么是同一笔请求（返回原单），要么是另一笔请求（拒绝）。
        SELECT ir.request_hash, ir.response, ir.status INTO v_existing
          FROM idempotency_record ir
         WHERE ir.scope = v_scope AND ir.idempotency_key = p_idempotency_key;

        IF v_existing.request_hash <> v_hash THEN
            RAISE EXCEPTION '幂等键 % 已用于另一笔请求（订单 %）',
              p_idempotency_key, COALESCE(v_existing.response->>'order_no', '?');
        END IF;

        SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
          FROM sales_order o
         WHERE o.id = NULLIF(v_existing.response->>'order_id', '')::bigint;

        IF NOT FOUND THEN
            RAISE EXCEPTION '幂等键 % 正在处理中，稍后重试', p_idempotency_key;
        END IF;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- 抢到键了，但库里可能已经有同键的订单（幂等记录被清过的情况）。
    SELECT o.id, o.order_no, o.status, o.currency, o.subtotal, o.total INTO v_order
      FROM sales_order o
     WHERE o.channel_id = p_channel_id
       AND o.idempotency_key = p_idempotency_key;

    IF FOUND THEN
        UPDATE idempotency_record
           SET status   = 'done',
               response = jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no)
         WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

        order_id       := v_order.id;
        order_no       := v_order.order_no;
        order_status   := v_order.status;
        order_currency := v_order.currency;
        order_subtotal := v_order.subtotal;
        order_total    := v_order.total;
        created        := false;
        RETURN NEXT;
        RETURN;
    END IF;

    -- ---------------------------------------------------------------------------------
    -- ③ 逐项解析：价格、采纳源、快照
    --
    -- 金额只从 fn_price_variant() 取（定价的唯一实现）。
    -- 采纳源也来自同一个函数 —— 定价选中的源就是路由选中的源（不变量 43）。
    -- ---------------------------------------------------------------------------------
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_variant := NULLIF(v_item->>'variant_id', '')::bigint;
        v_qty     := COALESCE(NULLIF(v_item->>'quantity', '')::int, 0);
        v_date    := NULLIF(v_item->>'visit_date', '')::date;

        IF v_variant IS NULL OR v_qty <= 0 OR v_date IS NULL THEN
            RAISE EXCEPTION '明细不完整（需要 variant_id / quantity / visit_date）：%', v_item::text;
        END IF;

        SELECT * INTO v_price
          FROM fn_price_variant(v_variant, v_date, p_channel_id, p_channel_id);

        IF NOT FOUND THEN
            RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算）',
              v_variant, v_date;
        END IF;

        v_basis := COALESCE(NULLIF(v_price.rule->>'mode', ''), 'cost_plus');

        IF v_basis = 'per_group' THEN
            -- 按团报价：总价是团总价，与人数不成正比；人均只是分摊（硬约束 5）。
            v_total_price := v_price.sell_price;
            v_unit_price  := round(v_price.sell_price / v_qty, 2);
            v_unit_cost   := round(v_price.cost_price / v_qty, 2);
            v_cost_total  := v_cost_total + v_price.cost_price;
        ELSE
            v_unit_price  := v_price.sell_price;
            v_total_price := round(v_price.sell_price * v_qty, 2);
            v_unit_cost   := v_price.cost_price;
            v_cost_total  := v_cost_total + round(v_price.cost_price * v_qty, 2);
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_price.currency;
        ELSIF v_currency <> v_price.currency THEN
            RAISE EXCEPTION '一单只能一个币种：% 与 % 混在一单里', v_currency, v_price.currency;
        END IF;

        v_subtotal := v_subtotal + v_total_price;

        -- 场次与票种 id 从价格行借（只借 id，不借金额：金额只认定价函数）。
        SELECT pc.session_id, pc.ticket_type_id INTO v_price_row
          FROM price_calendar pc
         WHERE pc.product_variant_id = v_variant
           AND pc.date = v_date
           AND pc.status = 'active'
           AND (pc.channel_id = p_channel_id OR pc.channel_id IS NULL)
         ORDER BY (pc.channel_id IS NOT NULL) DESC, pc.id DESC
         LIMIT 1;

        SELECT cl.id INTO v_listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.product_id = v_price.product_id
           AND cl.status = 'online'
         ORDER BY cl.id
         LIMIT 1;

        SELECT sp.supplier_id INTO v_supplier_id
          FROM supplier_product sp
         WHERE sp.id = v_price.supplier_product_id;

        v_snapshot := jsonb_build_object(
            'variant_id',           v_variant,
            'product_id',           v_price.product_id,
            'visit_date',           v_date,
            'quantity',             v_qty,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'unit_price',           v_unit_price,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'cost_price',           v_price.cost_price,
            'cost_source_product_id', v_price.supplier_product_id,
            'price_locked',         v_price.price_locked,
            'fx_rate',              v_price.fx_rate,
            'fx_as_of',             v_price.fx_as_of,
            'rule',                 v_price.rule)
            || CASE WHEN v_basis = 'per_group'
                    THEN jsonb_build_object('group_total', v_price.sell_price)
                    ELSE '{}'::jsonb END;

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'product_id',           v_price.product_id,
            'product_variant_id',   v_variant,
            'session_id',           v_price_row.session_id,
            'ticket_type_id',       v_price_row.ticket_type_id,
            'channel_listing_id',   v_listing_id,
            'supplier_product_id',  v_price.supplier_product_id,
            'supplier_id',          v_supplier_id,
            'quantity',             v_qty,
            'unit_price',           v_unit_price,
            'unit_cost',            v_unit_cost,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'snapshot',             v_snapshot));

        v_pricing := v_pricing || jsonb_build_array(v_snapshot);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ③b 库存预占：锁源场次 → 算可售 → 明知不够当场报错
    --
    -- 防超卖靠两件事：
    --   1. 锁：按源场次 id 升序加锁（SELECT ... ORDER BY id FOR UPDATE）。
    --      两个并发订单不会各卖各的最后一张；升序是为了不让两个订单互相死锁
    --      （A 锁 1 再锁 2、B 锁 2 再锁 1）。
    --   2. 扣：可售数要减去我们在这个场次上已经承诺出去的量（inventory_hold）。
    --
    -- 不知道就不猜：没有库存快照也没有可用性缓存时放行，
    -- 但把「卖的时候不知道还剩多少」写进明细快照（硬约束 7）。
    -- ---------------------------------------------------------------------------------
    FOR v_detail IN SELECT * FROM jsonb_array_elements(v_resolved)
    LOOP
        SELECT pss.supplier_session_id INTO v_sup_sess
          FROM product_session_source pss
         WHERE pss.product_session_id IS NOT DISTINCT FROM NULLIF(v_detail->>'session_id', '')::bigint
           AND pss.supplier_product_id = NULLIF(v_detail->>'supplier_product_id', '')::bigint
         LIMIT 1;

        v_sessions := v_sessions || jsonb_build_array(v_sup_sess);
    END LOOP;

    SELECT array_agg(s ORDER BY s) INTO v_session_ids
      FROM (SELECT DISTINCT (e.value)::bigint AS s
              FROM jsonb_array_elements(v_sessions) e) t
     WHERE s IS NOT NULL;

    IF v_session_ids IS NOT NULL THEN
        PERFORM 1 FROM supplier_session ss
         WHERE ss.id = ANY(v_session_ids)
         ORDER BY ss.id
         FOR UPDATE;
    END IF;

    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_sup_sess := (v_sessions -> ((v_ord - 1)::int))::bigint;

        SELECT * INTO v_avail_row
          FROM fn_reserve_qty(v_sup_sess,
                              NULLIF(v_detail->>'ticket_type_id', '')::bigint,
                              (v_detail->>'quantity')::int,
                              '变体 ' || COALESCE(v_detail->>'product_variant_id', '?')
                                || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));

        v_avail := v_avail || jsonb_build_array(jsonb_build_object(
            'known',         v_avail_row.known,
            'available_qty', v_avail_row.available_qty,
            'committed_qty', v_avail_row.committed_qty,
            'remaining_qty', v_avail_row.remaining_qty,
            'sold_qty',      v_avail_row.sold_qty,
            'held_qty',      v_avail_row.held_qty,
            'source_status', v_avail_row.source_status,
            'snapshot_at',   v_avail_row.snapshot_at));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④ 落单
    -- ---------------------------------------------------------------------------------
    v_order_no := 'TC' || to_char(now(), 'YYYYMMDD') || lpad(nextval('public.seq_order_no')::text, 6, '0');

    INSERT INTO sales_order (order_no, channel_id, customer_id, status, currency,
                             subtotal, discount, tax, total, cost_total, commission_amount,
                             pricing_snapshot, contact_snapshot, idempotency_key, buyer_note, expires_at)
    VALUES (v_order_no, p_channel_id, p_customer_id, 'created', v_currency,
            v_subtotal, 0, 0, v_subtotal, v_cost_total, 0,
            jsonb_build_object('items', v_pricing, 'channel_id', p_channel_id, 'computed_at', now()),
            COALESCE(p_contact, '{}'::jsonb), p_idempotency_key, p_buyer_note,
            now() + interval '30 minutes')
    RETURNING id INTO v_order_id;

    -- 明细：展示内容走快照，订单历史不依赖当前商品表（硬约束 7）。
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        INSERT INTO sales_order_item (order_id, product_id, product_variant_id, channel_listing_id,
                                      supplier_product_id, supplier_id, session_id, ticket_type_id,
                                      quantity, unit_price, unit_cost, total_price, currency,
                                      pricing_basis, detail_snapshot, status)
        VALUES (v_order_id,
                (v_detail->>'product_id')::bigint,
                (v_detail->>'product_variant_id')::bigint,
                NULLIF(v_detail->>'channel_listing_id', '')::bigint,
                NULLIF(v_detail->>'supplier_product_id', '')::bigint,
                NULLIF(v_detail->>'supplier_id', '')::bigint,
                NULLIF(v_detail->>'session_id', '')::bigint,
                NULLIF(v_detail->>'ticket_type_id', '')::bigint,
                (v_detail->>'quantity')::int,
                (v_detail->>'unit_price')::numeric,
                (v_detail->>'unit_cost')::numeric,
                (v_detail->>'total_price')::numeric,
                (v_detail->>'currency'),
                (v_detail->>'pricing_basis'),
                (v_detail->'snapshot') || jsonb_build_object(
                    'title', COALESCE(
                        (SELECT p.title FROM product p WHERE p.id = (v_detail->>'product_id')::bigint),
                        ''),
                    'availability', COALESCE(v_avail -> ((v_ord - 1)::int), '{}'::jsonb)),
                'pending')
        RETURNING id INTO v_item_id;

        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'order_item_id',  v_item_id,
            'variant_id',     (v_detail->>'product_variant_id')::bigint,
            'ticket_type_id', NULLIF(v_detail->>'ticket_type_id', '')::bigint,
            'quantity',       (v_detail->>'quantity')::int));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④c 库存预占落账
    --
    -- 每条明细都要有一条预占记录：「我们卖出去多少」是事实，必须查得到。
    --
    -- 有购物车预占就把它消费掉（同一张预占从 active 变 consumed，
    -- 承诺量不变，不会重复扣）；没有就新建一张 consumed 的。
    -- ---------------------------------------------------------------------------------
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_sup_sess := (v_sessions -> ((v_ord - 1)::int))::bigint;
        v_qty       := (v_detail->>'quantity')::int;

        IF NULLIF(v_detail->>'session_id', '') IS NULL THEN
            RAISE EXCEPTION '订单明细（变体 %）没有场次，无法预占库存',
              COALESCE(v_detail->>'product_variant_id', '?');
        END IF;

        SELECT h.id INTO v_hold_id
          FROM inventory_hold h
         WHERE h.status = 'active'
           AND h.channel_id = p_channel_id
           AND h.product_variant_id = NULLIF(v_detail->>'product_variant_id', '')::bigint
           AND h.product_session_id IS NOT DISTINCT FROM NULLIF(v_detail->>'session_id', '')::bigint
           AND h.supplier_session_id IS NOT DISTINCT FROM v_sup_sess
           AND h.quantity = v_qty
         ORDER BY h.created_at, h.id
         LIMIT 1
         FOR UPDATE;

        IF v_hold_id IS NOT NULL THEN
            UPDATE inventory_hold
               SET status            = 'consumed',
                   consumed_quantity = quantity,
                   order_id          = v_order_id,
                   released_at       = NULL
             WHERE id = v_hold_id;
        ELSE
            v_hold_no := 'HOLD' || v_order_no || '-' || lpad(v_ord::text, 2, '0');

            INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                        supplier_id, product_variant_id, supplier_session_id,
                                        quantity, consumed_quantity, status, order_id,
                                        expires_at, created_at)
            VALUES (v_hold_no, p_channel_id,
                    NULLIF(v_detail->>'session_id', '')::bigint,
                    NULLIF(v_detail->>'ticket_type_id', '')::bigint,
                    NULLIF(v_detail->>'supplier_id', '')::bigint,
                    NULLIF(v_detail->>'product_variant_id', '')::bigint,
                    v_sup_sess,
                    v_qty, v_qty, 'consumed', v_order_id,
                    now() + interval '30 minutes', now())
            RETURNING id INTO v_hold_id;
        END IF;
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④b 实名：票种要求的持票人信息必须收齐
    --
    -- 结算页要哪些字段由 checkout_requirement 说（不变量 25 按同一口径把门）。
    -- 这里按下单明细逐项校验：份数够、字段够、长度与格式过得了。
    -- 校验口径与不变量 25 必须一致 —— 两处口径不一样，就会出现「函数放行、门禁拦下」。
    -- ---------------------------------------------------------------------------------
    FOR v_line IN SELECT * FROM jsonb_array_elements(v_items)
    LOOP
        FOR v_req IN
            SELECT cr.field_code, cr.label, cr.max_length, cr.pattern
              FROM checkout_requirement cr
              JOIN sales_order_item oi ON oi.id = (v_line->>'order_item_id')::bigint
             WHERE cr.required
               AND cr.product_id = oi.product_id
               AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = oi.ticket_type_id)
               AND (cr.channel_id IS NULL OR cr.channel_id = p_channel_id)
        LOOP
            SELECT count(DISTINCT (h->>'sequence')::int) INTO v_holders
              FROM jsonb_array_elements(p_holders) h
             WHERE (h->>'variant_id')::bigint = (v_line->>'variant_id')::bigint
               AND h->>'field_code' = v_req.field_code;

            IF v_holders < (v_line->>'quantity')::int THEN
                RAISE EXCEPTION '订单行（变体 %）要求实名信息：% 需要 % 份，实收 % 份',
                  (v_line->>'variant_id')::bigint, v_req.label,
                  (v_line->>'quantity')::int, v_holders;
            END IF;

            FOR v_holder IN
                SELECT h FROM jsonb_array_elements(p_holders) h
                 WHERE (h->>'variant_id')::bigint = (v_line->>'variant_id')::bigint
                   AND h->>'field_code' = v_req.field_code
            LOOP
                IF v_req.max_length IS NOT NULL
                   AND length(COALESCE(v_holder->>'value', '')) > v_req.max_length THEN
                    RAISE EXCEPTION '订单行（变体 %）的 % 超过长度上限 %',
                      (v_line->>'variant_id')::bigint, v_req.label, v_req.max_length;
                END IF;

                IF NULLIF(v_req.pattern, '') IS NOT NULL
                   AND (v_holder->>'value') !~ v_req.pattern THEN
                    RAISE EXCEPTION '订单行（变体 %）的 % 不符合格式要求',
                      (v_line->>'variant_id')::bigint, v_req.label;
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;

    -- 持票人落库（每个字段一行，与 checkout_requirement 的字段口径对齐）
    INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, sequence, field_code, value, value_hash)
    SELECT v_order_id,
           (it->>'order_item_id')::bigint,
           (it->>'ticket_type_id')::bigint,
           (h->>'sequence')::int,
           h->>'field_code',
           h->>'value',
           md5(COALESCE(h->>'value', ''))
      FROM jsonb_array_elements(v_items) it
      JOIN jsonb_array_elements(p_holders) h
        ON (h->>'variant_id')::bigint = (it->>'variant_id')::bigint;

    -- created → awaiting_payment（触发器会落一条 OrderAwaitingPayment 事件）
    UPDATE sales_order SET status = 'awaiting_payment' WHERE id = v_order_id;

    -- ---------------------------------------------------------------------------------
    -- ⑤ 幂等记账
    -- ---------------------------------------------------------------------------------
    UPDATE idempotency_record
       SET status   = 'done',
           response = jsonb_build_object('order_id', v_order_id, 'order_no', v_order_no)
     WHERE scope = v_scope AND idempotency_key = p_idempotency_key;

    order_id       := v_order_id;
    order_no       := v_order_no;
    order_status   := 'awaiting_payment';
    order_currency := v_currency;
    order_subtotal := v_subtotal;
    order_total    := v_subtotal;
    created        := true;
    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION fn_place_order IS
    '下单的唯一实现：金额取自 fn_price_variant，幂等必填，明细走快照，落单前按源场次加锁校验可售';

-- -------------------------------------------------------------------------------------
-- ⑧ 库存侧不变量（69-72）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_invariant_checks_inventory AS
WITH raw (seq, check_name, actual) AS (
    -- 69：每条订单明细都要有一条对应的库存预占（量对得上）——
    --     「我们卖出去多少」必须查得到，不然超卖和漏卖都查不出来。
    SELECT 69, '每条订单明细都必须有对应的库存预占',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE NOT EXISTS (
                   SELECT 1 FROM inventory_hold h
                    WHERE h.order_id = oi.order_id
                      AND h.product_session_id IS NOT DISTINCT FROM oi.session_id
                      AND h.ticket_type_id IS NOT DISTINCT FROM oi.ticket_type_id
                      AND h.supplier_id IS NOT DISTINCT FROM oi.supplier_id
                      AND h.quantity = oi.quantity))
    UNION ALL
    -- 70：预占与订单不许分叉 —— 预占指向的订单必须存在；
    --     状态是 consumed 的预占必须已经兑现完、并且挂在某个订单上。
    SELECT 70, '库存预占与订单的状态不许分叉',
           (SELECT count(*)
              FROM inventory_hold h
             WHERE (h.order_id IS NOT NULL
                    AND NOT EXISTS (SELECT 1 FROM sales_order o WHERE o.id = h.order_id))
                OR (h.status = 'consumed'
                    AND (h.consumed_quantity <> h.quantity OR h.order_id IS NULL))
                OR (h.status = 'active' AND h.consumed_quantity >= h.quantity))
    UNION ALL
    -- 71：预占的额度账自洽 —— 兑现量不能超过预占量；
    --     已兑现完的预占状态就该是 consumed；没卖过的不能是 voided。
    SELECT 71, '库存预占的额度账必须自洽',
           (SELECT count(*)
              FROM inventory_hold h
             WHERE h.consumed_quantity < 0
                OR h.consumed_quantity > h.quantity
                OR (h.status = 'consumed' AND h.consumed_quantity <> h.quantity)
                OR (h.status = 'voided' AND h.consumed_quantity <> h.quantity)
                OR (h.status IN ('released','expired') AND h.consumed_quantity >= h.quantity))
    UNION ALL
    -- 72：卖出去的量不得超过落单时看到的源侧可售数 ——
    --     不知道（没有源侧数据）时不拦，但「不知道」这件事本身记在明细快照里。
    SELECT 72, '订单卖出的量不得超过落单时看到的源侧可售数',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE COALESCE((oi.detail_snapshot->'availability'->>'known')::boolean, FALSE) IS TRUE
               AND COALESCE((oi.detail_snapshot->'availability'->>'remaining_qty')::int, 0) < oi.quantity)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_inventory IS '库存侧不变量（69-72）：预占与订单的一致性、额度账、以及卖出量与可售数的关系';

-- -------------------------------------------------------------------------------------
-- ⑨ 总视图：并集
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_invariant_checks AS
    SELECT * FROM v_invariant_checks_core
    UNION ALL
    SELECT * FROM v_invariant_checks_tx
    UNION ALL
    SELECT * FROM v_invariant_checks_order
    UNION ALL
    SELECT * FROM v_invariant_checks_fulfill
    UNION ALL
    SELECT * FROM v_invariant_checks_refund
    UNION ALL
    SELECT * FROM v_invariant_checks_redemption
    UNION ALL
    SELECT * FROM v_invariant_checks_inventory;

COMMENT ON VIEW v_invariant_checks IS '全部 72 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';
