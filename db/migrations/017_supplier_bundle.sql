-- =============================================================================
-- 017 源侧整套卖（异构融合方向 B 的第二种形状）
--
-- 013/014 的方向 B 是「一个可售单元由多个源 SKU 按数量组成」：
--   源侧把成分分开卖，我们按配方拼成一张套餐，价格是成分单价 × 份数。
--
-- 这一层接的是另一种供给形态：**源侧把整套当一个 SKU 卖**。
--   源侧只有一个 SKU（家庭套票），一个价，一次预订，一次扣库存（扣 1 套，不是 3 张），
--   一次出券（出 3 个名额）。
--
-- 为什么接不了（012 之前的困境）：
--   从 coverage 看不出一个源 SKU 是「一整套」还是「一张谁都能用的票」——
--   覆盖关系只回答「这个源 SKU 能不能顶这个可售单元」，不回答「它顶了几个名额」。
--   看不出来就不能猜：猜错了就是「收了三个人的钱，出了两张票」。
--
-- 这一层把三个单位分开记，各自只写一处：
--   售卖单位（set）：源侧卖的是几套 —— 定价、扣库存、下单、预订都按它。
--   成分单位（unit）：一套里几个成分（2 成人 + 1 儿童）—— 规范侧的声明。
--   入场份数（admission）：几个名额 —— 出券、实名按它。
--
-- 成本怎么摊：整套价按成分份数比例摊到各成分，最后一份吃掉余数，
--   合计精确等于整套成本（不变量 98 守着这件事）。
--
-- 供给形态只有一种：配方（多个源 SKU 按份数拼）与套装（一个源 SKU 整套卖）
--   不许同时有 —— 守卫当场挡住（不变量 95）。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ① 声明：套装头 + 套装成分
--
-- 套装头 = 「这个组合由这个源 SKU 整套兑现」。
-- 套装成分 = 「一套里各占几个名额」，必须与规范声明（product_variant_relation）
--   逐项对得上（不变量 96，守卫当场挡住写错的行）。
-- -----------------------------------------------------------------------------
CREATE TABLE supplier_variant_bundle (
    id                   BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_variant_id   BIGINT       NOT NULL REFERENCES product_variant(id)  ON DELETE CASCADE,
    supplier_variant_id  BIGINT       NOT NULL REFERENCES supplier_variant(id) ON DELETE CASCADE,
    valid_days           NUMERIC(8,2) NOT NULL DEFAULT 1 CHECK (valid_days > 0),
    status               TEXT         NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT svb_uk UNIQUE (product_variant_id, supplier_variant_id)
);

CREATE INDEX ix_svb_variant ON supplier_variant_bundle (product_variant_id, status);
CREATE INDEX ix_svb_source  ON supplier_variant_bundle (supplier_variant_id, status);

CREATE TABLE supplier_variant_bundle_part (
    id                   BIGINT       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bundle_id            BIGINT       NOT NULL REFERENCES supplier_variant_bundle(id) ON DELETE CASCADE,
    component_variant_id BIGINT       NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    quantity             NUMERIC(8,2) NOT NULL DEFAULT 1 CHECK (quantity > 0),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT svbp_uk UNIQUE (bundle_id, component_variant_id)
);

CREATE INDEX ix_svbp_bundle    ON supplier_variant_bundle_part (bundle_id);
CREATE INDEX ix_svbp_component ON supplier_variant_bundle_part (component_variant_id);

-- -----------------------------------------------------------------------------
-- ② 守卫：形态唯一、套装只挂组合、成分必须与声明对得上
-- -----------------------------------------------------------------------------

-- 形态唯一：配方与套装不许同时挂在同一个组合上。
--
-- 两种形态的供给路径完全不同（配方是多个源 SKU 的加总，套装是一个源 SKU 的整价）。
-- 同时挂上，定价函数不知道该按哪条路算 —— 算错了就是「按 A 源的价格卖、按 B 源出票」。
CREATE OR REPLACE FUNCTION fn_guard_bundle_exclusive()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_combo  BIGINT;
    v_recipe INT;
BEGIN
    IF TG_TABLE_NAME = 'supplier_variant_bundle' THEN
        v_combo := NEW.product_variant_id;
    ELSE
        SELECT product_variant_id INTO v_combo
          FROM supplier_variant_bundle
         WHERE id = NEW.bundle_id;
    END IF;

    IF v_combo IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) INTO v_recipe
      FROM supplier_variant_composition
     WHERE product_variant_id = v_combo
       AND status = 'active';

    IF v_recipe > 0 THEN
        RAISE EXCEPTION
            '组合 % 已经有配方了，不许再挂套装：供给形态只能有一种（要么多个源 SKU 按份数拼，要么源侧一个 SKU 整套卖）',
            v_combo;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_bundle_exclusive
    BEFORE INSERT OR UPDATE ON supplier_variant_bundle
    FOR EACH ROW EXECUTE FUNCTION fn_guard_bundle_exclusive();

CREATE TRIGGER trg_guard_bundle_part_exclusive
    BEFORE INSERT OR UPDATE ON supplier_variant_bundle_part
    FOR EACH ROW EXECUTE FUNCTION fn_guard_bundle_exclusive();

-- 配方侧也要挡：给一个已经有套装的组合加配方，同样是形态冲突。
CREATE OR REPLACE FUNCTION fn_guard_composition_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = NEW.product_variant_id;

    IF v_role IS DISTINCT FROM 'combo' THEN
        RAISE EXCEPTION
            '配方只能挂在 combo 变体上（变体 % 的 role 是 %）',
            NEW.product_variant_id, COALESCE(v_role, '不存在');
    END IF;

    IF EXISTS (SELECT 1
                 FROM supplier_variant_bundle svb
                WHERE svb.product_variant_id = NEW.product_variant_id
                  AND svb.status = 'active') THEN
        RAISE EXCEPTION
            '组合 % 已经有套装了，不许再挂配方：供给形态只能有一种',
            NEW.product_variant_id;
    END IF;

    RETURN NEW;
END;
$$;

-- 套装只许挂在组合上：普通变体的供给走覆盖映射（方向 A），不走套装。
CREATE OR REPLACE FUNCTION fn_guard_bundle_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_role TEXT;
BEGIN
    SELECT pv.variant_role INTO v_role
      FROM product_variant pv
     WHERE pv.id = NEW.product_variant_id;

    IF v_role IS DISTINCT FROM 'combo' THEN
        RAISE EXCEPTION
            '套装只能挂在 combo 变体上（变体 % 的 role 是 %）：套装是「一个可售单元由一个源 SKU 整套兑现」',
            NEW.product_variant_id, COALESCE(v_role, '不存在');
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_bundle_parent
    BEFORE INSERT OR UPDATE ON supplier_variant_bundle
    FOR EACH ROW EXECUTE FUNCTION fn_guard_bundle_parent();

-- 成分必须与规范声明逐项对得上：不多不少、份数一致。
--
-- 写错份数的后果是「收了三个人的钱，出了两张票」——
-- 所以当场报错，不等到对账才发现。
CREATE OR REPLACE FUNCTION fn_guard_bundle_part()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_combo    BIGINT;
    v_declared NUMERIC;
BEGIN
    SELECT product_variant_id INTO v_combo
      FROM supplier_variant_bundle
     WHERE id = NEW.bundle_id;

    IF v_combo IS NULL THEN
        RAISE EXCEPTION '套装成分行 % 挂在一个不存在的套装上', NEW.id;
    END IF;

    SELECT r.quantity INTO v_declared
      FROM product_variant_relation r
     WHERE r.parent_variant_id = v_combo
       AND r.child_variant_id = NEW.component_variant_id
       AND r.relation_type = 'included';

    IF v_declared IS NULL THEN
        RAISE EXCEPTION
            '套装成分 % 不是组合 % 声明的成分（套装与规范声明必须逐项对得上）',
            NEW.component_variant_id, v_combo;
    END IF;

    IF v_declared <> NEW.quantity THEN
        RAISE EXCEPTION
            '套装成分 % 的份数 % 与组合 % 的声明 % 不一致（套装与规范声明必须逐项对得上）',
            NEW.component_variant_id, NEW.quantity, v_combo, v_declared;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_bundle_part
    BEFORE INSERT OR UPDATE ON supplier_variant_bundle_part
    FOR EACH ROW EXECUTE FUNCTION fn_guard_bundle_part();


-- -----------------------------------------------------------------------------
-- ③ 库存池：源侧的「套」票种
--
-- 套装在源侧的售卖单位是「套」，不是「人」。
-- 源侧报的库存也是套数（还剩 3 套家庭套票），按票种分开。
--
-- 现在的可售数口径只能按**规范票种**找池子（ticket_type_mapping 把规范票种
-- 映射到源票种）。套装没有单一规范票种 —— 它是一组人，不是一个人。
-- 所以这里给预占加一个「源票种」的口径：直接按源票种找池子，
-- 承诺也记在源票种上（inventory_hold.source_ticket_type_id）。
-- -----------------------------------------------------------------------------
ALTER TABLE inventory_hold
    ADD COLUMN source_ticket_type_id BIGINT REFERENCES supplier_ticket_type(id) ON DELETE RESTRICT;

CREATE INDEX ix_hold_source_ticket_type
    ON inventory_hold (source_ticket_type_id) WHERE source_ticket_type_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- ④ 可售数与预占：加「源票种」口径
--
-- 旧的两个参数还在（规范票种），新口径多一个「源票种」——
-- 套装走新口径，普通变体与配方组合走旧口径。
-- ---------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.fn_available_qty(p_supplier_session_id bigint, p_ticket_type_id bigint, p_source_ticket_type_id bigint)
 RETURNS TABLE(known boolean, available_qty integer, committed_qty integer, remaining_qty integer, sold_qty integer, held_qty integer, source_status text, snapshot_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_avail         INTEGER;
    v_sold          INTEGER;
    v_status        TEXT;
    v_at            TIMESTAMPTZ;
    v_cnt           INTEGER;
    v_found         BOOLEAN := FALSE;
    v_ticket_scoped BOOLEAN := FALSE;   -- 池子是票种级的（互不相干）还是场次级的（共享）
    v_our_sold      INTEGER := 0;
    v_our_held      INTEGER := 0;
    v_unref         INTEGER := 0;
BEGIN
    IF p_supplier_session_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::int, 0::int, 0::int, 0::int, 0::int,
                            NULL::text, NULL::timestamptz;
        RETURN;
    END IF;

    -- 精确优先：源票种级库存快照（017 新增）。
    --
    -- 套装的售卖单位是「套」：源侧报「还剩 3 套家庭套票」，
    -- 这个数不对应任何规范票种，只能直接按源票种找。
    -- 承诺也按源票种算：我们在这个源票种上欠了多少套。
    IF p_source_ticket_type_id IS NOT NULL THEN
        SELECT COALESCE(i.available_qty, 0), COALESCE(i.sold_qty, 0),
               i.status, i.captured_at
          INTO v_avail, v_sold, v_status, v_at
          FROM inventory_snapshot i
         WHERE i.supplier_session_id = p_supplier_session_id
           AND i.supplier_ticket_type_id = p_source_ticket_type_id
         ORDER BY i.captured_at DESC, i.id DESC
         LIMIT 1;

        IF FOUND THEN
            v_found := TRUE;
            v_ticket_scoped := TRUE;

            SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
                   COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
              INTO v_our_sold, v_our_held
              FROM inventory_hold h
             WHERE h.supplier_session_id = p_supplier_session_id
               AND h.source_ticket_type_id = p_source_ticket_type_id;
        END IF;
    END IF;

    -- 精确优先：票种级库存快照。
    -- 一个源票种只取最新一条；一个规范票种可能对应好几个源票种（映射表），要加总。
    IF NOT v_found THEN
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
            v_ticket_scoped := TRUE;
        END IF;
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

    -- 我们在这个池子上的承诺：已兑现的（consumed）+ 还占着的（active）。
    -- voided / released / expired 都不再占库存 —— 承诺已经撤销了。
    --
    -- 算到哪个范围，看这个池子是怎么来的：
    --   源票种级池子（套装）：这个源票种上的池子，与别的票种互不相干 → 只算本票种的承诺；
    --   票种级池子（v_ticket_scoped）：每个源票种各有一个池子，互不相干 → 只算本票种的承诺；
    --   场次级池子（整个场次一份）    ：所有票种共用 → 整个场次的承诺都要算。
    --
    -- 少了后一句，就是「每个票种都能把整场次的可用量再花一遍」——
    -- 卖 2 张成人再卖 2 张儿童，池子里明明只有 2 张。
    IF p_source_ticket_type_id IS NOT NULL AND v_found THEN
        NULL;   -- 上面已经算过了
    ELSIF p_ticket_type_id IS NULL OR v_ticket_scoped THEN
        SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
               COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
          INTO v_our_sold, v_our_held
          FROM inventory_hold h
         WHERE h.supplier_session_id = p_supplier_session_id
           AND (p_ticket_type_id IS NULL OR h.ticket_type_id = p_ticket_type_id);
    ELSE
        SELECT COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'consumed'), 0),
               COALESCE(sum(h.quantity) FILTER (WHERE h.status = 'active'), 0)
          INTO v_our_sold, v_our_held
          FROM inventory_hold h
         WHERE h.supplier_session_id = p_supplier_session_id;
    END IF;

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
$function$;

CREATE OR REPLACE FUNCTION public.fn_available_qty(p_supplier_session_id bigint, p_ticket_type_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(known boolean, available_qty integer, committed_qty integer, remaining_qty integer, sold_qty integer, held_qty integer, source_status text, snapshot_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    RETURN QUERY SELECT * FROM fn_available_qty(p_supplier_session_id, p_ticket_type_id, NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.fn_reserve_qty(p_supplier_session_id bigint, p_ticket_type_id bigint, p_source_ticket_type_id bigint, p_quantity integer, p_label text DEFAULT ''::text)
 RETURNS TABLE(known boolean, available_qty integer, committed_qty integer, remaining_qty integer, sold_qty integer, held_qty integer, source_status text, snapshot_at timestamp with time zone)
 LANGUAGE plpgsql
AS $function$
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
      FROM fn_available_qty(p_supplier_session_id, p_ticket_type_id, p_source_ticket_type_id);

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
$function$;

CREATE OR REPLACE FUNCTION public.fn_reserve_qty(p_supplier_session_id bigint, p_ticket_type_id bigint, p_quantity integer, p_label text DEFAULT ''::text)
 RETURNS TABLE(known boolean, available_qty integer, committed_qty integer, remaining_qty integer, sold_qty integer, held_qty integer, source_status text, snapshot_at timestamp with time zone)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY SELECT * FROM fn_reserve_qty(p_supplier_session_id, p_ticket_type_id, NULL,
                                              p_quantity, p_label);
END;
$function$;

-- -----------------------------------------------------------------------------
-- ⑤ 套装成分的唯一读法：fn_bundle_components
--
-- 读出来的是「一套里各占几个名额、这个成分分摊到多少成本」。
-- 成本分摊按成分份数比例摊，最后一个成分吃掉余数 ——
-- 合计精确等于整套成本（不变量 98）。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_bundle_components(p_variant_id bigint, p_date date, p_channel_id bigint, p_target_currency text)
 RETURNS TABLE(component_variant_id bigint, component_key text, component_ticket_type_id bigint, quantity numeric, supplier_variant_id bigint, supplier_product_id bigint, supplier_id bigint, source_ticket_type_id bigint, net_price numeric, source_currency text, fx_rate numeric, fx_as_of date, set_cost numeric, unit_cost numeric, product_session_id bigint, supplier_session_id bigint, source_min_margin numeric, is_price_locked boolean, bundle_valid_days numeric, covers_components boolean)
 LANGUAGE sql
 STABLE
AS $function$
    WITH bundle AS (
        SELECT svb.id, svb.product_variant_id, svb.supplier_variant_id, svb.valid_days
          FROM supplier_variant_bundle svb
         WHERE svb.product_variant_id = p_variant_id
           AND svb.status = 'active'
    ),
    parts AS (
        SELECT p.bundle_id, p.component_variant_id, p.quantity
          FROM supplier_variant_bundle_part p
          JOIN bundle b ON b.id = p.bundle_id
    ),
    listing AS (
        SELECT cl.id AS listing_id
          FROM channel_listing cl
         WHERE cl.channel_id = p_channel_id
           AND cl.status = 'online'
           AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
    ),
    head AS (
        SELECT b.id, b.product_variant_id, b.supplier_variant_id, b.valid_days,
               sv.supplier_product_id, sp.supplier_id, sv.is_price_locked,
               COALESCE(cls.min_margin, 0) AS source_min_margin,
               spc.net_price, spc.currency AS source_currency, spc.supplier_ticket_type_id,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8) END AS fx_rate,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date) END AS fx_as_of,
               CASE WHEN spc.net_price IS NULL THEN NULL
                    ELSE round(fn_convert(spc.net_price, spc.currency, p_target_currency, p_date), 2) END AS set_cost,
               ps.id AS product_session_id
          FROM bundle b
          JOIN supplier_variant sv ON sv.id = b.supplier_variant_id AND sv.status = 'active'
          JOIN supplier_product sp ON sp.id = sv.supplier_product_id
          -- 套装当天在这个源上的报价：源侧 SKU × 规范组合 × 日期
          LEFT JOIN LATERAL (
                SELECT s.net_price, s.currency, s.supplier_ticket_type_id
                  FROM supplier_price_calendar s
                 WHERE s.supplier_variant_id = b.supplier_variant_id
                   AND s.product_variant_id = b.product_variant_id
                   AND s.date = p_date
                   AND s.status = 'available'
                 ORDER BY s.id
                 LIMIT 1) spc ON true
          LEFT JOIN LATERAL (
                SELECT c2.min_margin
                  FROM channel_listing_source c2
                  JOIN listing l ON l.listing_id = c2.channel_listing_id
                 WHERE c2.supplier_product_id = sv.supplier_product_id
                   AND c2.enabled
                 ORDER BY c2.priority, c2.id
                 LIMIT 1) cls ON true
          -- 规范场次：按日期取这个商品当天的场次（不猜）
          LEFT JOIN LATERAL (
                SELECT p2.id
                  FROM product_session p2
                 WHERE p2.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = b.product_variant_id)
                   AND p2.session_date = p_date
                   AND p2.status = 'active'
                 ORDER BY p2.id
                 LIMIT 1) ps ON true
    ),
    located AS (
        SELECT h.*, pt.component_variant_id, pt.quantity AS part_qty,
               cv.variant_key AS component_key, cv.ticket_type_id AS component_ticket_type_id,
               SUM(pt.quantity) OVER () AS total_units
          FROM head h
          JOIN parts pt ON pt.bundle_id = h.id
          JOIN product_variant cv ON cv.id = pt.component_variant_id
    ),
    -- 分摊：按成分份数比例摊整套成本，余数归最后一个成分。
    -- 用「累计取整 − 上一段累计取整」而不是各自分摊再四舍五入：
    -- 后者会丢分或多分（不变量 98 守着这件事）。
    apportioned AS (
        SELECT l.*,
               CASE WHEN l.set_cost IS NULL OR l.total_units IS NULL OR l.total_units = 0 THEN NULL
                    ELSE round(l.set_cost * l.part_qty / l.total_units, 2) END AS rounded_part,
               row_number() OVER (ORDER BY l.component_variant_id) AS rn,
               count(*) OVER () AS cnt
          FROM located l
    ),
    cum AS (
        SELECT ap.*,
               COALESCE(sum(ap.rounded_part) OVER (
                   ORDER BY ap.component_variant_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS prev_cum
          FROM apportioned ap
    )
    SELECT c.component_variant_id,
           c.component_key,
           c.component_ticket_type_id,
           c.part_qty,
           c.supplier_variant_id,
           c.supplier_product_id,
           c.supplier_id,
           c.supplier_ticket_type_id AS source_ticket_type_id,
           c.net_price,
           c.source_currency,
           c.fx_rate,
           c.fx_as_of,
           c.set_cost,
           CASE WHEN c.set_cost IS NULL THEN NULL
                WHEN c.rn = c.cnt THEN round(c.set_cost - c.prev_cum, 2)
                ELSE c.rounded_part END AS unit_cost,
           c.product_session_id,
           fn_bound_supplier_session(c.product_session_id, c.supplier_product_id) AS supplier_session_id,
           c.source_min_margin,
           c.is_price_locked,
           c.valid_days,
           -- 源侧的整套有效期必须盖住规范侧承诺的窗口（成分窗口的并集）。
           -- 盖不住就是「我们承诺两天，源侧只认一天」——不许卖。
           c.valid_days >= fn_variant_validity_days(c.product_variant_id) AS covers_components
      FROM cum c
     ORDER BY c.component_variant_id;
$function$;

-- -----------------------------------------------------------------------------
-- ⑥ 定价：套装分支
--
-- 套装有单一采纳源（它就是一个源 SKU），所以成本可以追溯、汇率可以留痕 ——
-- 这与配方组合不同（配方的成分可能来自多个源商品，没有单一采纳源）。
-- ---------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.fn_price_variant(p_variant_id bigint, p_date date, p_context_channel_id bigint, p_price_channel_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(product_id bigint, product_variant_id bigint, date date, currency text, supplier_product_id bigint, source_currency text, net_price numeric, fx_rate numeric, fx_as_of date, cost_price numeric, sell_price numeric, list_price numeric, discount_pct numeric, price_locked boolean, min_margin numeric, rule jsonb)
 LANGUAGE sql
 STABLE
AS $function$
WITH ctx AS (
    SELECT cl.id AS listing_id,
           cl.product_id,
           cl.price_policy,
           COALESCE(NULLIF(cl.price_policy->>'mode', ''), 'cost_plus')                  AS mode,
           COALESCE(NULLIF(cl.price_policy->>'percent', '')::numeric, 0)                AS percent,
           NULLIF(cl.price_policy->>'floor', '')::numeric                               AS floor_price,
           COALESCE(NULLIF(cl.price_policy->>'list_markup_percent', '')::numeric, 0)    AS list_markup,
           COALESCE(NULLIF(cl.price_policy->>'min_margin', '')::numeric, 0)            AS listing_min_margin,
           fn_price_row_currency(p_price_channel_id)                                   AS target_currency
      FROM channel_listing cl
     WHERE cl.channel_id = p_context_channel_id
       AND cl.status = 'online'
       AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
),
cand AS (
    -- 候选与排序来自选源的唯一实现（fn_route_candidates）：
    -- 路由视图与定价函数必须选出同一个源，否则会「按 A 源的价格卖、按 B 源出票」。
    SELECT ctx.product_id,
           ctx.price_policy,
           ctx.target_currency,
           ctx.mode,
           ctx.percent,
           ctx.floor_price,
           ctx.list_markup,
           ctx.listing_min_margin,
           rc.supplier_product_id,
           rc.source_currency,
           rc.net_price,
           rc.supplier_price,
           rc.is_price_locked,
           rc.source_min_margin,
           rc.fx_rate_to_target   AS rate_to_target,
           rc.fx_as_of            AS snap_date,
           fn_convert(rc.net_price, rc.source_currency, ctx.target_currency, p_date) AS cost_in_target
      FROM ctx
      JOIN LATERAL fn_route_candidates(p_variant_id, p_date, p_context_channel_id,
                                       ctx.target_currency) rc
        ON rc.route_rank = 1
),
combo_parts AS (
    SELECT cc.*
      FROM ctx
      JOIN LATERAL fn_combo_components(p_variant_id, p_date, p_context_channel_id,
                                       ctx.target_currency) cc
        ON true
),
bundle_parts AS (
    SELECT bp.*
      FROM ctx
      JOIN LATERAL fn_bundle_components(p_variant_id, p_date, p_context_channel_id,
                                       ctx.target_currency) bp
        ON true
),
bundle AS (
    -- 套装：源侧一个 SKU 整套卖（方向 B 的第二种形状）。
    --
    -- 套装只有一个源，所以它有单一采纳源、单一源币种、单一汇率 ——
    -- 这些留痕不许空着：成本要能追溯到那个具体源（不变量 45）。
    -- 成本是整套的成本；成分是它的分摊（fn_bundle_components 摊好）。
    SELECT ctx.product_id,
           ctx.price_policy,
           ctx.target_currency,
           ctx.mode,
           ctx.percent,
           ctx.floor_price,
           ctx.list_markup,
           ctx.listing_min_margin,
           max(bp.set_cost)                       AS cost_in_target,
           max(bp.net_price)                      AS net_price,
           max(bp.source_currency)                AS source_currency,
           max(bp.fx_rate)                        AS rate_to_target,
           max(bp.fx_as_of)                       AS snap_date,
           max(bp.supplier_product_id)            AS supplier_product_id,
           max(bp.source_ticket_type_id)          AS source_ticket_type_id,
           max(bp.source_min_margin)              AS source_min_margin,
           bool_or(bp.is_price_locked)            AS any_locked,
           bool_and(bp.covers_components)         AS covers_components,
           count(*)                               AS n_parts,
           count(bp.set_cost)                     AS n_priced,
           count(DISTINCT bp.supplier_session_id) AS n_sessions,
           sum(bp.quantity)                       AS total_units,
           jsonb_agg(jsonb_build_object(
               'component_variant_id', bp.component_variant_id,
               'component_key',        bp.component_key,
               'quantity',             bp.quantity,
               'admission_quantity',   bp.quantity,
               'unit_cost',            bp.unit_cost,
               'cost',                 bp.unit_cost,
               'currency',             bp.source_currency,
               'fx_rate',              bp.fx_rate,
               'fx_as_of',             bp.fx_as_of
           ) ORDER BY bp.component_variant_id) AS breakdown
      FROM ctx
      JOIN bundle_parts bp ON true
     GROUP BY ctx.product_id, ctx.price_policy, ctx.target_currency, ctx.mode, ctx.percent,
              ctx.floor_price, ctx.list_markup, ctx.listing_min_margin
),
combo AS (
    -- 组合：一份套餐的成本 = Σ 成分单价 × 成分数量。
    SELECT ctx.product_id,
           ctx.price_policy,
           ctx.target_currency,
           ctx.mode,
           ctx.percent,
           ctx.floor_price,
           ctx.list_markup,
           ctx.listing_min_margin,
           sum(cc.unit_cost * cc.quantity)                AS cost_in_target,
           count(*)                                      AS n_parts,
           count(cc.unit_cost)                           AS n_priced,
           count(DISTINCT cc.product_session_id)         AS n_sessions,
           count(DISTINCT cc.supplier_id)                AS n_suppliers,
           count(*) FILTER (WHERE cc.is_price_locked)    AS n_locked,
           max(cc.source_min_margin)                     AS source_min_margin,
           jsonb_agg(jsonb_build_object(
               'component_variant_id', cc.component_variant_id,
               'component_key',        cc.component_key,
               'quantity',             cc.quantity,
               'supplier_variant_id',  cc.supplier_variant_id,
               'supplier_product_id',  cc.supplier_product_id,
               'net_price',            cc.net_price,
               'currency',             cc.source_currency,
               'fx_rate',              cc.fx_rate,
               'fx_as_of',             cc.fx_as_of,
               'unit_cost',            cc.unit_cost,
               'cost',                 round(cc.unit_cost * cc.quantity, 2),
               'price_locked',         cc.is_price_locked
           ) ORDER BY cc.component_variant_id) AS breakdown
      FROM ctx
      JOIN combo_parts cc ON true
     GROUP BY ctx.product_id, ctx.price_policy, ctx.target_currency, ctx.mode, ctx.percent,
              ctx.floor_price, ctx.list_markup, ctx.listing_min_margin
),
one AS (
    -- 普通变体：一个源 SKU 顶住这个可售单元（方向 A）。
    SELECT c.product_id,
           c.target_currency,
           c.supplier_product_id,
           c.source_currency,
           c.net_price,
           c.rate_to_target,
           c.snap_date,
           c.cost_in_target,
           c.supplier_price,
           c.is_price_locked,
           c.source_min_margin,
           c.mode,
           c.percent,
           c.floor_price,
           c.list_markup,
           c.listing_min_margin,
           c.price_policy,
           NULL::jsonb  AS breakdown,
           false        AS is_bundle
      FROM cand c
    UNION ALL
    -- 套装变体：源侧一个 SKU 整套卖（方向 B 的第二种形状）。
    --
    -- 拿不准一律不卖：当天没有套装报价、套装盖不住成分的窗口、锁价 → 这一行不存在。
    -- 锁价为什么也不卖：源方锁的价是「一个人的价」，套装的加价规则还没定 ——
    -- 宁可少卖，不可卖错。
    SELECT bd.product_id,
           bd.target_currency,
           bd.supplier_product_id,
           bd.source_currency,
           bd.net_price,
           bd.rate_to_target,
           bd.snap_date,
           bd.cost_in_target,
           NULL::numeric,   -- 套装没有单一「源方挂牌价」可借用
           false,           -- 不锁价
           bd.source_min_margin,
           bd.mode,
           bd.percent,
           bd.floor_price,
           bd.list_markup,
           bd.listing_min_margin,
           bd.price_policy,
           bd.breakdown,
           true
      FROM bundle bd
     WHERE bd.n_parts > 0
       AND bd.n_priced = bd.n_parts
       AND bd.total_units > 0
       AND bd.n_sessions = 1
       AND NOT bd.any_locked
       AND bd.covers_components
       -- 源侧的套装必须有自己的票种：源侧报「还剩 3 套」是按这个票种报的。
       -- 找不到它就算不出套装占了哪个池子 —— 不许猜，宁可不卖。
       AND bd.source_ticket_type_id IS NOT NULL
       AND bd.mode <> 'per_group'
    UNION ALL
    -- 组合变体：多个源 SKU 组成这个可售单元（方向 B）。
    -- 拿不准一律不卖：成分缺价、成分不同场次、跨源、成分锁价、按团报价 → 这一行不存在。
    --
    -- 成分锁价为什么也不卖：锁价是「源方定价，平台无权加价」。
    -- 组合是一整张套餐的价格，给它加价等于给那个被锁价的成分变相加价 ——
    -- 源方的锁价承诺是在成分上兑现的，挪到套餐上就没法兑现了。
    -- 宁可少卖，不可卖错。
    SELECT cb.product_id,
           cb.target_currency,
           NULL::bigint,   -- 没有单一采纳源商品（成分可能来自多个源商品）
           NULL::text,     -- 成分可能不同币种 → 没有单一源币种
           NULL::numeric,  -- 同理，没有单一源净价
           NULL::numeric,  -- 没有单一汇率（每个成分各自留痕）
           NULL::date,
           cb.cost_in_target,
           NULL::numeric,
           false,          -- 组合不锁价（锁价是单一源方挂牌价的概念）
           cb.source_min_margin,
           cb.mode,
           cb.percent,
           cb.floor_price,
           cb.list_markup,
           cb.listing_min_margin,
           cb.price_policy,
           cb.breakdown,
           false
      FROM combo cb
     WHERE cb.n_parts > 0
       AND cb.n_priced = cb.n_parts
       AND cb.n_sessions = 1
       AND cb.n_suppliers = 1
       AND cb.n_locked = 0
       AND cb.mode <> 'per_group'
),
calc AS (
    SELECT o.*,
           GREATEST(o.listing_min_margin, COALESCE(o.source_min_margin, 0)) AS effective_min_margin,
           (o.is_price_locked AND fn_bool_setting('price_locked_uses_source_list_price', true)) AS locked
      FROM one o
),
priced AS (
    SELECT c.*,
           CASE
             WHEN c.locked
               THEN round(fn_convert(c.supplier_price, c.source_currency, c.target_currency, p_date), 2)
             WHEN c.mode = 'per_group'
               THEN round(fn_convert(c.supplier_price, c.source_currency, c.target_currency, p_date), 2)
             ELSE round(GREATEST(
                    c.cost_in_target * (1 + c.percent / 100),
                    CASE WHEN c.effective_min_margin > 0 AND c.effective_min_margin < 1
                         THEN c.cost_in_target / (1 - c.effective_min_margin)
                         ELSE c.cost_in_target END,
                    COALESCE(c.floor_price, c.cost_in_target)
             ), 2)
           END AS sell_price
      FROM calc c
)
SELECT c.product_id,
       p_variant_id,
       p_date,
       c.target_currency,
       c.supplier_product_id,
       c.source_currency,
       c.net_price,
       c.rate_to_target,
       c.snap_date,
       round(c.cost_in_target, 2) AS cost_price,
       c.sell_price,
       -- 源方定价（锁价 / 按团报价）不虚构划线价；其余行按 list_markup_percent 上浮。
       CASE WHEN c.locked OR c.mode = 'per_group'
            THEN c.sell_price
            ELSE round(c.sell_price * (1 + c.list_markup / 100), 2)
       END AS list_price,
       CASE WHEN c.locked OR c.mode = 'per_group' OR c.sell_price = 0
            THEN 0::numeric
            ELSE round(((round(c.sell_price * (1 + c.list_markup / 100), 2) - c.sell_price)
                        / round(c.sell_price * (1 + c.list_markup / 100), 2)) * 100, 2)
       END AS discount_pct,
       c.locked AS price_locked,
       c.effective_min_margin AS min_margin,
       CASE WHEN c.breakdown IS NULL
            THEN c.price_policy
            ELSE c.price_policy || jsonb_build_object('combo', c.breakdown)
                 || CASE WHEN c.is_bundle
                         THEN jsonb_build_object('bundle', true)
                         ELSE '{}'::jsonb END
       END AS rule
  FROM priced c;
$function$;

-- -----------------------------------------------------------------------------
-- ⑦ 下单：套装分支
--
-- 套装的成分行照样落 sales_order_item_source（出券与实名靠它），
-- 但「售卖单位」是套、「入场份数」是人，两件事分开记。
-- ---------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.fn_place_order(p_channel_id bigint, p_idempotency_key text, p_items jsonb, p_customer_id bigint DEFAULT NULL::bigint, p_contact jsonb DEFAULT '{}'::jsonb, p_buyer_note text DEFAULT NULL::text, p_holders jsonb DEFAULT '[]'::jsonb)
 RETURNS TABLE(order_id bigint, order_no text, order_status text, order_currency text, order_subtotal numeric, order_total numeric, created boolean)
 LANGUAGE plpgsql
AS $function$
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
    v_new_sources  JSONB := '[]'::jsonb;
    v_line_rec     RECORD;
    v_avail        JSONB := '[]'::jsonb;
    v_avail_items  JSONB := '[]'::jsonb;   -- 每条明细一份可售数快照（013）
    v_session_ids  BIGINT[];
    v_sup_sess     BIGINT;
    v_demand       INT;
    v_ord          BIGINT;
    v_src_ord      BIGINT;
    v_avail_row    RECORD;
    v_hold_id      BIGINT;
    v_hold_no      TEXT;
    -- 组合（013）：明细的成分行
    v_role         TEXT;
    -- 套装（017）：源侧一个 SKU 整套卖
    v_is_bundle    BOOLEAN := FALSE;
    v_stt          BIGINT;   -- 套装的源票种（源侧那个「套」的票种）
    v_sets         INT;      -- 套数（售卖单位）
    v_comp         RECORD;
    v_sources      JSONB := '[]'::jsonb;
    v_src          JSONB;
    v_sv           BIGINT;
    v_session_id   BIGINT;
    v_ticket_type  BIGINT;
    v_need         INT;
    v_adm          INT;
    v_item_index   INT;
    -- 实名匹配：holder 里的 variant_id 指向成分变体；
    -- item_index 指向明细（同一个变体在一单里出现两次时靠它区分）。
    v_strict_item BOOLEAN;
    v_ambiguous   TEXT;
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

    -- 实名里带 item_index 的，按明细严格匹配；否则退回「按 variant_id 匹配」。
    v_strict_item := EXISTS (SELECT 1 FROM jsonb_array_elements(p_holders) h WHERE h ? 'item_index');

    -- ---------------------------------------------------------------------------------
    -- ③ 逐项解析：价格、采纳源、成分行、快照
    --
    -- 金额只从 fn_price_variant() 取（定价的唯一实现）。
    -- 采纳源也来自同一个函数 —— 定价选中的源就是路由选中的源（不变量 43）。
    -- ---------------------------------------------------------------------------------
    FOR v_item, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        -- 行号从 1 开始：调用方传过来的实名 item_index 用的是同一套口径。
        -- （0 起会让「第几行」和「第几名持票人」两套编号混在一起，
        --   差一位就把甲的实名绑到乙的票上。）
        v_item_index := v_ord::int;

        v_variant := NULLIF(v_item->>'variant_id', '')::bigint;
        v_qty     := COALESCE(NULLIF(v_item->>'quantity', '')::int, 0);
        v_date    := NULLIF(v_item->>'visit_date', '')::date;

        IF v_variant IS NULL OR v_qty <= 0 OR v_date IS NULL THEN
            RAISE EXCEPTION '明细不完整（需要 variant_id / quantity / visit_date）：%', v_item::text;
        END IF;

        SELECT * INTO v_price
          FROM fn_price_variant(v_variant, v_date, p_channel_id, p_channel_id);

        IF NOT FOUND THEN
            RAISE EXCEPTION '变体 % 在 % 没有可售价格（商品未上架 / 当天无可用报价 / 成本无法折算 / 组合套餐当天配不齐）',
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

        -- ---------------------------------------------------------------------------------
        -- ③a 成分行：这个明细要用哪些源 SKU、各几份
        --
        -- 普通变体 = 一行（明细自己的变体 + 定价选中的源 SKU）；
        -- 组合变体 = 每个成分一行（配方说了算）。
        -- ---------------------------------------------------------------------------------
        SELECT pv.variant_role INTO v_role
          FROM product_variant pv
         WHERE pv.id = v_variant;

        v_sources := '[]'::jsonb;

        IF v_role = 'combo' THEN
            -- 套装优先（017）：源侧一个 SKU 整套卖。
            -- 配方与套装不许同时有（守卫），所以这里只需要问「有没有套装」。
            IF EXISTS (SELECT 1
                         FROM supplier_variant_bundle svb
                        WHERE svb.product_variant_id = v_variant
                          AND svb.status = 'active') THEN
                v_is_bundle := TRUE;

                FOR v_comp IN
                    SELECT * FROM fn_bundle_components(v_variant, v_date, p_channel_id, v_price.currency)
                LOOP
                    v_sources := v_sources || jsonb_build_array(jsonb_build_object(
                        'component_variant_id',  v_comp.component_variant_id,
                        'supplier_variant_id',   v_comp.supplier_variant_id,
                        'supplier_product_id',   v_comp.supplier_product_id,
                        'supplier_id',           v_comp.supplier_id,
                        'product_session_id',    v_comp.product_session_id,
                        'supplier_session_id',   v_comp.supplier_session_id,
                        'source_ticket_type_id', v_comp.source_ticket_type_id,
                        'ticket_type_id',        v_comp.component_ticket_type_id,
                        -- 售卖单位是「套」：源侧卖的是整套，不是逐张。
                        'quantity',              v_qty,
                        -- 入场份数是「人」：一套里几个名额。
                        'admission_quantity',    (v_comp.quantity * v_qty)::int,
                        -- 每套分摊到这个成分上的成本。
                        'unit_cost',             v_comp.unit_cost,
                        'currency',              v_comp.source_currency,
                        'fx_rate',               v_comp.fx_rate,
                        'fx_as_of',              v_comp.fx_as_of,
                        'is_bundle',             true,
                        'bundle_sets',           v_qty));
                END LOOP;

                IF jsonb_array_length(v_sources) = 0 THEN
                    RAISE EXCEPTION '套装 % 在 % 没有可售的套装价（源侧当天没有这个套装的报价）',
                      v_variant, v_date;
                END IF;

                -- 套装的场次 = 规范场次（一次入园一个场次）
                v_session_id   := (v_sources -> 0 ->> 'product_session_id')::bigint;
                v_ticket_type  := NULL;   -- 套装没有单一票种（它是一组人）
                v_supplier_id  := (v_sources -> 0 ->> 'supplier_id')::bigint;
            ELSE
            FOR v_comp IN
                SELECT * FROM fn_combo_components(v_variant, v_date, p_channel_id, v_price.currency)
            LOOP
                v_sources := v_sources || jsonb_build_array(jsonb_build_object(
                    'component_variant_id', v_comp.component_variant_id,
                    'supplier_variant_id',  v_comp.supplier_variant_id,
                    'supplier_product_id',  v_comp.supplier_product_id,
                    'supplier_id',          v_comp.supplier_id,
                    'product_session_id',   v_comp.product_session_id,
                    'supplier_session_id',  v_comp.supplier_session_id,
                    'ticket_type_id',       v_comp.component_ticket_type_id,
                    'quantity',             (v_comp.quantity * v_qty)::int,
                    'admission_quantity',   (v_comp.quantity * v_qty)::int,
                    'unit_cost',            v_comp.unit_cost,
                    'currency',             v_comp.source_currency,
                    'fx_rate',              v_comp.fx_rate,
                    'fx_as_of',             v_comp.fx_as_of));
            END LOOP;

            IF jsonb_array_length(v_sources) = 0 THEN
                RAISE EXCEPTION '组合套餐 % 在 % 没有可售的成分配方（成分当天没报价 / 成分不同场次 / 跨源 / 按团报价口径未定）',
                  v_variant, v_date;
            END IF;

            -- 组合的场次 = 成分的场次（一次入园一个场次；定价函数已判定成分同场次）
            v_session_id   := (v_sources -> 0 ->> 'product_session_id')::bigint;
            v_ticket_type  := NULL;   -- 组合没有单一票种（成人 + 儿童）
            v_supplier_id  := (v_sources -> 0 ->> 'supplier_id')::bigint;
            END IF;
        ELSE
            SELECT sp.supplier_id INTO v_supplier_id
              FROM supplier_product sp
             WHERE sp.id = v_price.supplier_product_id;

            -- 定价选中的源 SKU：与 fn_price_variant 同一个排序函数的第一名。
            SELECT rc.supplier_variant_id INTO v_sv
              FROM fn_route_candidates(v_variant, v_date, p_channel_id, v_price.currency) rc
             WHERE rc.route_rank = 1;

            IF v_sv IS NULL THEN
                RAISE EXCEPTION '变体 % 在 % 没有选出可履约的源（定价与选源不一致）', v_variant, v_date;
            END IF;

            v_session_id  := v_price_row.session_id;
            v_ticket_type := v_price_row.ticket_type_id;

            -- 按团报价：向源侧买的是「一整团」，进几次场看团人数。
            v_need := CASE WHEN v_basis = 'per_group' THEN 1 ELSE v_qty END;
            v_adm  := v_qty;

            v_sources := jsonb_build_array(jsonb_build_object(
                'component_variant_id', v_variant,
                'supplier_variant_id',  v_sv,
                'supplier_product_id',  v_price.supplier_product_id,
                'supplier_id',          v_supplier_id,
                'product_session_id',   v_session_id,
                -- 源场次：走场次级绑定表，不按日期猜（硬约束 19）。
                -- 没有绑定就留空 —— 留空是「还不知道」，不是「没有」。
                -- 库存快照与预订建到那一步再报错，源头不猜。
                'supplier_session_id',  fn_bound_supplier_session(v_session_id, v_price.supplier_product_id),
                'ticket_type_id',       v_ticket_type,
                'quantity',             v_need,
                'admission_quantity',   v_adm,
                'unit_cost',            v_price.cost_price,
                'currency',             v_price.source_currency,
                'fx_rate',              v_price.fx_rate,
                'fx_as_of',             v_price.fx_as_of));
        END IF;

        -- 展示与对账用的成分快照（组合看得见自己由什么组成）
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
                    ELSE '{}'::jsonb END
            || CASE WHEN v_role = 'combo'
                    THEN jsonb_build_object('components', v_sources)
                    ELSE '{}'::jsonb END;

        v_resolved := v_resolved || jsonb_build_array(jsonb_build_object(
            'item_index',           v_item_index,
            'product_id',           v_price.product_id,
            'product_variant_id',   v_variant,
            'session_id',           v_session_id,
            'ticket_type_id',       v_ticket_type,
            'channel_listing_id',   v_listing_id,
            'supplier_product_id',  CASE WHEN v_role = 'combo' AND NOT v_is_bundle THEN NULL ELSE v_price.supplier_product_id END,
            'supplier_id',          v_supplier_id,
            'quantity',             v_qty,
            'unit_price',           v_unit_price,
            'unit_cost',            v_unit_cost,
            'total_price',          v_total_price,
            'currency',             v_price.currency,
            'pricing_basis',        CASE WHEN v_basis = 'per_group' THEN 'per_group' ELSE 'per_person' END,
            'snapshot',             v_snapshot,
            'sources',              v_sources));

        v_pricing := v_pricing || jsonb_build_array(v_snapshot);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ③a 源场次解析：每一行成分都要落到一个源场次上
    --
    -- 库存数字挂在源场次上，预订也挂在源场次上 —— 所以这一行成分的源场次
    -- 必须在下单时就定下来，后面所有环节读同一个值。
    --
    -- 为什么强调「同一个值」：
    --   库存算一遍用 A 源场次、建预订再算一遍用 B 源场次，
    --   卖出去的是 A 场的票、出去的是 B 场的票，账面上完全看不出来。
    --   所以这里解析一次写回，后面不许再各算各的。
    --
    -- 解析口径：场次级绑定表（product_session_source），不按日期猜（硬约束 19）。
    -- 没有绑定就留空 —— 留空是「还不知道」，真到建预订那一步才报错。
    -- ---------------------------------------------------------------------------------
    v_sessions := '[]'::jsonb;

    FOR v_line_rec IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_new_sources := '[]'::jsonb;

        FOR v_src IN
            SELECT e.value FROM jsonb_array_elements(v_line_rec.value->'sources') e
        LOOP
            IF NULLIF(v_src->>'supplier_session_id', '') IS NULL THEN
                v_src := v_src || jsonb_build_object(
                    'supplier_session_id',
                    fn_bound_supplier_session(
                        NULLIF(v_src->>'product_session_id', '')::bigint,
                        NULLIF(v_src->>'supplier_product_id', '')::bigint));
            END IF;

            v_new_sources := v_new_sources || jsonb_build_array(v_src);
        END LOOP;

        v_resolved := jsonb_set(v_resolved,
                                ARRAY[(v_line_rec.ordinality - 1)::text, 'sources'],
                                v_new_sources);
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ③a 实名归属：分不清是哪一行的，不许猜
    --
    -- 组合套餐把这个歧义放大了：
    --   一张家庭套餐（成分 9 = 2 份成人票）+ 一张单买的成人票（也是成分 9），
    --   两行明细都要实名，但光看 variant_id 分不出「这份姓名属于哪一行」。
    --
    -- 猜错就是把甲的实名绑到乙的票上 —— 闸机前才发现，人已经进去了。
    -- 所以同一个成分变体出现在多行明细时，当场报错，让调用方带 item_index 指明行号。
    -- ---------------------------------------------------------------------------------
    IF NOT v_strict_item THEN
        SELECT string_agg(DISTINCT x.component_variant_id, ', ')
          INTO v_ambiguous
          FROM (
                SELECT s->>'component_variant_id' AS component_variant_id
                  FROM jsonb_array_elements(v_resolved) it
                  CROSS JOIN LATERAL jsonb_array_elements(it->'sources') s
                 GROUP BY s->>'component_variant_id'
                HAVING count(DISTINCT it->>'item_index') > 1
               ) x;

        IF v_ambiguous IS NOT NULL THEN
            RAISE EXCEPTION '成分变体 % 同时出现在多行明细里，持票人无法归属：请在实名里带 item_index 指明是哪一行（从 1 开始）',
              v_ambiguous;
        END IF;
    ELSE
        -- 带了 item_index 就得全带：漏一条的那条匹配不上任何行，
        -- 报出来的是「实名收不齐」这种让人摸不着头脑的话。
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_holders) h WHERE NOT (h ? 'item_index')) THEN
            RAISE EXCEPTION '实名里带了 item_index 的，每一条实名都必须带 item_index（要么全带，要么全不带）';
        END IF;
    END IF;

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
    --
    -- 组合：每个成分在自己的源场次上单独预占（成分之间是不同的票，甚至不同的源商品）。
    -- ---------------------------------------------------------------------------------
    FOR v_detail IN SELECT * FROM jsonb_array_elements(v_resolved)
    LOOP
        FOR v_src IN SELECT * FROM jsonb_array_elements(v_detail->'sources')
        LOOP
            -- 源场次在 ③a 已经解析过一次，这里直接读，不重算。
            v_sup_sess := NULLIF(v_src->>'supplier_session_id', '')::bigint;

            v_sessions := v_sessions || jsonb_build_array(v_sup_sess);
        END LOOP;
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

    -- ---------------------------------------------------------------------------------
    -- ③b-1 场次总量校验：同一场次上的所有成分要一起算
    --
    -- 逐成分各查各的会漏掉超卖：
    --   成人成分查「这个源票种还剩 2 张」→ 2 ≤ 2 过；
    --   儿童成分也查「还剩 2 张」→ 1 ≤ 2 过；
    --   加起来要 3 张，可那个池子只有 2 张 —— 超卖一张。
    --
    -- 根子在参数化源：成人和儿童是**同一个源票种**（一个人群参数化的 SKU），
    -- 一个池子被查了两次，每次都以为还有 2 张。
    -- 池子被查两次这个事实，只有按场次加总才看得见。
    --
    -- 所以这里按源场次把这一单的需求加总，跟这个场次的**总可售数**比一次
    -- （票种级可售数是子集，比总池子严；总池子都不够，子集更不够）。
    -- 这一道挡住的是「一个池子被查两次」；下面逐成分那道挡住的是「某个票种本来就不够」。
    -- ---------------------------------------------------------------------------------
    FOR v_sup_sess, v_demand IN
        SELECT (src->>'supplier_session_id')::bigint AS sess,
               sum((src->>'admission_quantity')::int)::int AS demand
          FROM jsonb_array_elements(v_resolved) d
          CROSS JOIN LATERAL jsonb_array_elements(d->'sources') src
         WHERE NULLIF(src->>'supplier_session_id', '') IS NOT NULL
           AND NOT COALESCE((src->>'is_bundle')::boolean, false)
         GROUP BY 1
         ORDER BY 1
    LOOP
        PERFORM * FROM fn_reserve_qty(
            v_sup_sess,
            NULL,
            v_demand,
            '本单在这个源场次上的总需求（多个成分合起来）');
    END LOOP;

    -- 套装：按套数预占。
    --
    -- 源侧卖的是整套，池子里的单位也是套 ——
    -- 拿「入场份数」去比一个以套计的池子，就会把 3 个名额当成 3 套，
    -- 明明还剩 1 套也报「库存不足」。所以这里走源票种口径、按套数算。
    FOR v_sup_sess, v_sv, v_stt, v_sets IN
        SELECT DISTINCT (src->>'supplier_session_id')::bigint,
                        (src->>'supplier_variant_id')::bigint,
                        (src->>'source_ticket_type_id')::bigint,
                        (src->>'bundle_sets')::int
          FROM jsonb_array_elements(v_resolved) d
          CROSS JOIN LATERAL jsonb_array_elements(d->'sources') src
         WHERE COALESCE((src->>'is_bundle')::boolean, false)
           AND NULLIF(src->>'supplier_session_id', '') IS NOT NULL
    LOOP
        PERFORM * FROM fn_reserve_qty(
            v_sup_sess,
            NULL,
            v_stt,
            v_sets,
            '本单在这个源场次上的套装需求（按套）');
    END LOOP;

    -- 逐成分算可售数，按明细聚合成一份快照（每条明细一份）
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        v_avail := '[]'::jsonb;

        FOR v_src, v_src_ord IN
            SELECT e.value, e.ordinality
              FROM jsonb_array_elements(v_detail->'sources') WITH ORDINALITY AS e(value, ordinality)
        LOOP
            v_sup_sess := (v_src->>'supplier_session_id')::bigint;

            IF COALESCE((v_src->>'is_bundle')::boolean, false) THEN
                -- 套装：池子落在源侧的「套」票种上，量是套数。
                SELECT * INTO v_avail_row
                  FROM fn_reserve_qty(v_sup_sess,
                                      NULL,
                                      NULLIF(v_src->>'source_ticket_type_id', '')::bigint,
                                      (v_src->>'bundle_sets')::int,
                                      '套装 ' || COALESCE(v_src->>'component_variant_id', '?')
                                        || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));
            ELSE
                SELECT * INTO v_avail_row
                  FROM fn_reserve_qty(v_sup_sess,
                                      NULLIF(v_src->>'ticket_type_id', '')::bigint,
                                      (v_src->>'admission_quantity')::int,
                                      '变体 ' || COALESCE(v_src->>'component_variant_id', '?')
                                        || ' ' || COALESCE(v_detail->'snapshot'->>'visit_date', '?'));
            END IF;

            v_avail := v_avail || jsonb_build_array(jsonb_build_object(
                'component_variant_id', (v_src->>'component_variant_id')::bigint,
                'supplier_variant_id',  (v_src->>'supplier_variant_id')::bigint,
                'source_quantity',      (CASE WHEN COALESCE((v_src->>'is_bundle')::boolean, false)
                                              THEN (v_src->>'bundle_sets')::int
                                              ELSE (v_src->>'admission_quantity')::int END),
                'known',         v_avail_row.known,
                'available_qty', v_avail_row.available_qty,
                'committed_qty', v_avail_row.committed_qty,
                'remaining_qty', v_avail_row.remaining_qty,
                'sold_qty',      v_avail_row.sold_qty,
                'held_qty',      v_avail_row.held_qty,
                'source_status', v_avail_row.source_status,
                'snapshot_at',   v_avail_row.snapshot_at));
        END LOOP;

        -- 聚合成一条明细的可售数快照：
        --   known      = 全都知道才算知道（有一个成分不知道，这条明细就不知道）
        --   remaining  = 取最小（最紧的那个成分才是约束）
        --   逐成分的明细放在 sources 里，对账要看得见「哪一份成分不紧」
        v_avail_items := v_avail_items || jsonb_build_array(jsonb_build_object(
            'known',         COALESCE((SELECT bool_and((e->>'known')::boolean) FROM jsonb_array_elements(v_avail) e), false),
            'available_qty', COALESCE((SELECT sum((e->>'available_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'committed_qty', COALESCE((SELECT sum((e->>'committed_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'remaining_qty', (SELECT min((e->>'remaining_qty')::int) FROM jsonb_array_elements(v_avail) e),
            'sold_qty',      COALESCE((SELECT sum((e->>'sold_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'held_qty',      COALESCE((SELECT sum((e->>'held_qty')::int) FROM jsonb_array_elements(v_avail) e), 0),
            'source_status', (SELECT e->>'source_status' FROM jsonb_array_elements(v_avail) e LIMIT 1),
            'snapshot_at',   (SELECT max((e->>'snapshot_at')::timestamptz) FROM jsonb_array_elements(v_avail) e),
            'sources',       v_avail));
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
                    'availability', COALESCE(v_avail_items -> ((v_ord - 1)::int), '{}'::jsonb)),
                'pending')
        RETURNING id INTO v_item_id;

        -- 成分行落库：履约的单位（预订 / 出券 / 预占都按它走）
        INSERT INTO sales_order_item_source (order_item_id, component_variant_id, supplier_variant_id,
                                             supplier_product_id, supplier_id, product_session_id,
                                             supplier_session_id, ticket_type_id, quantity,
                                             admission_quantity, unit_cost, currency, fx_rate, fx_as_of)
        SELECT v_item_id,
               (s->>'component_variant_id')::bigint,
               (s->>'supplier_variant_id')::bigint,
               (s->>'supplier_product_id')::bigint,
               (s->>'supplier_id')::bigint,
               (s->>'product_session_id')::bigint,
               (s->>'supplier_session_id')::bigint,
               (s->>'ticket_type_id')::bigint,
               (s->>'quantity')::numeric,
               (s->>'admission_quantity')::numeric,
               (s->>'unit_cost')::numeric,
               (s->>'currency'),
               (s->>'fx_rate')::numeric,
               (s->>'fx_as_of')::date
          FROM jsonb_array_elements(v_detail->'sources') s;

        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'order_item_id',  v_item_id,
            'item_index',     (v_detail->>'item_index')::int,
            'variant_id',     (v_detail->>'product_variant_id')::bigint,
            'product_id',     (v_detail->>'product_id')::bigint,
            'ticket_type_id', NULLIF(v_detail->>'ticket_type_id', '')::bigint,
            'quantity',       (v_detail->>'quantity')::int,
            'sources',        v_detail->'sources'));
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④c 库存预占落账
    --
    -- 每份成分都要有一条预占记录：「我们卖出去多少」是事实，必须查得到。
    --
    -- 有购物车预占就把它消费掉（同一张预占从 active 变 consumed，
    -- 承诺量不变，不会重复扣）；没有就新建一张 consumed 的。
    -- ---------------------------------------------------------------------------------
    FOR v_detail, v_ord IN
        SELECT e.value, e.ordinality
          FROM jsonb_array_elements(v_resolved) WITH ORDINALITY AS e(value, ordinality)
    LOOP
        IF NULLIF(v_detail->>'session_id', '') IS NULL THEN
            RAISE EXCEPTION '订单明细（变体 %）没有场次，无法预占库存',
              COALESCE(v_detail->>'product_variant_id', '?');
        END IF;

        FOR v_src, v_src_ord IN
            SELECT e.value, e.ordinality
              FROM jsonb_array_elements(v_detail->'sources') WITH ORDINALITY AS e(value, ordinality)
        LOOP
            -- 套装不按成分各占一份（源侧卖的是整套），它在下面单独占一条。
            IF COALESCE((v_src->>'is_bundle')::boolean, false) THEN
                CONTINUE;
            END IF;

            v_sup_sess := (v_src->>'supplier_session_id')::bigint;
            v_qty       := (v_src->>'admission_quantity')::int;

            SELECT h.id INTO v_hold_id
              FROM inventory_hold h
             WHERE h.status = 'active'
               AND h.channel_id = p_channel_id
               AND h.product_variant_id = (v_src->>'component_variant_id')::bigint
               AND h.product_session_id IS NOT DISTINCT FROM (v_src->>'product_session_id')::bigint
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
                v_hold_no := 'HOLD' || v_order_no || '-' || lpad(v_ord::text, 2, '0')
                          || '-' || lpad(v_src_ord::text, 2, '0');

                INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                            supplier_id, product_variant_id, supplier_session_id,
                                            quantity, consumed_quantity, status, order_id,
                                            expires_at, created_at)
                VALUES (v_hold_no, p_channel_id,
                        (v_src->>'product_session_id')::bigint,
                        (v_src->>'ticket_type_id')::bigint,
                        (v_src->>'supplier_id')::bigint,
                        (v_src->>'component_variant_id')::bigint,
                        v_sup_sess,
                        v_qty, v_qty, 'consumed', v_order_id,
                        now() + interval '30 minutes', now())
                RETURNING id INTO v_hold_id;
            END IF;
        END LOOP;

        -- 套装：一条预占记「套」，不记成分。
        --
        -- 记成分会把这个池子扣成「3 张」—— 源侧那个池子是以套计的，
        -- 扣成 3 套就把可售数扣没了。所以只记一套。
        FOR v_src IN
            SELECT DISTINCT ON (e.value->>'supplier_variant_id') e.value
              FROM jsonb_array_elements(v_detail->'sources') e
             WHERE COALESCE((e.value->>'is_bundle')::boolean, false)
             ORDER BY e.value->>'supplier_variant_id'
        LOOP
            v_sup_sess := (v_src->>'supplier_session_id')::bigint;
            v_qty       := (v_src->>'bundle_sets')::int;

            SELECT h.id INTO v_hold_id
              FROM inventory_hold h
             WHERE h.status = 'active'
               AND h.channel_id = p_channel_id
               AND h.product_variant_id = (v_detail->>'product_variant_id')::bigint
               AND h.product_session_id IS NOT DISTINCT FROM (v_src->>'product_session_id')::bigint
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
                v_hold_no := 'HOLD' || v_order_no || '-' || lpad(v_ord::text, 2, '0')
                          || '-B' || (v_src->>'supplier_variant_id');

                INSERT INTO inventory_hold (hold_no, channel_id, product_session_id, ticket_type_id,
                                            supplier_id, product_variant_id, supplier_session_id,
                                            source_ticket_type_id,
                                            quantity, consumed_quantity, status, order_id,
                                            expires_at, created_at)
                VALUES (v_hold_no, p_channel_id,
                        (v_src->>'product_session_id')::bigint,
                        NULL,
                        (v_src->>'supplier_id')::bigint,
                        (v_detail->>'product_variant_id')::bigint,
                        v_sup_sess,
                        (v_src->>'source_ticket_type_id')::bigint,
                        v_qty, v_qty, 'consumed', v_order_id,
                        now() + interval '30 minutes', now())
                RETURNING id INTO v_hold_id;
            END IF;
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------------------------
    -- ④b 实名：票种要求的持票人信息必须收齐
    --
    -- 结算页要哪些字段由 checkout_requirement 说（不变量 25 按同一口径把门）。
    -- 这里按**成分**逐项校验：组合的每个成分各有自己的份数与票种，
    -- 持票人按成分变体分组收（组合 = 2 份成人票 + 1 份儿童票 → 三份实名）。
    -- 校验口径与不变量 25 必须一致 —— 两处口径不一样，就会出现「函数放行、门禁拦下」。
    -- ---------------------------------------------------------------------------------
    FOR v_line IN SELECT * FROM jsonb_array_elements(v_items)
    LOOP
        FOR v_src IN SELECT * FROM jsonb_array_elements(v_line->'sources')
        LOOP
            FOR v_req IN
                SELECT cr.field_code, cr.label, cr.max_length, cr.pattern
                  FROM checkout_requirement cr
                 WHERE cr.required
                   AND cr.product_id = (v_line->>'product_id')::bigint
                   AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = (v_src->>'ticket_type_id')::bigint)
                   AND (cr.channel_id IS NULL OR cr.channel_id = p_channel_id)
            LOOP
                SELECT count(DISTINCT (h->>'sequence')::int) INTO v_holders
                  FROM jsonb_array_elements(p_holders) h
                 WHERE (h->>'variant_id')::bigint = (v_src->>'component_variant_id')::bigint
                   AND h->>'field_code' = v_req.field_code
                   AND (NOT v_strict_item
                        OR (h->>'item_index')::int = (v_line->>'item_index')::int);

                IF v_holders < (v_src->>'admission_quantity')::int THEN
                    RAISE EXCEPTION '订单行（成分变体 %）要求实名信息：% 需要 % 份，实收 % 份',
                      (v_src->>'component_variant_id')::bigint, v_req.label,
                      (v_src->>'admission_quantity')::int, v_holders;
                END IF;

                FOR v_holder IN
                    SELECT h FROM jsonb_array_elements(p_holders) h
                     WHERE (h->>'variant_id')::bigint = (v_src->>'component_variant_id')::bigint
                       AND h->>'field_code' = v_req.field_code
                       AND (NOT v_strict_item
                            OR (h->>'item_index')::int = (v_line->>'item_index')::int)
                LOOP
                    IF v_req.max_length IS NOT NULL
                       AND length(COALESCE(v_holder->>'value', '')) > v_req.max_length THEN
                        RAISE EXCEPTION '订单行（成分变体 %）的 % 超过长度上限 %',
                          (v_src->>'component_variant_id')::bigint, v_req.label, v_req.max_length;
                    END IF;

                    IF NULLIF(v_req.pattern, '') IS NOT NULL
                       AND (v_holder->>'value') !~ v_req.pattern THEN
                        RAISE EXCEPTION '订单行（成分变体 %）的 % 不符合格式要求',
                          (v_src->>'component_variant_id')::bigint, v_req.label;
                    END IF;
                END LOOP;
            END LOOP;
        END LOOP;
    END LOOP;

    -- 持票人落库（每个字段一行，与 checkout_requirement 的字段口径对齐）
    INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, component_variant_id,
                              sequence, field_code, value, value_hash)
    SELECT v_order_id,
           (it->>'order_item_id')::bigint,
           (s->>'ticket_type_id')::bigint,
           (s->>'component_variant_id')::bigint,
           (h->>'sequence')::int,
           h->>'field_code',
           h->>'value',
           md5(COALESCE(h->>'value', ''))
      FROM jsonb_array_elements(v_items) it
      JOIN LATERAL jsonb_array_elements(it->'sources') s ON true
      JOIN LATERAL jsonb_array_elements(p_holders) h
        ON (h->>'variant_id')::bigint = (s->>'component_variant_id')::bigint
       AND (NOT v_strict_item
            OR (h->>'item_index')::int = (it->>'item_index')::int);

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
$function$;

-- -----------------------------------------------------------------------------
-- ⑧ 建预订：套装按套数下
--
-- 预订的单位是源 SKU，份数是源侧认的那个单位：套装是套，别的是人。
-- ---------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.fn_create_bookings(p_order_id bigint)
 RETURNS TABLE(booking_id bigint, booking_no text, order_item_id bigint, created boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_order      RECORD;
    v_item       RECORD;
    v_grp        RECORD;
    v_booking    RECORD;
    v_booking_id BIGINT;
    v_booking_no TEXT;
    v_date       DATE;
    v_session    BIGINT;
    v_variant    BIGINT;
    -- 套装（017）：订的是「套」，不是「人」
    v_bundle_id  BIGINT;
    v_bundle_qty NUMERIC;
    v_sets       INT;
BEGIN
    SELECT o.id, o.order_no, o.status INTO v_order
      FROM sales_order o
     WHERE o.id = p_order_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION '订单 % 不存在', p_order_id;
    END IF;

    IF v_order.status NOT IN ('paid', 'booking_pending') THEN
        RAISE EXCEPTION '订单 % 当前状态 % 不能创建预订（只允许 paid / booking_pending）',
          v_order.order_no, v_order.status;
    END IF;

    FOR v_item IN
        SELECT oi.id, oi.product_id, oi.session_id, oi.ticket_type_id, oi.quantity,
               oi.product_variant_id, oi.supplier_product_id, oi.supplier_id,
               oi.detail_snapshot
          FROM sales_order_item oi
         WHERE oi.order_id = v_order.id
         ORDER BY oi.id
    LOOP
        -- 有成分行的明细：按源 SKU 分组建预订。
        --
        -- 分组键 = (源 SKU, 源商品, 源场次)：源卖的是 SKU，
        -- 同一个 SKU 在同一个源场次上只订一次（参数化源：成人与儿童是同一个 SKU）。
        FOR v_grp IN
            SELECT s.supplier_variant_id,
                   s.supplier_product_id,
                   s.supplier_id,
                   s.supplier_session_id,
                   s.product_session_id,
                   sum(s.admission_quantity)          AS total_admission,
                   jsonb_agg(jsonb_build_object(
                       'component_variant_id', s.component_variant_id,
                       'ticket_type_id',       s.ticket_type_id,
                       'quantity',            s.quantity,
                       'admission_quantity',  s.admission_quantity,
                       'unit_cost',           s.unit_cost,
                       'currency',            s.currency
                   ) ORDER BY s.component_variant_id, s.id) AS components
              FROM sales_order_item_source s
             WHERE s.order_item_id = v_item.id
             GROUP BY s.supplier_variant_id, s.supplier_product_id, s.supplier_id,
                      s.supplier_session_id, s.product_session_id
             ORDER BY min(s.id)
        LOOP
            -- 幂等：这张明细里同一个源 SKU 只有一条预订。
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_item_id = v_item.id
               AND b.supplier_variant_id IS NOT DISTINCT FROM v_grp.supplier_variant_id
               AND b.supplier_session_id IS NOT DISTINCT FROM v_grp.supplier_session_id
             ORDER BY b.id
             LIMIT 1;

            IF FOUND THEN
                -- 明细状态补齐：上一次建到一半崩了，这里把状态接上。
                UPDATE sales_order_item
                   SET status = 'booking'
                 WHERE id = v_item.id
                   AND status = 'pending';

                booking_id    := v_booking.id;
                booking_no    := v_booking.booking_no;
                order_item_id := v_item.id;
                created       := false;
                RETURN NEXT;
                CONTINUE;
            END IF;

            -- 源场次没解析出来（老数据）：按绑定表再解析一次，取的还是绑定表那条。
            v_session := v_grp.supplier_session_id;
            IF v_session IS NULL THEN
                v_session := fn_bound_supplier_session(v_grp.product_session_id,
                                                       v_grp.supplier_product_id);
            END IF;

            IF v_session IS NULL THEN
                RAISE EXCEPTION '订单行 % 的源 SKU % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
                  v_item.id, v_grp.supplier_variant_id, v_grp.product_session_id, v_grp.supplier_product_id;
            END IF;

            -- 套装（017）：源侧卖的是整套，订的份数是套数。
            --
            -- 成分行的入场份数是「人」（一套 3 个名额），源侧要的是「套」。
            -- 拿人数去下单，源侧会当成订了 3 套 —— 多订两套，钱就多花两套。
            v_bundle_id := NULL;
            v_sets      := NULL;

            SELECT svb.id INTO v_bundle_id
              FROM supplier_variant_bundle svb
             WHERE svb.product_variant_id = v_item.product_variant_id
               AND svb.supplier_variant_id = v_grp.supplier_variant_id
               AND svb.status = 'active';

            IF v_bundle_id IS NOT NULL THEN
                SELECT COALESCE(sum(p.quantity), 0) INTO v_bundle_qty
                  FROM supplier_variant_bundle_part p
                 WHERE p.bundle_id = v_bundle_id;

                IF v_bundle_qty <= 0 OR v_grp.total_admission % v_bundle_qty <> 0 THEN
                    RAISE EXCEPTION
                        '套装预订的入场份数 % 不是每套 % 份的整数倍（订了几套算不出来）',
                        v_grp.total_admission, v_bundle_qty;
                END IF;

                v_sets := (v_grp.total_admission / v_bundle_qty)::int;
            END IF;

            v_booking_no := 'BK' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_booking_no')::text, 6, '0');

            v_date := NULLIF(v_item.detail_snapshot->>'visit_date', '')::date;

            INSERT INTO booking (booking_no, order_id, order_item_id,
                                 supplier_id, supplier_product_id, supplier_session_id,
                                 supplier_variant_id, status, idempotency_key, request_payload)
            VALUES (v_booking_no, v_order.id, v_item.id,
                    v_grp.supplier_id, v_grp.supplier_product_id, v_session,
                    v_grp.supplier_variant_id, 'pending',
                    'bk-' || v_order.order_no || '-' || v_item.id::text
                             || '-' || v_grp.supplier_variant_id::text,
                    jsonb_build_object('order_no', v_order.order_no,
                                       'order_item_id', v_item.id,
                                       'product_id', v_item.product_id,
                                       'supplier_variant_id', v_grp.supplier_variant_id,
                                       'quantity', CASE WHEN v_sets IS NULL THEN v_grp.total_admission ELSE v_sets END,
                                       'admission_quantity', v_grp.total_admission,
                                       'visit_date', v_date,
                                       'product_session_id', v_grp.product_session_id,
                                       'supplier_session_id', v_session,
                                       'components', v_grp.components,
                                       'snapshot', v_item.detail_snapshot))
            RETURNING id INTO v_booking_id;

            -- 明细状态推进：pending → booking（这一单已经在向源侧下单了）
            UPDATE sales_order_item
               SET status = 'booking'
             WHERE id = v_item.id
               AND status = 'pending';

            booking_id    := v_booking_id;
            booking_no    := v_booking_no;
            order_item_id := v_item.id;
            created       := true;
            RETURN NEXT;
        END LOOP;

        -- 老明细（013 之前下的单）没有成分行：一条明细一条预订（沿用 005 的口径）。
        IF NOT EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = v_item.id) THEN
            SELECT b.id, b.booking_no INTO v_booking
              FROM booking b
             WHERE b.order_id = v_order.id
               AND b.order_item_id = v_item.id
             ORDER BY b.id
             LIMIT 1;

            IF FOUND THEN
                UPDATE sales_order_item
                   SET status = 'booking'
                 WHERE id = v_item.id
                   AND status = 'pending';

                booking_id    := v_booking.id;
                booking_no    := v_booking.booking_no;
                order_item_id := v_item.id;
                created       := false;
                RETURN NEXT;
                CONTINUE;
            END IF;

            IF v_item.supplier_id IS NULL OR v_item.supplier_product_id IS NULL THEN
                RAISE EXCEPTION '订单行 % 没有采纳源，无法创建预订（下单时必须选中源）', v_item.id;
            END IF;

            IF v_item.session_id IS NULL THEN
                RAISE EXCEPTION '订单行 % 没有场次，无法创建预订', v_item.id;
            END IF;

            -- 源场次：走场次级绑定表，不按日期猜（硬约束 19）。
            v_session := fn_bound_supplier_session(v_item.session_id, v_item.supplier_product_id);

            IF v_session IS NULL THEN
                RAISE EXCEPTION '订单行 % 的规范场次 % 没有绑定源商品 % 的源场次，无法创建预订（product_session_source 缺一条绑定）',
                  v_item.id, v_item.session_id, v_item.supplier_product_id;
            END IF;

            -- 源变体：按覆盖映射找能履约这个变体的源变体（同一源商品内取置信度最高的）。
            SELECT svm.supplier_variant_id INTO v_variant
              FROM supplier_variant_mapping svm
              JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
             WHERE svm.product_variant_id = v_item.product_variant_id
               AND sv.supplier_product_id = v_item.supplier_product_id
             ORDER BY svm.confidence DESC, svm.id
             LIMIT 1;

            v_booking_no := 'BK' || to_char(now(), 'YYYYMMDD')
                         || lpad(nextval('public.seq_booking_no')::text, 6, '0');

            v_date := NULLIF(v_item.detail_snapshot->>'visit_date', '')::date;

            INSERT INTO booking (booking_no, order_id, order_item_id, supplier_id, supplier_product_id,
                                 supplier_session_id, supplier_variant_id, status, idempotency_key,
                                 request_payload)
            VALUES (v_booking_no, v_order.id, v_item.id, v_item.supplier_id, v_item.supplier_product_id,
                    v_session, v_variant, 'pending',
                    'bk-' || v_order.order_no || '-' || v_item.id::text,
                    jsonb_build_object('order_no', v_order.order_no,
                                       'order_item_id', v_item.id,
                                       'product_id', v_item.product_id,
                                       'quantity', v_item.quantity,
                                       'visit_date', v_date,
                                       'product_session_id', v_item.session_id,
                                       'supplier_session_id', v_session,
                                       'supplier_variant_id', v_variant,
                                       'snapshot', v_item.detail_snapshot))
            RETURNING id INTO v_booking_id;

            UPDATE sales_order_item
               SET status = 'booking'
             WHERE id = v_item.id
               AND status = 'pending';

            booking_id    := v_booking_id;
            booking_no    := v_booking_no;
            order_item_id := v_item.id;
            created       := true;
            RETURN NEXT;
        END IF;
    END LOOP;

    -- 全部明细都有预订了，订单推进到 booking_pending（触发器落 OrderBookingPending）
    UPDATE sales_order
       SET status = 'booking_pending'
     WHERE id = v_order.id
       AND status = 'paid'
       AND NOT EXISTS (
             SELECT 1 FROM sales_order_item oi
              WHERE oi.order_id = v_order.id
                AND NOT EXISTS (SELECT 1 FROM booking b
                                 WHERE b.order_id = v_order.id AND b.order_item_id = oi.id));

    RETURN;
END;
$function$;

-- -----------------------------------------------------------------------------
-- ⑨ 日历同步：套装的日期来自套装源价行
-- ---------------------------------------------------------------------------


CREATE OR REPLACE FUNCTION public.fn_sync_combo_calendar()
 RETURNS TABLE(price_rows integer, cells integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_price_rows INT := 0;
  v_cells      INT := 0;
BEGIN
  -- ① 组合的售价行
  --
  -- 日期与场次：成分的售价行。
  -- 「所有成分都在同一天、同一场次」才算一份套餐 ——
  -- 少一个成分就是缺一份货（013 的口径），多一个场次就是两张套餐。
  INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency,
                              cost_price, cost_source_product_id, sell_price, list_price,
                              discount_pct, rule, status, source, synced_at, product_variant_id,
                              price_locked, fx_rate, fx_as_of)
  SELECT c.product_id, c.session_id, NULL, NULL, c.date, q.currency,
         q.cost_price, q.supplier_product_id, q.sell_price, q.list_price,
         q.discount_pct, q.rule, 'active', 'calc', now(), c.variant_id,
         q.price_locked, q.fx_rate, q.fx_as_of
    FROM (
      -- 配方组合：日期来自成分的售价行。
      -- 「所有成分都在同一天、同一场次」才算一份套餐 ——
      -- 少一个成分就是缺一份货（013 的口径），多一个场次就是两张套餐。
      SELECT combo.id AS variant_id,
             combo.product_id,
             pc.date,
             pc.session_id
        FROM product_variant combo
        JOIN product_variant_relation r
          ON r.parent_variant_id = combo.id
         AND r.relation_type = 'included'
        JOIN price_calendar pc
          ON pc.product_variant_id = r.child_variant_id
         AND pc.status = 'active'
         AND pc.session_id IS NOT NULL
       WHERE combo.variant_role = 'combo'
       GROUP BY combo.id, combo.product_id, pc.date, pc.session_id
      HAVING count(DISTINCT r.child_variant_id) = (
               SELECT count(*)
                 FROM product_variant_relation r2
                WHERE r2.parent_variant_id = combo.id
                  AND r2.relation_type = 'included')
      UNION
      -- 套装组合（017）：日期来自套装自己的源价行。
      --
      -- 套装的成分可能压根没有单独的售价行（源侧只卖整套），
      -- 所以日期不能只从成分那儿取。
      SELECT combo.id AS variant_id,
             combo.product_id,
             spc.date,
             ps.id
        FROM product_variant combo
        JOIN supplier_variant_bundle svb
          ON svb.product_variant_id = combo.id
         AND svb.status = 'active'
        JOIN supplier_price_calendar spc
          ON spc.supplier_variant_id = svb.supplier_variant_id
         AND spc.product_variant_id = combo.id
         AND spc.status = 'available'
        JOIN LATERAL (
              SELECT p2.id
                FROM product_session p2
               WHERE p2.product_id = combo.product_id
                 AND p2.session_date = spc.date
                 AND p2.status = 'active'
               ORDER BY p2.id
               LIMIT 1) ps ON true
       WHERE combo.variant_role = 'combo'
    ) c
    CROSS JOIN LATERAL fn_price_variant(c.variant_id, c.date, fn_default_context_channel(), NULL) q
   WHERE q.sell_price IS NOT NULL
  ON CONFLICT (product_variant_id, date, COALESCE(channel_id, 0), COALESCE(session_id, 0))
    WHERE product_variant_id IS NOT NULL
  DO UPDATE SET cost_price             = EXCLUDED.cost_price,
                cost_source_product_id = EXCLUDED.cost_source_product_id,
                sell_price             = EXCLUDED.sell_price,
                list_price             = EXCLUDED.list_price,
                discount_pct           = EXCLUDED.discount_pct,
                rule                   = EXCLUDED.rule,
                price_locked           = EXCLUDED.price_locked,
                fx_rate                = EXCLUDED.fx_rate,
                fx_as_of               = EXCLUDED.fx_as_of,
                status                 = 'active',
                source                 = 'calc',
                synced_at              = now();
  GET DIAGNOSTICS v_price_rows = ROW_COUNT;

  -- ② 日历格子：组合在哪些渠道上 = 它的商品在哪些渠道上架
  --
  -- 价格直接取组合自己的售价行（刷新作业算的是同一个值，同一个出处）。
  INSERT INTO c_variant_calendar (channel_id, product_variant_id, date,
                                  price_min, price_max, status, source_count, synced_at)
  SELECT cl.channel_id,
         pc.product_variant_id,
         pc.date,
         MIN(pc.sell_price),
         MAX(pc.sell_price),
         'available',
         (SELECT count(*)
            FROM supplier_variant_composition svc
           WHERE svc.product_variant_id = pc.product_variant_id
             AND svc.status = 'active')
         + (SELECT count(*)
              FROM supplier_variant_bundle_part svbp
              JOIN supplier_variant_bundle svb ON svb.id = svbp.bundle_id
             WHERE svb.product_variant_id = pc.product_variant_id
               AND svb.status = 'active'),
         now()
    FROM price_calendar pc
    JOIN product_variant pv ON pv.id = pc.product_variant_id
                          AND pv.variant_role = 'combo'
    JOIN channel_listing cl ON cl.product_id = pv.product_id
                           AND cl.status = 'online'
   WHERE pc.status = 'active'
     AND pc.sell_price IS NOT NULL
     AND pc.channel_id IS NULL
   GROUP BY cl.channel_id, pc.product_variant_id, pc.date
  ON CONFLICT (channel_id, product_variant_id, date)
  DO UPDATE SET price_min    = EXCLUDED.price_min,
                price_max    = EXCLUDED.price_max,
                status       = 'available',
                source_count = EXCLUDED.source_count,
                synced_at    = now();
  GET DIAGNOSTICS v_cells = ROW_COUNT;

  RETURN QUERY SELECT v_price_rows, v_cells;
END;
$function$;

-- -----------------------------------------------------------------------------
-- ⑩ 诊断：套装还差什么
--
-- 跟 v_combo_price_gap 一个口径：把「为什么卖不了」列出来，
-- 而不是只说「不可售」。
-- -----------------------------------------------------------------------------
CREATE VIEW v_bundle_gap AS
SELECT b.product_variant_id,
       b.supplier_variant_id,
       b.date,
       b.session_id,
       b.source_session_id,
       b.source_ticket_type_id,
       b.set_price,
       b.valid_days,
       b.union_days,
       CASE
         WHEN b.bundle_parts = 0 THEN '套装没有声明成分'
         WHEN b.declared_parts <> b.bundle_parts THEN '套装成分与规范声明对不上'
         WHEN b.set_price IS NULL THEN '套装当天没有源侧报价'
         WHEN b.session_id IS NULL THEN '套装当天没有规范场次'
         WHEN b.source_session_id IS NULL THEN '套装没有绑定源场次'
         WHEN b.source_ticket_type_id IS NULL THEN '套装没有源侧票种（算不出库存池）'
         WHEN b.valid_days < b.union_days THEN '源侧整套有效期盖不住成分窗口'
         WHEN ia.available_known IS FALSE THEN '源侧可售数未知（不拦，但要记快照）'
         ELSE ''
       END AS reason
  FROM (
        SELECT svb.product_variant_id,
               svb.supplier_variant_id,
               svb.valid_days,
               (SELECT count(*) FROM supplier_variant_bundle_part p
                 WHERE p.bundle_id = svb.id) AS bundle_parts,
               (SELECT count(*) FROM product_variant_relation r
                 WHERE r.parent_variant_id = svb.product_variant_id
                   AND r.relation_type = 'included') AS declared_parts,
               fn_variant_validity_days(svb.product_variant_id) AS union_days,
               d.date,
               ps.id AS session_id,
               ss.id AS source_session_id,
               spc.supplier_ticket_type_id AS source_ticket_type_id,
               spc.net_price AS set_price
          FROM supplier_variant_bundle svb
          -- 候选日子 = 我们打算卖的那几天 ∪ 源侧报了价的那几天。
          -- 只看「今天」没用：套装是按场次卖的，缺口长在具体某一天上。
          CROSS JOIN LATERAL (
                SELECT pc.date
                  FROM price_calendar pc
                 WHERE pc.product_variant_id = svb.product_variant_id
                   AND pc.status = 'active'
                UNION
                SELECT spc2.date
                  FROM supplier_price_calendar spc2
                 WHERE spc2.supplier_variant_id = svb.supplier_variant_id
                   AND spc2.product_variant_id = svb.product_variant_id
                   AND spc2.status = 'available') d
          LEFT JOIN LATERAL (
                SELECT p2.id
                  FROM product_session p2
                 WHERE p2.product_id = (SELECT pv.product_id
                                          FROM product_variant pv
                                         WHERE pv.id = svb.product_variant_id)
                   AND p2.session_date = d.date
                   AND p2.status = 'active'
                 ORDER BY p2.id
                 LIMIT 1) ps ON true
          LEFT JOIN LATERAL (
                SELECT ss2.id
                  FROM product_session_source pss
                  JOIN supplier_session ss2 ON ss2.id = pss.supplier_session_id
                 WHERE pss.product_session_id = ps.id
                   AND pss.supplier_product_id = (SELECT sv.supplier_product_id
                                                    FROM supplier_variant sv
                                                   WHERE sv.id = svb.supplier_variant_id)
                   AND ss2.session_date = d.date
                 ORDER BY pss.priority, pss.id
                 LIMIT 1) ss ON true
          LEFT JOIN LATERAL (
                SELECT s.supplier_ticket_type_id, s.net_price
                  FROM supplier_price_calendar s
                 WHERE s.supplier_variant_id = svb.supplier_variant_id
                   AND s.product_variant_id = svb.product_variant_id
                   AND s.date = d.date
                   AND s.status = 'available'
                 ORDER BY s.id
                 LIMIT 1) spc ON true
         WHERE svb.status = 'active') b
  LEFT JOIN LATERAL (
        SELECT a.known AS available_known
          FROM fn_available_qty(b.source_session_id, NULL, b.source_ticket_type_id) a) ia
    ON true;

COMMENT ON VIEW v_bundle_gap IS
    '套装卖不了的原因（017）：套装没有声明成分 / 与规范声明对不上 / 当天没有报价 / 没有场次 / 有效期盖不住 / 可售数未知';


-- -----------------------------------------------------------------------------
-- ⑩b 读视图：套装的供给形态
--
-- Go 侧与运营都从这里读套装，不直接查底表 ——
-- 底表是主数据，读视图是「供给形态」这件事的完整表达（成分、份数、有效期、缺口）。
--
-- 三种异构融合方向在这里都能看出来：
--   方向 A（一个源 SKU 覆盖多个可售单元）：coverage
--   方向 B 配方（一个可售单元由多个源 SKU 组成）：supplier_variant_composition
--   方向 B 套装（一个源 SKU 把整套当一个 SKU 卖）：supplier_variant_bundle ← 本视图
-- -----------------------------------------------------------------------------
CREATE VIEW v_variant_bundle AS
SELECT svb.id                    AS bundle_id,
       svb.product_variant_id,
       pv.variant_code,
       pv.variant_key,
       pv.product_id,
       svb.supplier_variant_id,
       sv.supplier_product_id,
       sv.external_variant_id     AS source_set_sku,
       COALESCE(sv.title, '')     AS source_set_title,
       sup.code                   AS supplier_code,
       svb.valid_days             AS set_valid_days,
       fn_variant_validity_days(svb.product_variant_id) AS union_days,
       (svb.valid_days >= fn_variant_validity_days(svb.product_variant_id)) AS covers_window,
       (SELECT count(*)
          FROM supplier_variant_bundle_part p
         WHERE p.bundle_id = svb.id) AS part_count,
       (SELECT COALESCE(sum(p.quantity), 0)
          FROM supplier_variant_bundle_part p
         WHERE p.bundle_id = svb.id) AS admissions_per_set,
       (SELECT jsonb_agg(jsonb_build_object(
                   'component_variant_id', p.component_variant_id,
                   'variant_code',         cpv.variant_code,
                   'quantity',             p.quantity,
                   'audience_code',        COALESCE(ctt.code, ''),
                   'valid_days',           fn_variant_validity_days(p.component_variant_id))
                 ORDER BY p.id)
          FROM supplier_variant_bundle_part p
          JOIN product_variant cpv ON cpv.id = p.component_variant_id
          LEFT JOIN ticket_type ctt ON ctt.id = cpv.ticket_type_id
         WHERE p.bundle_id = svb.id) AS parts,
       (SELECT count(*)
          FROM v_bundle_gap g
         WHERE g.product_variant_id = svb.product_variant_id
           AND g.supplier_variant_id = svb.supplier_variant_id) AS gap_days,
       (SELECT COALESCE(jsonb_agg(DISTINCT g.reason), '[]'::jsonb)
          FROM v_bundle_gap g
         WHERE g.product_variant_id = svb.product_variant_id
           AND g.supplier_variant_id = svb.supplier_variant_id
           AND g.reason <> '') AS gap_reasons
  FROM supplier_variant_bundle svb
  JOIN product_variant pv ON pv.id = svb.product_variant_id
  JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id
  JOIN supplier_product sp ON sp.id = sv.supplier_product_id
  JOIN supplier sup ON sup.id = sp.supplier_id
 WHERE svb.status = 'active';

COMMENT ON VIEW v_variant_bundle IS
    '套装的供给形态：一行一个套装（规范变体 ← 整套源 SKU）+ 成分构成 + 有效期窗口 + 缺口诊断';

CREATE VIEW v_variant_bundle_part AS
SELECT svb.product_variant_id,
       svb.supplier_variant_id,
       svb.id AS bundle_id,
       p.id   AS part_id,
       p.component_variant_id,
       cpv.variant_code,
       COALESCE(cpv.title, '') AS title,
       p.quantity,
       COALESCE(ctt.code, '') AS audience_code,
       fn_variant_validity_days(p.component_variant_id) AS valid_days
  FROM supplier_variant_bundle_part p
  JOIN supplier_variant_bundle svb ON svb.id = p.bundle_id
  JOIN product_variant cpv ON cpv.id = p.component_variant_id
  LEFT JOIN ticket_type ctt ON ctt.id = cpv.ticket_type_id
 WHERE svb.status = 'active';

COMMENT ON VIEW v_variant_bundle_part IS
    '套装成分明细：一行一个成分（份数 / 人群编码 / 各自管几天）';


-- -----------------------------------------------------------------------------
-- ⑪ 不变量
--
-- 新增 95-99（套装侧），修订 34 / 43 / 69 / 72 / 75 / 84（受套装影响的旧条目）。
--
-- 修订的方式是「包一层」：新视图从旧视图里挑掉被改的那条，接上改过的那条。
-- 旧视图不动 —— 它是历史，改了就没法对照了。
-- -----------------------------------------------------------------------------

-- 95：形态唯一 —— 一个组合不许既是配方又是套装。
CREATE VIEW v_invariant_checks_bundle AS
WITH raw(seq, check_name, actual) AS (
    SELECT 95,
           '组合的供给形态不许既是配方又是套装',
           (SELECT count(*)
              FROM (SELECT svc.product_variant_id
                      FROM supplier_variant_composition svc
                     WHERE svc.status = 'active'
                       AND EXISTS (SELECT 1
                                     FROM supplier_variant_bundle svb
                                    WHERE svb.product_variant_id = svc.product_variant_id
                                      AND svb.status = 'active')
                     GROUP BY svc.product_variant_id) x)
    UNION ALL
    -- 96：套装成分与规范声明逐项对得上（不少、不多、份数一致）。
    SELECT 96,
           '套装的成分必须与规范声明逐项对得上',
           (SELECT count(*)
              FROM supplier_variant_bundle svb
             WHERE svb.status = 'active'
               AND ( (SELECT count(*) FROM supplier_variant_bundle_part p WHERE p.bundle_id = svb.id)
                     <> (SELECT count(*) FROM product_variant_relation r
                          WHERE r.parent_variant_id = svb.product_variant_id
                            AND r.relation_type = 'included')
                     OR EXISTS (SELECT 1
                                  FROM product_variant_relation r
                                 WHERE r.parent_variant_id = svb.product_variant_id
                                   AND r.relation_type = 'included'
                                   AND NOT EXISTS (SELECT 1
                                                     FROM supplier_variant_bundle_part p
                                                    WHERE p.bundle_id = svb.id
                                                      AND p.component_variant_id = r.child_variant_id
                                                      AND p.quantity = r.quantity)) ))
    UNION ALL
    -- 97：源侧整套有效期必须盖住规范侧承诺的窗口。
    SELECT 97,
           '套装的有效期必须盖住成分的有效期窗口',
           (SELECT count(*)
              FROM supplier_variant_bundle svb
             WHERE svb.status = 'active'
               AND svb.valid_days < fn_variant_validity_days(svb.product_variant_id))
    UNION ALL
    -- 98：成本分摊不丢钱 —— 各成分分摊之和精确等于整套成本。
    SELECT 98,
           '套装成本分摊必须精确等于套装成本',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND EXISTS (SELECT 1
                             FROM supplier_variant_bundle svb
                            WHERE svb.product_variant_id = oi.product_variant_id
                              AND svb.status = 'active')
               AND round(COALESCE((SELECT sum(s.unit_cost)
                                     FROM sales_order_item_source s
                                    WHERE s.order_item_id = oi.id), 0), 2)
                   IS DISTINCT FROM round(COALESCE(NULLIF(oi.detail_snapshot->>'cost_price','')::numeric, 0), 2))
    UNION ALL
    -- 99：入场份数守恒 —— 各成分的名额之和 = 套装声明的名额 × 套餐份数。
    SELECT 99,
           '套装订单的入场份数必须等于套装声明的份数乘套餐份数',
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND EXISTS (SELECT 1
                             FROM supplier_variant_bundle svb
                            WHERE svb.product_variant_id = oi.product_variant_id
                              AND svb.status = 'active')
               AND COALESCE((SELECT sum(s.admission_quantity)
                               FROM sales_order_item_source s
                              WHERE s.order_item_id = oi.id), 0)
                   IS DISTINCT FROM (SELECT COALESCE(sum(p.quantity), 0)
                                       FROM supplier_variant_bundle_part p
                                       JOIN supplier_variant_bundle svb2 ON svb2.id = p.bundle_id
                                      WHERE svb2.product_variant_id = oi.product_variant_id
                                        AND svb2.status = 'active') * oi.quantity)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_bundle IS
    '套装侧不变量（95-99）：形态唯一、成分与声明对得上、有效期盖得住、成本分摊守恒、入场份数守恒';

-- 34 与 43：套装有可履约源 —— 套装的源就是那个整套 SKU。
--
-- 34 与 43 都住在 v_invariant_checks_core 里（012 把原来的 core 改名成 supply，
-- 又按同一批 45 条重建了一个 core；总表用的是 core）。
-- 所以这两条修订都落在 core_017 上，供给侧那一份（supply）只是历史快照，不动。
CREATE VIEW v_invariant_checks_core_017 AS
WITH raw(seq, check_name, actual) AS (
    SELECT b.seq, b.check_name, b.actual
      FROM v_invariant_checks_core b
     WHERE b.seq NOT IN (34, 43)
    UNION ALL
    SELECT 34,
           '有售价的变体在其上架渠道必须至少有一个可履约源',
           ( SELECT count(*) AS count
                   FROM ( SELECT DISTINCT cl.channel_id,
                            pc.product_variant_id
                           FROM channel_listing cl
                             JOIN price_calendar pc ON pc.product_id = cl.product_id AND pc.channel_id IS NULL AND pc.status = 'active'::text
                          WHERE pc.product_variant_id IS NOT NULL AND pc.sell_price IS NOT NULL AND NOT (EXISTS ( SELECT 1
                                   FROM v_variant_routing_candidates vrc
                                  WHERE vrc.channel_id = cl.channel_id AND vrc.product_variant_id = pc.product_variant_id)) AND NOT (EXISTS ( SELECT 1
                                   FROM supplier_variant_bundle svb
                                  WHERE svb.product_variant_id = pc.product_variant_id AND svb.status = 'active'::text)) AND NOT ((EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text)) AND NOT (EXISTS ( SELECT 1
                                   FROM product_variant_relation r
                                  WHERE r.parent_variant_id = pc.product_variant_id AND r.relation_type = 'included'::text AND NOT (EXISTS ( SELECT 1
   FROM supplier_variant_mapping svm
  WHERE svm.product_variant_id = r.child_variant_id AND svm.status = 'active'::text AND fn_variant_covered(svm.coverage, r.child_variant_id))))))) x) AS count
    UNION ALL
    -- 43：套装的采纳源不是路由候选 —— 它是唯一的那一个源 SKU。
    --
    -- 豁免只给「采纳源就是套装那个源 SKU」的售价行：
    -- 套装的供给不走路由（它就是那一个 SKU），所以路由选不出它。
    -- 但如果售价行的采纳源是别的源，这条照样要红 —— 那说明定价与选源分叉了。
    SELECT 43,
           '定价采用的源必须是路由选中的源',
           (SELECT count(*)
              FROM price_calendar pc
             WHERE pc.status = 'active'
               AND pc.product_variant_id IS NOT NULL
               AND pc.cost_source_product_id IS DISTINCT FROM
                   ((SELECT rc.supplier_product_id
                       FROM fn_route_candidates(pc.product_variant_id, pc.date,
                                                COALESCE(pc.channel_id, fn_default_context_channel()),
                                                fn_price_row_currency(pc.channel_id)) rc(supplier_product_id, supplier_variant_id, source_currency, net_price, supplier_price, is_price_locked, source_min_margin, cost_base, fx_rate_to_target, fx_as_of, priority, fallback_order, route_rank)
                      WHERE rc.route_rank = 1))
               AND NOT EXISTS (SELECT 1
                                 FROM supplier_variant_bundle svb
                                 JOIN supplier_variant sv ON sv.id = svb.supplier_variant_id
                                                 AND sv.status = 'active'
                                WHERE svb.product_variant_id = pc.product_variant_id
                                  AND svb.status = 'active'
                                  AND sv.supplier_product_id = pc.cost_source_product_id))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

COMMENT ON VIEW v_invariant_checks_core_017 IS
    '核心 45 条（017 修订 34 与 43：套装有可履约源、套装有单一采纳源）';

-- 69：套装按套预占（一条预占，份数是套数）。
CREATE VIEW v_invariant_checks_inventory_017 AS
WITH raw(seq, check_name, actual) AS (
    SELECT b.seq, b.check_name, b.actual
      FROM v_invariant_checks_inventory b
     WHERE b.seq NOT IN (69, 72)
    UNION ALL
    SELECT 69,
           '每条订单明细都必须有对应的库存预占（组合按成分、套装按套）',
           -- 有成分行的明细：每一条成分行都要找到配得上的预占。
           --
           -- 套装的预占只有一条（份数是套数），配方与普通变体是一成分一条
           -- （份数是入场份数）。两种口径不许混：拿成分份数去比套数，
           -- 或者拿套数去比成分份数，都会判成「没预占」。
           --
           -- 口径与旧版一致：数的是「连一条成分都配不上预占的明细」。
           (SELECT count(*)
              FROM sales_order_item oi
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND NOT (EXISTS (
                     SELECT 1
                       FROM sales_order_item_source s
                      WHERE s.order_item_id = oi.id
                        AND (EXISTS (
                               SELECT 1
                                 FROM inventory_hold h
                                WHERE h.order_id = oi.order_id
                                  AND NOT h.product_session_id IS DISTINCT FROM s.product_session_id
                                  AND NOT h.supplier_id IS DISTINCT FROM s.supplier_id
                                  AND NOT h.supplier_session_id IS DISTINCT FROM s.supplier_session_id
                                  AND (
                                        -- 套装：一条预占，份数是套数
                                        (h.quantity = oi.quantity
                                         AND EXISTS (SELECT 1
                                                       FROM supplier_variant_bundle svb
                                                      WHERE svb.product_variant_id = oi.product_variant_id
                                                        AND svb.supplier_variant_id = s.supplier_variant_id
                                                        AND svb.status = 'active'))
                                     OR -- 普通与配方：一份成分一条预占
                                        (NOT h.ticket_type_id IS DISTINCT FROM s.ticket_type_id
                                         AND h.quantity::numeric = s.admission_quantity
                                         AND NOT EXISTS (SELECT 1
                                                           FROM supplier_variant_bundle svb
                                                          WHERE svb.product_variant_id = oi.product_variant_id
                                                            AND svb.supplier_variant_id = s.supplier_variant_id
                                                            AND svb.status = 'active'))
                                      ))))))
           -- 老明细（没有成分行）：一条明细一条预占
           + (SELECT count(*)
                FROM sales_order_item oi
               WHERE NOT (EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id))
                 AND NOT (EXISTS (SELECT 1
                                    FROM inventory_hold h
                                   WHERE h.order_id = oi.order_id
                                     AND NOT h.product_session_id IS DISTINCT FROM oi.session_id
                                     AND NOT h.ticket_type_id IS DISTINCT FROM oi.ticket_type_id
                                     AND NOT h.supplier_id IS DISTINCT FROM oi.supplier_id
                                     AND h.quantity = oi.quantity)))
    UNION ALL
    SELECT 72,
           '订单卖出的量不得超过落单时看到的源侧可售数（组合按成分、套装按套）',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN sales_order_item_source s ON s.order_item_id = oi.id
              LEFT JOIN LATERAL (
                    SELECT e.value AS ent
                      FROM jsonb_array_elements(COALESCE((oi.detail_snapshot->'availability')->'sources','[]'::jsonb)) e(value)
                     WHERE ((e.value->>'component_variant_id')::bigint) = s.component_variant_id
                       AND ((e.value->>'supplier_variant_id')::bigint) = s.supplier_variant_id
                     ORDER BY ((e.value->>'remaining_qty')::integer) NULLS FIRST
                     LIMIT 1) a ON true
             WHERE COALESCE((a.ent->>'known')::boolean, false) IS TRUE
               AND COALESCE((a.ent->>'remaining_qty')::integer, 0)::numeric
                   < CASE WHEN EXISTS (SELECT 1
                                         FROM supplier_variant_bundle svb
                                        WHERE svb.product_variant_id = oi.product_variant_id
                                          AND svb.supplier_variant_id = s.supplier_variant_id
                                          AND svb.status = 'active')
                          THEN oi.quantity::numeric
                          ELSE s.admission_quantity END)
           + (SELECT count(*)
                FROM sales_order_item oi
               WHERE NOT (EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id))
                 AND COALESCE(((oi.detail_snapshot->'availability')->>'known')::boolean, false) IS TRUE
                 AND COALESCE(((oi.detail_snapshot->'availability')->>'remaining_qty')::integer, 0) < oi.quantity)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

-- 75：套装的源就是那个整套 SKU（它覆盖的是整套，不是某一个成分）。
CREATE VIEW v_invariant_checks_validity_017 AS
WITH raw(seq, check_name, actual) AS (
    SELECT b.seq, b.check_name, b.actual
      FROM v_invariant_checks_validity b
     WHERE b.seq <> 75
    UNION ALL
    SELECT 75,
           '卖出去的订单必须是用能装配出该可售单元的源出的（组合按成分、套装按套装声明）',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN booking b ON b.order_item_id = oi.id
             WHERE b.supplier_variant_id IS NOT NULL
               AND NOT ( (EXISTS (SELECT 1
                                    FROM supplier_variant_mapping svm
                                   WHERE svm.supplier_variant_id = b.supplier_variant_id
                                     AND svm.product_variant_id = oi.product_variant_id
                                     AND svm.status = 'active'
                                     AND fn_variant_covered(svm.coverage, oi.product_variant_id)))
                         OR (EXISTS (SELECT 1
                                       FROM sales_order_item_source s
                                       JOIN supplier_variant_mapping svm ON svm.supplier_variant_id = b.supplier_variant_id
                                                                      AND svm.product_variant_id = s.component_variant_id
                                                                      AND svm.status = 'active'
                                      WHERE s.order_item_id = oi.id
                                        AND NOT s.supplier_variant_id IS DISTINCT FROM b.supplier_variant_id
                                        AND NOT s.supplier_session_id IS DISTINCT FROM b.supplier_session_id
                                        AND fn_variant_covered(svm.coverage, s.component_variant_id)))
                         OR (EXISTS (SELECT 1
                                       FROM supplier_variant_bundle svb
                                      WHERE svb.product_variant_id = oi.product_variant_id
                                        AND svb.supplier_variant_id = b.supplier_variant_id
                                        AND svb.status = 'active'))))
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

-- 84：套装的入场份数按套装声明算（不是按配方的声明算）。
CREATE VIEW v_invariant_checks_combo_017 AS
WITH raw(seq, check_name, actual) AS (
    SELECT b.seq, b.check_name, b.actual
      FROM v_invariant_checks_combo b
     WHERE b.seq <> 84
    UNION ALL
    SELECT 84,
           '订单明细的成分入场份数必须与配方（套装）声明对得上',
           (SELECT count(*)
              FROM sales_order_item oi
              JOIN product_variant pv ON pv.id = oi.product_variant_id
             WHERE EXISTS (SELECT 1 FROM sales_order_item_source s WHERE s.order_item_id = oi.id)
               AND COALESCE((SELECT sum(s.admission_quantity)
                               FROM sales_order_item_source s
                              WHERE s.order_item_id = oi.id), 0) IS DISTINCT FROM
                   CASE
                     WHEN EXISTS (SELECT 1
                                   FROM supplier_variant_bundle svb
                                  WHERE svb.product_variant_id = oi.product_variant_id
                                    AND svb.status = 'active')
                       THEN (SELECT COALESCE(sum(p.quantity), 0)
                               FROM supplier_variant_bundle_part p
                               JOIN supplier_variant_bundle svb2 ON svb2.id = p.bundle_id
                              WHERE svb2.product_variant_id = oi.product_variant_id
                                AND svb2.status = 'active') * oi.quantity::numeric
                     WHEN pv.variant_role = 'combo'
                       THEN (SELECT COALESCE(sum(r.quantity), 0)
                               FROM product_variant_relation r
                              WHERE r.parent_variant_id = oi.product_variant_id
                                AND r.relation_type = 'included') * oi.quantity::numeric
                     ELSE oi.quantity::numeric
                   END)
)
SELECT seq, check_name, 0::int AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
  FROM raw;

-- 总表：把修订后的子视图接进来，再加套装那五条。
CREATE OR REPLACE VIEW v_invariant_checks AS
SELECT v_invariant_checks_core_017.seq, v_invariant_checks_core_017.check_name,
       v_invariant_checks_core_017.expected, v_invariant_checks_core_017.actual,
       v_invariant_checks_core_017.passed, v_invariant_checks_core_017.result
  FROM v_invariant_checks_core_017
UNION ALL SELECT v_invariant_checks_tx.seq, v_invariant_checks_tx.check_name, v_invariant_checks_tx.expected, v_invariant_checks_tx.actual, v_invariant_checks_tx.passed, v_invariant_checks_tx.result FROM v_invariant_checks_tx
UNION ALL SELECT v_invariant_checks_order.seq, v_invariant_checks_order.check_name, v_invariant_checks_order.expected, v_invariant_checks_order.actual, v_invariant_checks_order.passed, v_invariant_checks_order.result FROM v_invariant_checks_order
UNION ALL SELECT v_invariant_checks_fulfill.seq, v_invariant_checks_fulfill.check_name, v_invariant_checks_fulfill.expected, v_invariant_checks_fulfill.actual, v_invariant_checks_fulfill.passed, v_invariant_checks_fulfill.result FROM v_invariant_checks_fulfill
UNION ALL SELECT v_invariant_checks_refund.seq, v_invariant_checks_refund.check_name, v_invariant_checks_refund.expected, v_invariant_checks_refund.actual, v_invariant_checks_refund.passed, v_invariant_checks_refund.result FROM v_invariant_checks_refund
UNION ALL SELECT v_invariant_checks_redemption.seq, v_invariant_checks_redemption.check_name, v_invariant_checks_redemption.expected, v_invariant_checks_redemption.actual, v_invariant_checks_redemption.passed, v_invariant_checks_redemption.result FROM v_invariant_checks_redemption
UNION ALL SELECT v_invariant_checks_inventory_017.seq, v_invariant_checks_inventory_017.check_name, v_invariant_checks_inventory_017.expected, v_invariant_checks_inventory_017.actual, v_invariant_checks_inventory_017.passed, v_invariant_checks_inventory_017.result FROM v_invariant_checks_inventory_017
UNION ALL SELECT v_invariant_checks_validity_017.seq, v_invariant_checks_validity_017.check_name, v_invariant_checks_validity_017.expected, v_invariant_checks_validity_017.actual, v_invariant_checks_validity_017.passed, v_invariant_checks_validity_017.result FROM v_invariant_checks_validity_017
UNION ALL SELECT v_invariant_checks_readmodel.seq, v_invariant_checks_readmodel.check_name, v_invariant_checks_readmodel.expected, v_invariant_checks_readmodel.actual, v_invariant_checks_readmodel.passed, v_invariant_checks_readmodel.result FROM v_invariant_checks_readmodel
UNION ALL SELECT v_invariant_checks_composition.seq, v_invariant_checks_composition.check_name, v_invariant_checks_composition.expected, v_invariant_checks_composition.actual, v_invariant_checks_composition.passed, v_invariant_checks_composition.result FROM v_invariant_checks_composition
UNION ALL SELECT v_invariant_checks_combo_017.seq, v_invariant_checks_combo_017.check_name, v_invariant_checks_combo_017.expected, v_invariant_checks_combo_017.actual, v_invariant_checks_combo_017.passed, v_invariant_checks_combo_017.result FROM v_invariant_checks_combo_017
UNION ALL SELECT v_invariant_checks_hardening.seq, v_invariant_checks_hardening.check_name, v_invariant_checks_hardening.expected, v_invariant_checks_hardening.actual, v_invariant_checks_hardening.passed, v_invariant_checks_hardening.result FROM v_invariant_checks_hardening
UNION ALL SELECT v_invariant_checks_bundle.seq, v_invariant_checks_bundle.check_name, v_invariant_checks_bundle.expected, v_invariant_checks_bundle.actual, v_invariant_checks_bundle.passed, v_invariant_checks_bundle.result FROM v_invariant_checks_bundle;

