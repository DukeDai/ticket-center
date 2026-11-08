-- =====================================================================================
-- 001_baseline.sql — 建库基线
-- =====================================================================================
-- 这是项目从 POC 走到正式项目时的结构快照。**一字不改地保留。**
--
-- 从这条规则起，物理模型只增不改：
--   - 要加列 / 加表 / 加索引 / 改函数 → 新增 db/migrations/NNN_*.sql，
--     用 ALTER TABLE ... ADD 演进，不要回头改这个文件；
--   - 迁移引擎把每个文件应用时的 sha256 记进账本 ops.schema_migration，
--     文件在应用后被改过 → 引擎拒绝继续跑。
--     「只增不改」因此是机制，不是约定。
--
-- 存量库接管（一个用旧脚本建出来、账本为空的库）：
--     tc-connect migrate --baseline 001
-- 引擎记下这个文件的校验和而不重跑它（结构本来就是它建出来的），
-- 然后接着应用后续迁移。
-- =====================================================================================

-- =====================================================================================
-- Ticket Center — 多源票券中心 物理模型
-- 目标库：PostgreSQL 15+   编码：UTF8
--
-- 设计要点（详见 docs/schema-design.md）：
--   1. 四层分离：规范层(Catalog) / 源层(Supply) / 映射层(Mapping) / 交易层(Transaction+Booking+Fulfillment)
--   2. 长尾属性进 jsonb + GIN 索引，热点筛选属性进强类型列或表达式索引
--   3. 源系统原样报文 raw_payload 全部归档，可回放、可对账、不断裂
--   4. 规范商品 ↔ 供应商商品 是多对多：一个商品多个源，一个源商品也可拆多个规范商品
--   5. 规范场次 product_session 与 源场次 supplier_session 解耦，支持跨源冗余与自动改派
--   6. 订单与"供应商预订"是两个聚合（不同一致性边界）：Order 用状态机 + Saga 驱动 Booking
--
-- 命名约定：
--   sales_*  交易域   | booking_*  预订域 | voucher_*  履约域 | settlement_*  结算域
--   supplier_* 供应域 | product/catalog_* 目录域 | channel_* 渠道域 | *_attr 属性
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 0. 基础设施
-- -------------------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- title 模糊检索

-- 统一 updated_at 维护
CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- =====================================================================================
-- 1. 集成域 Integration — 供应商接入、原始报文归档、同步作业
-- =====================================================================================

CREATE TABLE supplier (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code              TEXT NOT NULL,                       -- 唯一编码: ingresso/fonticket/goodfellows_jtb/globaltix/piaofutong
    name              TEXT NOT NULL,
    short_name        TEXT,
    country_code      CHAR(2),
    default_currency  CHAR(3) NOT NULL DEFAULT 'CNY',
    timezone          TEXT NOT NULL DEFAULT 'Asia/Shanghai',
    status            TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','inactive','suspended','onboarding')),
    api_base          TEXT,
    -- 凭据只存"引用"（Keychain/Vault/KMS 的 key），严禁明文密钥落库
    auth_config       JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 能力矩阵：声明该源支持哪些端口，前端/路由据此降级
    -- 例: {"product":true,"price":true,"session":true,"availability":"live","booking":true,
    --      "cancel":true,"validate":false,"partial_refund":false,"partial_booking":false}
    capability        JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 同步策略：{"catalog":"daily","price":"hourly","availability":"live","webhook":true}
    sync_policy       JSONB NOT NULL DEFAULT '{}'::jsonb,
    connector_version TEXT,
    contact           JSONB NOT NULL DEFAULT '{}'::jsonb,   -- 商务/技术联系人
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT supplier_code_uk UNIQUE (code)
);

COMMENT ON TABLE supplier IS '票券供应源（GDS/票务平台）注册表';
COMMENT ON COLUMN supplier.capability IS '能力矩阵：决定该源可参与哪些业务流（预订/改期/退票/核销）';
COMMENT ON COLUMN supplier.auth_config IS '凭据引用，禁止明文密钥';

CREATE TRIGGER trg_supplier_updated BEFORE UPDATE ON supplier
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 源系统原始报文归档：排障、对账、重放、字段漂移检测
CREATE TABLE supplier_raw_payload (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id  BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    entity_type  TEXT NOT NULL,      -- product/price/session/availability/booking/cancel/validate/refund/webhook
    entity_ref   TEXT,               -- 源侧对象 id
    direction    TEXT NOT NULL DEFAULT 'inbound' CHECK (direction IN ('inbound','outbound')),
    request      JSONB,
    response     JSONB,
    http_status  INT,
    latency_ms   INT,
    trace_id     TEXT,
    occurred_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_raw_supplier_entity ON supplier_raw_payload (supplier_id, entity_type, entity_ref, created_at DESC);
CREATE INDEX ix_raw_created       ON supplier_raw_payload (created_at DESC);
CREATE INDEX ix_raw_response_gin  ON supplier_raw_payload USING GIN (response jsonb_path_ops);

COMMENT ON TABLE supplier_raw_payload IS '源系统原样报文归档（inbound=源返回 / outbound=我们发出），支持重放与对账';

-- 同步作业日志：目录/价格/库存/预订状态轮询
CREATE TABLE sync_job_log (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    job_type    TEXT NOT NULL,       -- catalog_sync/price_sync/inventory_sync/booking_status_poll
    scope       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- 本次作业范围（商品/日期区间）
    status      TEXT NOT NULL DEFAULT 'running'
                CHECK (status IN ('running','success','partial','failed')),
    started_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    stats       JSONB NOT NULL DEFAULT '{}'::jsonb,   -- {"scanned":100,"created":3,"updated":7,"skipped":90,"failed":0}
    error       JSONB,
    CONSTRAINT sync_job_finished_ck CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX ix_syncjob_supplier ON sync_job_log (supplier_id, job_type, started_at DESC);

-- =====================================================================================
-- 2. 目录域 Catalog — 规范商品（与来源无关的主数据）
-- =====================================================================================

CREATE TABLE category (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       TEXT NOT NULL UNIQUE,
    name       TEXT NOT NULL,
    parent_id  BIGINT REFERENCES category(id) ON DELETE SET NULL,
    path       TEXT,                -- 物化路径 /category/1/7
    level      INT NOT NULL DEFAULT 1,
    sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE city (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         TEXT NOT NULL UNIQUE,
    name         TEXT NOT NULL,
    country_code CHAR(2),
    longitude    NUMERIC(10,7),
    latitude     NUMERIC(10,7),
    timezone     TEXT NOT NULL DEFAULT 'Asia/Shanghai'
);

CREATE TABLE product (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_code     TEXT NOT NULL UNIQUE,      -- 对内 SKU
    title            TEXT NOT NULL,
    subtitle         TEXT,
    description      TEXT,
    category_id      BIGINT REFERENCES category(id) ON DELETE SET NULL,
    city_id          BIGINT REFERENCES city(id) ON DELETE SET NULL,
    country_code     CHAR(2),
    product_type     TEXT NOT NULL DEFAULT 'ticket'
                     CHECK (product_type IN ('ticket','package','pass','voucher','accommodation','transport','service')),
    status           TEXT NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','active','inactive','discontinued')),
    -- 归一化指纹：用于跨源自动聚类（标题+地点+品类+时长 的稳定哈希）
    canonical_key    TEXT,
    -- 规范化长尾属性：{"duration_minutes":120,"age_limit":{"min":3},"includes":["guide"]}
    -- 这是"半 SQL"的核心：结构化可查 + 不锁 schema
    attributes       JSONB NOT NULL DEFAULT '{}'::jsonb,
    fulfilment_type  TEXT NOT NULL DEFAULT 'ticket_code'
                     CHECK (fulfilment_type IN ('ticket_code','qr_pickup','ntc','digital_voucher','physical')),
    -- 使用与有效期规则：{"validity":"session_date","valid_days":null,"single_use":true}
    validity_rule    JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 退改规则：{"refundable":true,"cutoff_hours":48,"fees":[...]}
    refund_policy    JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 注意事项/内嵌规则文本（供应商条款）
    terms            JSONB NOT NULL DEFAULT '{}'::jsonb,
    rating           NUMERIC(3,2),
    review_count     INT NOT NULL DEFAULT 0,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_product_status      ON product (status);
CREATE INDEX ix_product_category    ON product (category_id);
CREATE INDEX ix_product_city        ON product (city_id);
CREATE INDEX ix_product_canonical   ON product (canonical_key);
-- 长尾属性检索：jsonb_path_ops 比默认 GIN 小且支持 @> 包含查询
CREATE INDEX ix_product_attr_gin    ON product USING GIN (attributes jsonb_path_ops);
CREATE INDEX ix_product_title_trgm  ON product USING GIN (title gin_trgm_ops);
COMMENT ON INDEX ix_product_attr_gin IS '规范化属性 GIN 索引：支持 attributes @> ''{"age_limit":{"min":3}}'' 这类包含查询';

CREATE TRIGGER trg_product_updated BEFORE UPDATE ON product
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 属性字典：驱动 B 端动态筛选表单 / C 端筛选器，避免前端硬编码
CREATE TABLE attribute_definition (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code          TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    data_type     TEXT NOT NULL CHECK (data_type IN ('string','text','number','bool','date','enum','duration','json')),
    unit          TEXT,
    scope         TEXT NOT NULL DEFAULT 'product' CHECK (scope IN ('product','session','listing','ticket_type')),
    is_filterable BOOLEAN NOT NULL DEFAULT false,
    is_searchable BOOLEAN NOT NULL DEFAULT false,
    is_multi      BOOLEAN NOT NULL DEFAULT false,   -- 多值属性
    enum_values   JSONB,                            -- [{"value":"half_day","label":"半日游"}]
    min_value     NUMERIC,
    max_value     NUMERIC,
    sort_order    INT NOT NULL DEFAULT 0,
    status        TEXT NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE attribute_definition IS '属性字典：source-agnostic 的属性元数据，驱动动态筛选与字段映射';

-- 源字段 → 规范属性的映射规则（配置驱动归一化，不写死在代码里）
CREATE TABLE attribute_mapping_rule (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    attribute_code    TEXT NOT NULL REFERENCES attribute_definition(code) ON UPDATE CASCADE,
    supplier_id       BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    source_path       TEXT NOT NULL,   -- JSONPath，如 $.items[0].attributes.duration
    target_path       TEXT,            -- 写入 product.attributes 的路径，留空=属性 code
    transform         JSONB NOT NULL DEFAULT '{}'::jsonb, -- {"type":"minutes","from":"hours"}
    default_value     JSONB,
    priority          INT NOT NULL DEFAULT 100,
    enabled           BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT attr_map_uk UNIQUE (supplier_id, attribute_code, source_path)
);
COMMENT ON TABLE attribute_mapping_rule IS '源报文到规范属性的映射规则，归一化逻辑配置化、可热改';

CREATE TABLE product_translation (
    product_id  BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    locale      TEXT NOT NULL,          -- zh-CN/en-US/pt-BR/ja-JP
    title       TEXT,
    subtitle    TEXT,
    description TEXT,
    terms       JSONB NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (product_id, locale)
);

CREATE TABLE product_media (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    media_type  TEXT NOT NULL DEFAULT 'image' CHECK (media_type IN ('image','video','panorama','doc')),
    url         TEXT NOT NULL,
    thumbnail   TEXT,
    caption     TEXT,
    sort_order  INT NOT NULL DEFAULT 0,
    width       INT,
    height      INT,
    is_primary  BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX ix_media_product ON product_media (product_id, sort_order);

-- =====================================================================================
-- 3. 供应域 Supply — 源商品、源票种、源场次（源系统"原样"模型）
-- =====================================================================================

CREATE TABLE supplier_product (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id       BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    external_id       TEXT NOT NULL,       -- 源侧商品 id
    external_code     TEXT,                -- 源侧 sku/code
    external_url      TEXT,
    raw_title         TEXT,
    raw_payload       JSONB NOT NULL DEFAULT '{}'::jsonb,  -- 源侧商品原始报文
    source_attributes JSONB NOT NULL DEFAULT '{}'::jsonb,  -- 源侧未归一化属性
    -- 库存/价格获取方式：live=实时查 API；pull_sync=定时拉取落库；push=源推送；static=固定
    availability_mode TEXT NOT NULL DEFAULT 'live'
                      CHECK (availability_mode IN ('live','pull_sync','push','static')),
    content_hash      TEXT,                -- 源报文哈希，用于变更检测
    status            TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','inactive','discontinued','pending_review')),
    last_synced_at    TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT supplier_product_uk UNIQUE (supplier_id, external_id)
);
CREATE INDEX ix_sp_supplier    ON supplier_product (supplier_id, status);
CREATE INDEX ix_sp_hash        ON supplier_product (supplier_id, content_hash);
CREATE INDEX ix_sp_payload_gin ON supplier_product USING GIN (raw_payload jsonb_path_ops);
CREATE INDEX ix_sp_attr_gin    ON supplier_product USING GIN (source_attributes jsonb_path_ops);

CREATE TRIGGER trg_supplier_product_updated BEFORE UPDATE ON supplier_product
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE supplier_product IS '源商品：各 GDS 的原样商品，不做归一化，是映射与对账的锚点';

-- 源票种（成人/儿童/家庭…），源命名各不相同
CREATE TABLE supplier_ticket_type (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    external_id         TEXT NOT NULL,
    name                TEXT,
    name_en             TEXT,
    description         TEXT,
    age_rule            JSONB NOT NULL DEFAULT '{}'::jsonb,  -- {"min_age":12,"max_age":null,"height_cm":null}
    is_optional         BOOLEAN NOT NULL DEFAULT false,   -- 附加项而非默认票种
    raw_payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT supplier_ticket_type_uk UNIQUE (supplier_product_id, external_id)
);

-- 源场次（出发批次/使用日期/时段）
CREATE TABLE supplier_session (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    supplier_ticket_type_id BIGINT REFERENCES supplier_ticket_type(id) ON DELETE CASCADE,
    external_id         TEXT NOT NULL,
    session_date        DATE,
    start_at            TIMESTAMPTZ,
    end_at              TIMESTAMPTZ,
    timezone            TEXT NOT NULL DEFAULT 'Asia/Shanghai',
    local_start_label   TEXT,             -- 源侧原始时间文本，如 "09:30" / "Morning"
    meeting_point       TEXT,
    address             TEXT,
    latitude            NUMERIC(10,7),
    longitude           NUMERIC(10,7),
    capacity            INT,
    status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','sold_out','cancelled','unavailable','pending')),
    raw_payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT supplier_session_uk UNIQUE (supplier_product_id, external_id)
);
CREATE INDEX ix_ss_product_date ON supplier_session (supplier_product_id, session_date);
CREATE INDEX ix_ss_start          ON supplier_session (start_at);

COMMENT ON TABLE supplier_session IS '源场次：各源的"出发批次/使用日期"模型差异极大，在此原样保存';

-- =====================================================================================
-- 4. 映射层 Mapping — 规范商品 ↔ 源商品
-- =====================================================================================

CREATE TABLE product_mapping (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    supplier_id         BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    product_id          BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    match_type          TEXT NOT NULL DEFAULT 'manual'
                        CHECK (match_type IN ('auto','rule','manual','inferred')),
    confidence          NUMERIC(4,3) CHECK (confidence >= 0 AND confidence <= 1),
    -- 判定依据：{"signals":["title_similarity:0.91","same_geo:ok"],"decided_by":"ops@x"}
    match_evidence      JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 该源商品在此规范商品下是否为主源（其余为备源，用于冗余改派）
    is_primary          BOOLEAN NOT NULL DEFAULT false,
    status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','pending_review','rejected')),
    created_by          TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT product_mapping_uk UNIQUE (supplier_product_id, product_id)
);
CREATE INDEX ix_map_product  ON product_mapping (product_id, status);
CREATE INDEX ix_map_primary  ON product_mapping (product_id) WHERE is_primary;
-- 一个规范商品在同一个供应商下最多只能有一个主源（其余为备源/改派）
CREATE UNIQUE INDEX ux_map_single_primary
    ON product_mapping (product_id, supplier_id) WHERE is_primary;

COMMENT ON TABLE product_mapping IS '跨源归一化映射：多对多，允许一个源商品拆成多个规范商品（打包拆分场景）';

CREATE TRIGGER trg_product_mapping_updated BEFORE UPDATE ON product_mapping
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 规范票种（对客展示的规格：成人票/儿童票/家庭票）
CREATE TABLE ticket_type (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    description TEXT,
    age_rule    JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 库存口径：per_session=每场次库存；per_product=全商品池；unlimited=不限量
    stock_mode  TEXT NOT NULL DEFAULT 'per_session'
                CHECK (stock_mode IN ('per_session','per_product','unlimited')),
    sort_order  INT NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active',
    CONSTRAINT ticket_type_uk UNIQUE (product_id, code)
);

-- 源票种 ↔ 规范票种
CREATE TABLE ticket_type_mapping (
    supplier_ticket_type_id BIGINT NOT NULL REFERENCES supplier_ticket_type(id) ON DELETE CASCADE,
    ticket_type_id          BIGINT NOT NULL REFERENCES ticket_type(id) ON DELETE CASCADE,
    -- 价格修正：{"factor":1.0,"add":0,"currency":"CNY"}（源价换算到规范价）
    price_adjustment        JSONB NOT NULL DEFAULT '{}'::jsonb,
    quantity_multiplier     NUMERIC(6,3) NOT NULL DEFAULT 1,  -- 1 张源票 = N 张规范票（如家庭票=4人）
    PRIMARY KEY (supplier_ticket_type_id, ticket_type_id)
);

-- =====================================================================================
-- 5. 规范场次（跨源统一的可售单元）
-- =====================================================================================

CREATE TABLE product_session (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id    BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    session_date  DATE NOT NULL,
    slot_key      TEXT NOT NULL DEFAULT 'default',  -- 时段键：morning/afternoon/09:30
    start_at      TIMESTAMPTZ,
    end_at        TIMESTAMPTZ,
    timezone      TEXT NOT NULL DEFAULT 'Asia/Shanghai',
    meeting_point TEXT,
    status        TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','sold_out','cancelled','hidden','pending')),
    min_adult     INT NOT NULL DEFAULT 1,
    max_adult     INT,
    max_child     INT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT product_session_uk UNIQUE (product_id, session_date, slot_key)
);
CREATE INDEX ix_ps_product_date ON product_session (product_id, session_date, status);

CREATE TRIGGER trg_product_session_updated BEFORE UPDATE ON product_session
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 规范场次 ← 源场次：一个源场次可支撑多个规范时段（上午/下午拆分），也可反之
CREATE TABLE product_session_source (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_session_id  BIGINT NOT NULL REFERENCES product_session(id) ON DELETE CASCADE,
    supplier_session_id BIGINT NOT NULL REFERENCES supplier_session(id) ON DELETE CASCADE,
    supplier_id         BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    role                TEXT NOT NULL DEFAULT 'primary'
                        CHECK (role IN ('primary','backup','fallback')),
    price_overlay       JSONB NOT NULL DEFAULT '{}'::jsonb,
    priority            INT NOT NULL DEFAULT 100,   -- 路由优先级，越小越优先
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pss_uk UNIQUE (product_session_id, supplier_session_id)
);
CREATE INDEX ix_pss_supplier ON product_session_source (supplier_id, role);

COMMENT ON TABLE product_session_source IS '多源冗余的核心：同一可售场次可由多个源供给，支持失败自动改派';

-- =====================================================================================
-- 6. 价格与库存 Pricing & Inventory
-- =====================================================================================

-- 6.1 源侧成本价日历（供应域）—— 多源比价的数据基础，一行 = 一个源在一个日期上的报价
CREATE TABLE supplier_price_calendar (
    id                      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_product_id     BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    supplier_ticket_type_id BIGINT REFERENCES supplier_ticket_type(id) ON DELETE CASCADE,
    supplier_session_id     BIGINT REFERENCES supplier_session(id) ON DELETE CASCADE,
    product_id              BIGINT REFERENCES product(id) ON DELETE CASCADE,  -- 冗余映射结果，便于跨源横向对比
    date                    DATE NOT NULL,
    currency                CHAR(3) NOT NULL DEFAULT 'CNY',
    supplier_price          NUMERIC(12,2),   -- 源侧挂牌价
    net_price               NUMERIC(12,2),   -- 源侧结算净价（扣佣金/税后）
    tax                     NUMERIC(12,2),
    min_qty                 INT,
    max_qty                 INT,
    status                  TEXT NOT NULL DEFAULT 'available'
                            CHECK (status IN ('available','sold_out','closed','on_request')),
    synced_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
    raw_payload             JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE UNIQUE INDEX ux_spc_scope
    ON supplier_price_calendar (supplier_product_id, date,
                                COALESCE(supplier_ticket_type_id, 0), COALESCE(supplier_session_id, 0));
CREATE INDEX ix_spc_product_date ON supplier_price_calendar (product_id, date);
CREATE INDEX ix_spc_src_date     ON supplier_price_calendar (supplier_product_id, date, status);

COMMENT ON TABLE supplier_price_calendar IS '源成本价日历：多源比价与自动路由选源的依据';

-- 6.1b 汇率快照：跨币种源（EUR/BRL/JPY/HKD）与基准币种成本换算
CREATE TABLE fx_rate (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_currency  CHAR(3) NOT NULL,     -- 基准币种（如 CNY）
    quote_currency CHAR(3) NOT NULL,     -- 目标币种（如 EUR）
    rate           NUMERIC(18,8) NOT NULL CHECK (rate > 0),  -- 1 base = rate quote
    as_of_date     DATE NOT NULL,
    source         TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fx_rate_uk UNIQUE (base_currency, quote_currency, as_of_date)
);
CREATE INDEX ix_fx_lookup ON fx_rate (base_currency, quote_currency, as_of_date DESC);

COMMENT ON TABLE fx_rate IS '汇率快照：rate 表示 1 base_currency = rate quote_currency；换算到基准币种用除法。跨币种比价必须落到同一基准币种，否则成本不可比';

-- -------------------------------------------------------------------------------------
-- 6.1b 基准币种配置与汇率折算口径
--
-- 原来三个视图各自硬编码 'CNY'，取汇率一律 ORDER BY as_of_date DESC LIMIT 1：
--   1) 缺快照时 COALESCE(rate, 1) 把外币当成本币 —— 比价结果直接是错的；
--      新币种上线当天没配汇率，价格就会以 1:1 参与比价，选出一个「便宜到不可能」的源。
--   2) 取「最新」快照意味着昨天算出来的成本今天会变 —— 成本不可复现、不可对账。
--
-- 现在口径收敛到三个函数，别处不再各自查汇率：
--   fn_base_currency()          基准币种，单一事实来源
--   fn_fx_rate(quote, as_of)    1 基准币种 = ? 外币；取 as_of 当日或之前最近的一份快照
--   fn_convert(amount, from, to) 跨币种折算；缺快照返回 NULL，调用方必须拒绝比价
-- -------------------------------------------------------------------------------------
CREATE TABLE app_setting (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    description TEXT,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_app_setting_updated BEFORE UPDATE ON app_setting
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
COMMENT ON TABLE app_setting IS '全局配置：基准币种等口径参数的唯一来源';

-- 基准币种。没配就退回 CNY，但正常路径由 db/seed.sql 写入。
CREATE FUNCTION fn_base_currency() RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
           (SELECT TRIM(value) FROM app_setting WHERE key = 'base_currency'),
           'CNY');
$$;

-- 1 基准币种 = fn_fx_rate(...) 外币。
--   quote 等于基准币种 → 恒为 1（不需要快照）。
--   否则取 as_of 当日或之前最近的一份快照；没有 → NULL。
--   NULL 的含义是「不可比」，调用方必须把它排除在比价之外，不得兜底成 1。
--
-- 折算方向：外币 → 基准币种是除以它，基准币种 → 外币是乘以它。
CREATE FUNCTION fn_fx_rate(p_quote TEXT, p_as_of DATE) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_quote IS NULL OR p_as_of IS NULL THEN NULL
           WHEN TRIM(p_quote) = fn_base_currency() THEN 1
           ELSE (SELECT r.rate
                   FROM fx_rate r
                  WHERE r.base_currency = fn_base_currency()
                    AND TRIM(r.quote_currency) = TRIM(p_quote)
                    AND r.as_of_date <= p_as_of
                  ORDER BY r.as_of_date DESC
                  LIMIT 1)
         END;
$$;

-- 跨币种折算。任一环节缺快照 → NULL（不可比）。
CREATE FUNCTION fn_convert(p_amount NUMERIC, p_from TEXT, p_to TEXT, p_as_of DATE) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_amount IS NULL THEN NULL
           WHEN TRIM(p_from) = TRIM(p_to) THEN p_amount
           ELSE p_amount / fn_fx_rate(p_from, p_as_of) * fn_fx_rate(p_to, p_as_of)
         END;
$$;

-- 折算实际用的那份快照是哪天的。基准币种不需要快照，返回 NULL。
CREATE FUNCTION fn_fx_snapshot_date(p_quote TEXT, p_as_of DATE) RETURNS DATE
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_quote IS NULL OR p_as_of IS NULL THEN NULL
           WHEN TRIM(p_quote) = fn_base_currency() THEN NULL
           ELSE (SELECT r.as_of_date
                   FROM fx_rate r
                  WHERE r.base_currency = fn_base_currency()
                    AND TRIM(r.quote_currency) = TRIM(p_quote)
                    AND r.as_of_date <= p_as_of
                  ORDER BY r.as_of_date DESC
                  LIMIT 1)
         END;
$$;

-- 一币种对的折算因子：1 单位源币种 = ? 单位目标币种。
--
-- 折算经基准币种中转：1 base = rate(quote)，所以 from → to = rate(to) / rate(from)。
-- 两端币种相同 → 不需要折算，因子是 1（不碰汇率表，也不留快照）。
CREATE FUNCTION fn_fx_pair_rate(p_from TEXT, p_to TEXT, p_as_of DATE) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_from IS NULL OR p_to IS NULL OR p_as_of IS NULL THEN NULL
           WHEN TRIM(p_from) = TRIM(p_to) THEN 1
           ELSE fn_convert(1, p_from, p_to, p_as_of)
         END;
$$;

-- 这一折算实际依赖的汇率快照是哪一天。
--
-- 经基准币种中转，最多依赖两份快照：源腿（from）与目标腿（to）。基准币种那一腿不需要快照。
-- 同币种不折算 → 没有快照 → NULL。
--
-- 两腿都有快照时取较晚的那一天（M = max(A, B)）。取较晚是安全的：
--   A、B 都是「原 as_of 当日或之前最近的一份」，M ≤ as_of，
--   所以 (A, M] 与 (B, M] 之间不可能夹着别的快照 ——
--   用 M 重算，任一腿选中的还是原来那一份，因子逐位相同。
-- 这条性质让留痕日期可以独立复算：拿 fx_as_of 回去重算，不必再问原始价格日期。
CREATE FUNCTION fn_fx_pair_snapshot_date(p_from TEXT, p_to TEXT, p_as_of DATE) RETURNS DATE
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN p_from IS NULL OR p_to IS NULL OR p_as_of IS NULL THEN NULL
           WHEN TRIM(p_from) = TRIM(p_to) THEN NULL
           ELSE GREATEST(fn_fx_snapshot_date(p_from, p_as_of),
                         fn_fx_snapshot_date(p_to, p_as_of))
         END;
$$;

-- 读一个布尔型全局开关。没配就用默认值。
CREATE FUNCTION fn_bool_setting(p_key TEXT, p_default BOOLEAN) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
           (SELECT (value::boolean) FROM app_setting WHERE key = p_key),
           p_default);
$$;


-- 6.2 对客售价日历（定价域）—— 与源成本解耦，定价策略只作用在售价侧
CREATE TABLE price_calendar (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id     BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    session_id     BIGINT REFERENCES product_session(id) ON DELETE CASCADE,
    ticket_type_id BIGINT REFERENCES ticket_type(id) ON DELETE CASCADE,
    channel_id     BIGINT,   -- 渠道级覆盖价（FK 在 channel 建表后补，见 section 7）
    date           DATE NOT NULL,
    currency       CHAR(3) NOT NULL DEFAULT 'CNY',
    cost_price     NUMERIC(12,2),    -- 采纳的最优成本（由源成本价派生，冗余留痕）
    cost_source_product_id BIGINT REFERENCES supplier_product(id) ON DELETE SET NULL,  -- 成本取自哪个源
    sell_price     NUMERIC(12,2),    -- 对客售价
    list_price     NUMERIC(12,2),    -- 划线价
    discount_pct   NUMERIC(5,2),
    -- 定价规则：{"markup":"percent","value":12,"floor":null,"cap":null}
    rule           JSONB NOT NULL DEFAULT '{}'::jsonb,
    status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','closed')),
    source         TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','sync','calc')),
    synced_at      TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- channel_id / ticket_type_id 可空 → 用表达式唯一索引规避 NULL 不去重
CREATE UNIQUE INDEX ux_price_scope
    ON price_calendar (product_id, date, COALESCE(ticket_type_id, 0), COALESCE(channel_id, 0), COALESCE(session_id, 0));
CREATE INDEX ix_price_date     ON price_calendar (date, status);
CREATE INDEX ix_price_product  ON price_calendar (product_id, date);

CREATE TRIGGER trg_price_calendar_updated BEFORE UPDATE ON price_calendar
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE price_calendar IS '对客售价日历：渠道覆盖价 + 定价规则；成本价取自 supplier_price_calendar 的最优源';

-- 库存快照（同步落库的库存）
CREATE TABLE inventory_snapshot (
    id                    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_session_id   BIGINT NOT NULL REFERENCES supplier_session(id) ON DELETE CASCADE,
    supplier_ticket_type_id BIGINT REFERENCES supplier_ticket_type(id) ON DELETE CASCADE,
    session_date          DATE,
    available_qty         INT,
    held_qty              INT,     -- 锁座/占位
    sold_qty              INT,
    status                TEXT NOT NULL DEFAULT 'unknown'
                          CHECK (status IN ('available','sold_out','limited','blocked','unknown')),
    raw_payload           JSONB NOT NULL DEFAULT '{}'::jsonb,
    captured_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_inv_session_time ON inventory_snapshot (supplier_session_id, captured_at DESC);
CREATE INDEX ix_inv_latest      ON inventory_snapshot (supplier_session_id, supplier_ticket_type_id, captured_at DESC)
    WHERE supplier_ticket_type_id IS NOT NULL;

-- 实时可用性缓存（live 模式的短 TTL 缓存，避免打爆源 API）
CREATE TABLE availability_cache (
    cache_key       TEXT PRIMARY KEY,   -- hash(supplier_id|product_id|date|slot|ticket_type)
    supplier_id     BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    supplier_product_id BIGINT REFERENCES supplier_product(id) ON DELETE CASCADE,
    supplier_session_id BIGINT REFERENCES supplier_session(id) ON DELETE CASCADE,
    product_id      BIGINT REFERENCES product(id) ON DELETE CASCADE,
    session_date    DATE,
    available_qty   INT,
    status          TEXT,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at      TIMESTAMPTZ NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_avcache_expiry ON availability_cache (expires_at);

COMMENT ON TABLE availability_cache IS '实时可用性短 TTL 缓存 + 熔断计数（降级时回落到库存快照）';

-- =====================================================================================
-- 7. 渠道域 Channel — B 端 / C 端 上架与路由
-- =====================================================================================

CREATE TABLE channel (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             TEXT NOT NULL UNIQUE,
    name             TEXT NOT NULL,
    -- b2c_own=自有C端; b2b_distributor=B端分销; supplier_direct=供应商直销; corporate=企业客户; package=打包渠道
    channel_type     TEXT NOT NULL CHECK (channel_type IN ('b2c_own','b2b_distributor','supplier_direct','corporate','package','op_internal')),
    settlement_mode  TEXT NOT NULL DEFAULT 'prepaid' CHECK (settlement_mode IN ('prepaid','postpaid','credit','consignment')),
    commission_rate  NUMERIC(6,4) NOT NULL DEFAULT 0,
    default_currency CHAR(3) NOT NULL DEFAULT 'CNY',
    tax_policy       JSONB NOT NULL DEFAULT '{}'::jsonb,
    status           TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','suspended')),
    config           JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_channel_updated BEFORE UPDATE ON channel
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 补齐 price_calendar 的渠道外键（price_calendar 早于 channel 定义）
ALTER TABLE price_calendar
    ADD CONSTRAINT fk_price_calendar_channel
    FOREIGN KEY (channel_id) REFERENCES channel(id) ON DELETE CASCADE;

COMMENT ON TABLE channel IS '销售渠道：B端分销与C端自营共用同一套商品/价格/库存模型，靠 channel 隔离';

CREATE TABLE channel_listing (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id          BIGINT NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    product_id          BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    status              TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft','online','offline','sold_out','expired')),
    title_override      TEXT,
    subtitle_override   TEXT,
    description_override TEXT,
    -- 定价策略：{"mode":"cost_plus","percent":15,"min_margin":0.05,"rounding":1}
    price_policy        JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 库存策略：{"mode":"full","limit":null,"sell_through":null}
    stock_policy        JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 预订策略：{"mode":"instant","confirm_deadline_min":30,"need_deposit":false}
    booking_policy      JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 退款策略覆盖
    refund_policy_override JSONB NOT NULL DEFAULT '{}'::jsonb,
    min_order_qty       INT NOT NULL DEFAULT 1,
    max_order_qty       INT,
    sort_weight         INT NOT NULL DEFAULT 0,
    published_at        TIMESTAMPTZ,
    offline_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT channel_listing_uk UNIQUE (channel_id, product_id),
    CONSTRAINT channel_listing_qty_ck CHECK (min_order_qty >= 1 AND (max_order_qty IS NULL OR max_order_qty >= min_order_qty))
);
CREATE INDEX ix_listing_online ON channel_listing (channel_id, status, sort_weight);

CREATE TRIGGER trg_channel_listing_updated BEFORE UPDATE ON channel_listing
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- 渠道商品的货源绑定：多源冗余 / 自动比价改派
CREATE TABLE channel_listing_source (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_listing_id  BIGINT NOT NULL REFERENCES channel_listing(id) ON DELETE CASCADE,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    supplier_id         BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    priority            INT NOT NULL DEFAULT 100,   -- 越小越优先
    fallback_order      INT,                        -- 主源失败后的改派次序
    cost_override       NUMERIC(12,2),
    min_margin          NUMERIC(6,4),
    max_daily_qty       INT,                        -- 该源每日配额（部分源有限量）
    enabled             BOOLEAN NOT NULL DEFAULT true,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT cls_uk UNIQUE (channel_listing_id, supplier_product_id)
);
CREATE INDEX ix_cls_route ON channel_listing_source (channel_listing_id, enabled, priority);

COMMENT ON TABLE channel_listing_source IS '路由表：一次下单命中哪个源，按 priority + fallback_order 决策';

-- 售价行的结算币种：渠道专属行用该渠道的结算币种，默认行（channel_id IS NULL）用基准币种。
--
-- 「这一行该按哪个币种定价」以前散在三个地方（fn_price_variant 里的 CASE、
-- seed.sql 手写的 currency 字面量、演练器自己判断），三处可以各写各的。
-- 现在只有一个来源：币种由渠道决定，不由谁记得手填。
CREATE FUNCTION fn_price_row_currency(p_channel_id BIGINT) RETURNS TEXT
LANGUAGE sql STABLE AS $$
  SELECT CASE
           -- 0 与 NULL 都表示「没有渠道专属行」= 默认行（基准币种）。
           -- 调用方用 0 当哨兵（Go 侧 int64 零值），SQL 侧用 NULL；
           -- 两个哨兵都收，省得谁把 0 当成真渠道 id，结算币种就查成了 NULL。
           WHEN p_channel_id IS NULL OR p_channel_id = 0 THEN fn_base_currency()
           ELSE (SELECT TRIM(ch.default_currency) FROM channel ch WHERE ch.id = p_channel_id)
         END;
$$;

-- 默认售价行（channel_id IS NULL）归 C 端自营渠道：规则与可选源都取自它的上架关系。
-- 「默认行属于哪个渠道」以前是口头约定，现在由这张表决定，不再靠某个人记得 channel 1。
CREATE FUNCTION fn_default_context_channel() RETURNS BIGINT
LANGUAGE sql STABLE AS $$
    SELECT id
      FROM channel
     WHERE channel_type = 'b2c_own'
       AND status = 'active'
     ORDER BY id
     LIMIT 1
$$;

-- =====================================================================================
-- 8. 交易域 Transaction — 订单
-- =====================================================================================

CREATE TABLE customer (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_id   BIGINT REFERENCES channel(id) ON DELETE SET NULL,
    customer_type TEXT NOT NULL DEFAULT 'c' CHECK (customer_type IN ('c','b','anonymous')),
    member_code  TEXT,
    name         TEXT,
    email        TEXT,
    phone        TEXT,
    country_code CHAR(2),
    locale       TEXT,
    metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT customer_member_uk UNIQUE (member_code)
);

CREATE TABLE sales_order (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_no            TEXT NOT NULL UNIQUE,
    channel_id          BIGINT NOT NULL REFERENCES channel(id),
    customer_id         BIGINT REFERENCES customer(id) ON DELETE SET NULL,
    status              TEXT NOT NULL DEFAULT 'created'
                        CHECK (status IN ('created','awaiting_payment','paid','booking_pending','confirmed',
                                          'partially_fulfilled','fulfilled','cancelled','expired','failed',
                                          'refunding','refunded')),
    payment_status      TEXT NOT NULL DEFAULT 'unpaid'
                        CHECK (payment_status IN ('unpaid','paid','partially_paid','refunded','failed')),
    fulfillment_status  TEXT NOT NULL DEFAULT 'unfulfilled'
                        CHECK (fulfillment_status IN ('unfulfilled','partial','fulfilled','cancelled','failed')),
    currency            CHAR(3) NOT NULL DEFAULT 'CNY',
    subtotal            NUMERIC(12,2) NOT NULL DEFAULT 0,
    discount            NUMERIC(12,2) NOT NULL DEFAULT 0,
    tax                 NUMERIC(12,2) NOT NULL DEFAULT 0,
    total               NUMERIC(12,2) NOT NULL DEFAULT 0,
    cost_total          NUMERIC(12,2) NOT NULL DEFAULT 0,
    commission_amount   NUMERIC(12,2) NOT NULL DEFAULT 0,
    -- 下单瞬间的定价/商品快照（历史不可变，不依赖当前表状态）
    pricing_snapshot    JSONB NOT NULL DEFAULT '{}'::jsonb,
    contact_snapshot    JSONB NOT NULL DEFAULT '{}'::jsonb,
    idempotency_key     TEXT,
    buyer_note          TEXT,
    internal_note       TEXT,
    placed_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at          TIMESTAMPTZ,
    confirmed_at        TIMESTAMPTZ,
    completed_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sales_order_money_ck CHECK (total >= 0 AND subtotal >= 0),
    CONSTRAINT sales_order_time_ck CHECK (completed_at IS NULL OR completed_at >= placed_at)
);
CREATE UNIQUE INDEX ux_order_idem ON sales_order (channel_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX ix_order_status   ON sales_order (status, placed_at DESC);
CREATE INDEX ix_order_channel  ON sales_order (channel_id, placed_at DESC);
CREATE INDEX ix_order_customer ON sales_order (customer_id, placed_at DESC);

CREATE TRIGGER trg_sales_order_updated BEFORE UPDATE ON sales_order
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE sales_order IS '订单：C端与B端共用；status 是订单聚合根的唯一状态机';

CREATE TABLE sales_order_item (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id            BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    product_id          BIGINT NOT NULL REFERENCES product(id),
    channel_listing_id  BIGINT REFERENCES channel_listing(id) ON DELETE SET NULL,
    -- 实际命中的源（下单时快照，路由结果）
    supplier_product_id BIGINT REFERENCES supplier_product(id) ON DELETE SET NULL,
    supplier_id         BIGINT REFERENCES supplier(id) ON DELETE SET NULL,
    session_id          BIGINT REFERENCES product_session(id) ON DELETE SET NULL,
    ticket_type_id      BIGINT REFERENCES ticket_type(id) ON DELETE SET NULL,
    quantity            INT NOT NULL CHECK (quantity > 0),
    unit_price          NUMERIC(12,2) NOT NULL,
    unit_cost           NUMERIC(12,2),
    total_price         NUMERIC(12,2) NOT NULL,
    currency            CHAR(3) NOT NULL DEFAULT 'CNY',
    -- 明细快照：标题/日期/时段/入场点/规格/政策，订单历史必须可复现
    detail_snapshot     JSONB NOT NULL DEFAULT '{}'::jsonb,
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','booking','confirmed','ticketed','failed','cancelled','refunded')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT order_item_total_ck CHECK (total_price = unit_price * quantity)
);
CREATE INDEX ix_order_item_order  ON sales_order_item (order_id);
CREATE INDEX ix_order_item_suppl  ON sales_order_item (supplier_id, created_at DESC);
CREATE INDEX ix_order_item_sess   ON sales_order_item (session_id);

CREATE TRIGGER trg_sales_order_item_updated BEFORE UPDATE ON sales_order_item
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE sales_payment (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id         BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    channel_id       BIGINT REFERENCES channel(id) ON DELETE SET NULL,
    payment_method   TEXT NOT NULL,
    amount           NUMERIC(12,2) NOT NULL,
    currency         CHAR(3) NOT NULL DEFAULT 'CNY',
    status           TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','processing','succeeded','failed','cancelled','refunded','partial_refund')),
    provider         TEXT,
    provider_txn_id  TEXT,
    paid_at          TIMESTAMPTZ,
    raw_payload      JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_payment_order ON sales_payment (order_id);
CREATE UNIQUE INDEX ux_payment_provider_txn ON sales_payment (provider, provider_txn_id)
    WHERE provider_txn_id IS NOT NULL;

CREATE TABLE sales_refund (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    refund_no        TEXT NOT NULL UNIQUE,
    order_id         BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    order_item_id    BIGINT REFERENCES sales_order_item(id) ON DELETE SET NULL,
    amount           NUMERIC(12,2) NOT NULL,
    currency         CHAR(3) NOT NULL DEFAULT 'CNY',
    status           TEXT NOT NULL DEFAULT 'requested'
                     CHECK (status IN ('requested','approved','processing','succeeded','failed','rejected')),
    reason           TEXT,
    supplier_refund_id TEXT,
    requested_by     TEXT,
    approved_at      TIMESTAMPTZ,
    completed_at     TIMESTAMPTZ,
    raw_payload      JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_refund_order ON sales_refund (order_id, status);

-- =====================================================================================
-- 9. 预订域 Booking — 与供应商的预订交互（独立聚合 / Saga 编排）
-- =====================================================================================

CREATE TABLE booking (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_no          TEXT NOT NULL UNIQUE,
    order_id            BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    order_item_id       BIGINT REFERENCES sales_order_item(id) ON DELETE CASCADE,
    supplier_id         BIGINT NOT NULL REFERENCES supplier(id),
    supplier_product_id BIGINT REFERENCES supplier_product(id) ON DELETE SET NULL,
    supplier_session_id BIGINT REFERENCES supplier_session(id) ON DELETE SET NULL,
    external_booking_id TEXT,                 -- 源侧预订号
    status              TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','requested','confirmed','failed','cancelled',
                                          'expired','ticketed','partially_cancelled')),
    attempt_count       INT NOT NULL DEFAULT 0,
    next_retry_at       TIMESTAMPTZ,
    -- 发往源侧的幂等键（同一 logical booking 重试不重复下单）
    idempotency_key     TEXT NOT NULL,
    request_payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
    response_payload    JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_code          TEXT,
    error_message       TEXT,
    confirmed_at        TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT booking_retry_time_ck CHECK (next_retry_at IS NULL OR next_retry_at >= created_at - interval '1 minute')
);
CREATE UNIQUE INDEX ux_booking_idem ON booking (supplier_id, idempotency_key);
CREATE INDEX ix_booking_order     ON booking (order_id);
CREATE INDEX ix_booking_retry     ON booking (status, next_retry_at)
    WHERE status IN ('pending','requested');
CREATE INDEX ix_booking_external  ON booking (supplier_id, external_booking_id)
    WHERE external_booking_id IS NOT NULL;

CREATE TRIGGER trg_booking_updated BEFORE UPDATE ON booking
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE booking IS '供应商预订：与订单分离的聚合，独立重试/超时/改派，不阻塞订单聚合';

CREATE TABLE booking_attempt (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id  BIGINT NOT NULL REFERENCES booking(id) ON DELETE CASCADE,
    attempt_no  INT NOT NULL,
    request     JSONB,
    response    JSONB,
    http_status INT,
    latency_ms  INT,
    error_type  TEXT,   -- retriable/fatal/auth/rate_limit/timeout
    error_message TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT booking_attempt_uk UNIQUE (booking_id, attempt_no)
);

CREATE TABLE booking_event (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id  BIGINT NOT NULL REFERENCES booking(id) ON DELETE CASCADE,
    from_status TEXT,
    to_status   TEXT,
    event_type  TEXT NOT NULL,   -- BookingRequested/BookingConfirmed/BookingFailed/BookingCancelled/BookingExpired
    payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_booking_event ON booking_event (booking_id, created_at);

-- =====================================================================================
-- 10. 履约域 Fulfillment — 票券凭证与核销
-- =====================================================================================

CREATE TABLE voucher (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_no      TEXT NOT NULL UNIQUE,
    order_id        BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    order_item_id   BIGINT REFERENCES sales_order_item(id) ON DELETE CASCADE,
    booking_id      BIGINT REFERENCES booking(id) ON DELETE SET NULL,
    product_id      BIGINT NOT NULL REFERENCES product(id),
    supplier_id     BIGINT REFERENCES supplier(id) ON DELETE SET NULL,
    ticket_type_id  BIGINT REFERENCES ticket_type(id) ON DELETE SET NULL,
    session_id      BIGINT REFERENCES product_session(id) ON DELETE SET NULL,
    code            TEXT,             -- 票号
    barcode         TEXT,
    qr_payload      TEXT,             -- 二维码内容（建议带签名 token）
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','issued','used','void','expired','refunded')),
    issued_at       TIMESTAMPTZ,
    valid_from      TIMESTAMPTZ,
    valid_to        TIMESTAMPTZ,
    holder_snapshot JSONB NOT NULL DEFAULT '{}'::jsonb,  -- 持票人姓名/证件快照
    used_at         TIMESTAMPTZ,
    used_channel    TEXT,
    raw_payload     JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_voucher_code ON voucher (supplier_id, code) WHERE code IS NOT NULL AND supplier_id IS NOT NULL;
CREATE INDEX ix_voucher_order   ON voucher (order_id);
CREATE INDEX ix_voucher_status  ON voucher (status, valid_to);
CREATE INDEX ix_voucher_session ON voucher (session_id, status);

CREATE TRIGGER trg_voucher_updated BEFORE UPDATE ON voucher
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE voucher IS '票券凭证：一券一行，可多次入场的用 entitlement 表';

CREATE TABLE voucher_entitlement (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_id        BIGINT NOT NULL REFERENCES voucher(id) ON DELETE CASCADE,
    entitlement_type  TEXT NOT NULL,   -- admission/meal/pickup/transfer
    quantity          INT NOT NULL DEFAULT 1,
    consumed_quantity INT NOT NULL DEFAULT 0,
    meta              JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT entitlement_qty_ck CHECK (consumed_quantity >= 0 AND consumed_quantity <= quantity)
);

CREATE TABLE voucher_redemption (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_id     BIGINT NOT NULL REFERENCES voucher(id) ON DELETE CASCADE,
    supplier_id    BIGINT REFERENCES supplier(id) ON DELETE SET NULL,
    result         TEXT NOT NULL CHECK (result IN ('success','failed','duplicate','expired','revoked')),
    scanned_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    gate_location  TEXT,
    device_id      TEXT,
    operator_id    TEXT,
    payload        JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX ix_redemption_voucher ON voucher_redemption (voucher_id, scanned_at DESC);

-- =====================================================================================
-- 11. 结算域 Settlement — 供应商对账与结算
-- =====================================================================================

CREATE TABLE settlement_statement (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id    BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    channel_id     BIGINT REFERENCES channel(id) ON DELETE SET NULL,
    statement_no   TEXT,
    period_start   DATE NOT NULL,
    period_end     DATE NOT NULL,
    currency       CHAR(3) NOT NULL DEFAULT 'CNY',
    status         TEXT NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','reconciled','disputed','settled','paid')),
    gross_amount   NUMERIC(14,2) NOT NULL DEFAULT 0,
    fee_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
    tax_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_amount     NUMERIC(14,2) NOT NULL DEFAULT 0,
    file_url       TEXT,
    source         TEXT NOT NULL DEFAULT 'import' CHECK (source IN ('import','auto','manual')),
    imported_at    TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT statement_period_ck CHECK (period_end >= period_start)
);
CREATE INDEX ix_statement_supplier ON settlement_statement (supplier_id, period_start DESC);

CREATE TRIGGER trg_statement_updated BEFORE UPDATE ON settlement_statement
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE settlement_line (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    statement_id      BIGINT NOT NULL REFERENCES settlement_statement(id) ON DELETE CASCADE,
    booking_id        BIGINT REFERENCES booking(id) ON DELETE SET NULL,
    order_id          BIGINT REFERENCES sales_order(id) ON DELETE SET NULL,
    external_ref      TEXT,        -- 源侧结算行号
    quantity          INT NOT NULL DEFAULT 1,
    gross_amount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    fee_amount        NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_amount        NUMERIC(14,2) NOT NULL DEFAULT 0,
    currency          CHAR(3) NOT NULL DEFAULT 'CNY',
    discrepancy_type  TEXT CHECK (discrepancy_type IN ('missing','extra','amount_mismatch','qty_mismatch','status_mismatch')),
    discrepancy_amount NUMERIC(14,2),
    note              TEXT,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_settle_line_booking ON settlement_line (booking_id);
CREATE INDEX ix_settle_line_disc    ON settlement_line (statement_id) WHERE discrepancy_type IS NOT NULL;

CREATE TABLE reconciliation_run (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id    BIGINT NOT NULL REFERENCES supplier(id) ON DELETE CASCADE,
    scope          TEXT NOT NULL DEFAULT 'statement',
    period_start   DATE,
    period_end     DATE,
    status         TEXT NOT NULL DEFAULT 'running' CHECK (status IN ('running','success','partial','failed')),
    matched_count  INT NOT NULL DEFAULT 0,
    mismatched_count INT NOT NULL DEFAULT 0,
    discrepancies  JSONB NOT NULL DEFAULT '[]'::jsonb,
    started_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at    TIMESTAMPTZ
);

-- =====================================================================================
-- 12. 事件与幂等（Outbox / Inbox）
-- =====================================================================================

CREATE TABLE event_outbox (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aggregate_type TEXT NOT NULL,
    aggregate_id   BIGINT NOT NULL,
    event_type     TEXT NOT NULL,
    payload        JSONB NOT NULL DEFAULT '{}'::jsonb,
    status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','published','failed','dead_letter')),
    attempts       INT NOT NULL DEFAULT 0,
    next_retry_at  TIMESTAMPTZ,
    last_error     TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ
);
CREATE INDEX ix_outbox_pending ON event_outbox (status, next_retry_at) WHERE status = 'pending';

CREATE TABLE idempotency_record (
    scope         TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash  TEXT NOT NULL,
    response      JSONB,
    status        TEXT NOT NULL DEFAULT 'in_progress' CHECK (status IN ('in_progress','done','failed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ,
    PRIMARY KEY (scope, idempotency_key)
);

CREATE TABLE notification_outbox (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel        TEXT NOT NULL,      -- sms/email/wechat/lark/webhook
    template_code  TEXT NOT NULL,
    recipient      TEXT NOT NULL,
    payload        JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 多通道冗余：每个通道独立状态与重试
    channels       JSONB NOT NULL DEFAULT '[]'::jsonb,  -- [{"type":"lark","status":"sent","at":...}]
    status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','partial','failed')),
    attempts       INT NOT NULL DEFAULT 0,
    next_retry_at  TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at        TIMESTAMPTZ
);
CREATE INDEX ix_notify_retry ON notification_outbox (status, next_retry_at) WHERE status <> 'sent';

-- =====================================================================================
-- 13. 运维视图
-- =====================================================================================

-- 13.1 跨源覆盖度：每个规范商品有几个源在供、是否有多源冗余
CREATE VIEW v_product_source_coverage AS
SELECT
    p.id                                   AS product_id,
    p.product_code,
    p.title,
    p.status                               AS product_status,
    COUNT(DISTINCT m.supplier_product_id)  AS supplier_count,
    COUNT(DISTINCT m.supplier_product_id) FILTER (WHERE m.is_primary) AS primary_source_count,
    COUNT(DISTINCT m.supplier_product_id) FILTER (WHERE m.status <> 'active') AS pending_mapping_count,
    string_agg(DISTINCT s.code, ',')       AS suppliers,
    (COUNT(DISTINCT m.supplier_product_id) FILTER (WHERE m.status = 'active') > 1) AS has_redundancy,
    MAX(m.updated_at)                      AS mapping_updated_at
FROM product p
LEFT JOIN product_mapping m  ON m.product_id = p.id
LEFT JOIN supplier_product sp ON sp.id = m.supplier_product_id
LEFT JOIN supplier s          ON s.id = sp.supplier_id
GROUP BY p.id, p.product_code, p.title, p.status;

COMMENT ON VIEW v_product_source_coverage IS '跨源覆盖度：has_redundancy=true 表示该商品具备多源冗余能力';

-- 13.2 多源比价：同一商品不同源的成本与库存，用于自动路由决策
--      粒度到「商品 × 源 × 币种」：跨币种的裸数字没有可比性，
--      min_net_cost_native 只在同币种内取最小值，跨币种比较一律看 min_net_cost_base。
CREATE VIEW v_product_source_compare AS
SELECT
    p.id                AS product_id,
    p.title,
    sp.id               AS supplier_product_id,
    sup.id              AS supplier_id,
    sup.code            AS supplier_code,
    sp.external_id,
    sp.availability_mode,
    spc.currency        AS source_currency,
    MIN(spc.net_price)                          AS min_net_cost_native,
    MIN(fn_convert(spc.net_price, spc.currency, fn_base_currency(), spc.date))
                                                  AS min_net_cost_base,   -- 统一折算到基准币种后才可比
    fn_base_currency()                           AS base_currency,
    MAX(spc.supplier_price)  AS max_list_price,
    AVG(spc.supplier_price)  AS avg_list_price,
    COUNT(spc.id)            AS priced_days,
    COUNT(DISTINCT spc.date) AS covered_dates,
    (SELECT COUNT(*) FROM product_session_source pss
       WHERE pss.supplier_product_id = sp.id AND pss.role IN ('primary','fallback')) AS session_bindings
FROM product p
JOIN product_mapping m   ON m.product_id = p.id AND m.status = 'active'
JOIN supplier_product sp  ON sp.id = m.supplier_product_id
JOIN supplier sup         ON sup.id = sp.supplier_id
LEFT JOIN supplier_price_calendar spc ON spc.supplier_product_id = sp.id
GROUP BY p.id, p.title, sp.id, sup.id, sup.code, sp.external_id, sp.availability_mode, spc.currency;

-- 13.3 订单-预订-凭证 漏斗（排查"付了没出票"）
CREATE VIEW v_order_fulfillment_gap AS
SELECT
    o.id                AS order_id,
    o.order_no,
    o.channel_id,
    o.status            AS order_status,
    o.payment_status,
    o.placed_at,
    COUNT(DISTINCT b.id)      AS booking_count,
    COUNT(DISTINCT b.id) FILTER (WHERE b.status = 'confirmed')  AS confirmed_bookings,
    COUNT(DISTINCT b.id) FILTER (WHERE b.status = 'failed')     AS failed_bookings,
    COUNT(DISTINCT v.id)      AS voucher_count,
    COUNT(DISTINCT v.id) FILTER (WHERE v.status = 'issued')     AS issued_vouchers,
    COUNT(DISTINCT v.id) FILTER (WHERE v.status = 'used')       AS used_vouchers,
    (o.payment_status = 'paid' AND COUNT(DISTINCT v.id) FILTER (WHERE v.status = 'issued') = 0
        AND o.placed_at < now() - interval '30 minutes')          AS suspected_lost
FROM sales_order o
LEFT JOIN booking b ON b.order_id = o.id
LEFT JOIN voucher v ON v.order_id = o.id
GROUP BY o.id, o.order_no, o.channel_id, o.status, o.payment_status, o.placed_at;

COMMENT ON VIEW v_order_fulfillment_gap IS '履约漏斗：suspected_lost=true 表示已付款 30 分钟仍未出票，需人工/自动重报';

-- 13.4 源健康度
CREATE VIEW v_supplier_sync_health AS
SELECT
    s.id AS supplier_id,
    s.code,
    s.name,
    s.status,
    (SELECT COUNT(*) FROM supplier_product sp WHERE sp.supplier_id = s.id AND sp.status = 'active') AS active_products,
    (SELECT COUNT(*) FROM product_mapping m JOIN supplier_product sp2 ON sp2.id = m.supplier_product_id
      WHERE sp2.supplier_id = s.id AND m.status = 'active') AS mapped_products,
    (SELECT COUNT(*) FROM supplier_raw_payload r WHERE r.supplier_id = s.id
      AND r.created_at > now() - interval '1 hour')          AS payloads_1h,
    (SELECT MAX(started_at) FROM sync_job_log j WHERE j.supplier_id = s.id) AS last_sync_at,
    (SELECT count(*) FROM sync_job_log j WHERE j.supplier_id = s.id
      AND j.status = 'failed' AND j.started_at > now() - interval '24 hours') AS failed_jobs_24h
FROM supplier s;

-- 13.5 结算缺口：已确认预订但未出现在结算单里
CREATE VIEW v_settlement_gap AS
SELECT
    b.supplier_id,
    sup.code AS supplier_code,
    b.id AS booking_id,
    b.booking_no,
    b.external_booking_id,
    b.status AS booking_status,
    b.confirmed_at,
    o.order_no,
    (SELECT count(*) FROM settlement_line sl WHERE sl.booking_id = b.id) AS settlement_lines
FROM booking b
JOIN supplier sup ON sup.id = b.supplier_id
JOIN sales_order o ON o.id = b.order_id
WHERE b.status IN ('confirmed','ticketed')
  AND NOT EXISTS (SELECT 1 FROM settlement_line sl WHERE sl.booking_id = b.id);

-- 13.6 选源候选（自动路由）：把 渠道 → 源 → 成本 → 汇率 → 排名 串成一条可执行决策
--      汇率口径走 fn_fx_rate(币种, 价格日期)：取当日或之前最近的一份快照。
--      没有快照的币种不参与比价 —— 不可比的成本不该被当成便宜的候选。
CREATE VIEW v_source_routing_candidates AS
SELECT
    cl.channel_id,
    ch.code                AS channel_code,
    pc.product_id,
    p.title                AS product_title,
    pc.date,
    tt.code                AS ticket_type_code,
    spc.supplier_product_id,
    sup.code               AS supplier_code,
    spc.currency           AS source_currency,
    spc.supplier_price,
    spc.net_price,
    fn_fx_rate(spc.currency, spc.date) AS fx_rate,
    fn_convert(spc.net_price, spc.currency, fn_base_currency(), spc.date) AS cost_base,
    fn_base_currency()     AS base_currency,
    cls.priority,
    cls.fallback_order,
    sp.availability_mode,
    ROW_NUMBER() OVER (
        PARTITION BY cl.channel_id, pc.product_id, pc.date, tt.code
        ORDER BY fn_convert(spc.net_price, spc.currency, fn_base_currency(), spc.date),
                 cls.priority, cls.fallback_order
    ) AS route_rank
FROM channel_listing cl
JOIN channel ch          ON ch.id = cl.channel_id
JOIN price_calendar pc   ON pc.product_id = cl.product_id
                       AND pc.date IS NOT NULL
JOIN product p           ON p.id = pc.product_id
JOIN ticket_type tt      ON tt.id = pc.ticket_type_id
JOIN supplier_price_calendar spc
     ON spc.product_id  = pc.product_id
    AND spc.date        = pc.date
    AND spc.supplier_ticket_type_id IS NOT NULL
JOIN ticket_type_mapping ttm ON ttm.supplier_ticket_type_id = spc.supplier_ticket_type_id
                             AND ttm.ticket_type_id = tt.id
JOIN supplier_product sp  ON sp.id = spc.supplier_product_id
JOIN supplier sup         ON sup.id = sp.supplier_id
JOIN channel_listing_source cls ON cls.channel_listing_id = cl.id
                               AND cls.supplier_product_id = sp.id
                               AND cls.enabled
WHERE pc.channel_id IS NULL
  AND pc.status = 'active'
  AND spc.status = 'available'
  AND fn_fx_rate(spc.currency, spc.date) IS NOT NULL;

COMMENT ON VIEW v_source_routing_candidates IS '选源候选：route_rank=1 即自动路由首选源；成本已按汇率归一到 CNY';

-- 13.7 不变量自检视图：任何一条 actual > 0 即为数据违反业务约束（可直接进 CI）
CREATE VIEW v_invariant_checks AS
WITH raw(seq, check_name, actual) AS (
  SELECT 1, '规范商品必须有至少一个 active 源映射',
         (SELECT count(*) FROM product p WHERE NOT EXISTS (
            SELECT 1 FROM product_mapping m WHERE m.product_id = p.id AND m.status = 'active'))
  UNION ALL
  SELECT 2, '同一商品同一供应商最多一个 primary 映射',
         (SELECT count(*) FROM (SELECT 1 FROM product_mapping WHERE is_primary
                                GROUP BY product_id, supplier_id HAVING count(*) > 1) x)
  UNION ALL
  SELECT 3, '场次源绑定的源商品必须映射到同一规范商品',
         (SELECT count(*) FROM product_session_source pss
            JOIN product_session ps ON ps.id = pss.product_session_id
            JOIN supplier_product sp ON sp.id = pss.supplier_product_id
           WHERE NOT EXISTS (SELECT 1 FROM product_mapping m
                              WHERE m.supplier_product_id = sp.id
                                AND m.product_id = ps.product_id AND m.status = 'active'))
  UNION ALL
  SELECT 4, '订单金额自洽 total = subtotal - discount + tax',
         (SELECT count(*) FROM sales_order WHERE total <> subtotal - discount + tax)
  UNION ALL
  -- 5. 订单明细金额自洽（本预览版为旧口径；最终口径见第 19 节的不变量视图，
  --    按团计价需要 pricing_basis 列，故此处在建列之前只能校验按人口径）
  SELECT 5, '订单明细 total_price = unit_price * quantity',
         (SELECT count(*) FROM sales_order_item WHERE total_price <> unit_price * quantity)
  UNION ALL
  SELECT 6, '订单行 supplier_id 与 supplier_product 所属供应商一致',
         (SELECT count(*) FROM sales_order_item oi JOIN supplier_product sp ON sp.id = oi.supplier_product_id
           WHERE sp.supplier_id <> oi.supplier_id)
  UNION ALL
  SELECT 7, '已确认预订必须有 external_booking_id',
         (SELECT count(*) FROM booking WHERE status = 'confirmed' AND external_booking_id IS NULL)
  UNION ALL
  SELECT 8, '同源同票码不得重复出票',
         (SELECT count(*) FROM (SELECT 1 FROM voucher WHERE code IS NOT NULL
                                GROUP BY supplier_id, code HAVING count(*) > 1) x)
  UNION ALL
  SELECT 9, '权益消耗数不得超过发放数',
         (SELECT count(*) FROM voucher_entitlement WHERE consumed_quantity > quantity)
  UNION ALL
  SELECT 10, '对客售价必须 ≥ 采纳成本（不得亏本销售）',
         (SELECT count(*) FROM price_calendar
           WHERE cost_price IS NOT NULL AND sell_price IS NOT NULL AND sell_price < cost_price)
  UNION ALL
  SELECT 11, '已支付订单必须有 succeeded 支付记录',
         (SELECT count(*) FROM sales_order o WHERE o.payment_status = 'paid'
           AND NOT EXISTS (SELECT 1 FROM sales_payment p WHERE p.order_id = o.id AND p.status = 'succeeded'))
  UNION ALL
  SELECT 12, '已履约订单必须有 issued/used 状态凭证',
         (SELECT count(*) FROM sales_order o WHERE o.fulfillment_status = 'fulfilled'
           AND NOT EXISTS (SELECT 1 FROM voucher v WHERE v.order_id = o.id AND v.status IN ('issued','used')))
  UNION ALL
  SELECT 13, '映射的 supplier_id 与源商品所属供应商一致',
         (SELECT count(*) FROM product_mapping m JOIN supplier_product sp ON sp.id = m.supplier_product_id
           WHERE m.supplier_id <> sp.supplier_id)
  UNION ALL
  SELECT 14, '所有在用币种（非基准币种）必须有汇率快照',
         (SELECT count(*) FROM (SELECT DISTINCT currency FROM supplier_price_calendar) c
           WHERE c.currency <> 'CNY'
             AND NOT EXISTS (SELECT 1 FROM fx_rate f
                              WHERE f.quote_currency = c.currency AND f.base_currency = 'CNY'))
  UNION ALL
  SELECT 15, '每个 online 渠道上架必须绑定至少一个启用源',
         (SELECT count(*) FROM channel_listing cl
           WHERE cl.status = 'online'
             AND NOT EXISTS (SELECT 1 FROM channel_listing_source cls
                             WHERE cls.channel_listing_id = cl.id AND cls.enabled))
  UNION ALL
  SELECT 16, '售价日历的采纳成本必须可追溯到具体源',
         (SELECT count(*) FROM price_calendar pc
           WHERE pc.cost_price IS NOT NULL AND pc.cost_source_product_id IS NULL)
  UNION ALL
  SELECT 17, 'booking.attempt_count 不得小于实际尝试记录数',
         (SELECT count(*) FROM booking b
           WHERE b.attempt_count < (SELECT count(*) FROM booking_attempt ba WHERE ba.booking_id = b.id))
  UNION ALL
  SELECT 18, '渠道内订单幂等键不得重复',
         (SELECT count(*) FROM (SELECT 1 FROM sales_order WHERE idempotency_key IS NOT NULL
                                GROUP BY channel_id, idempotency_key HAVING count(*) > 1) x)
  UNION ALL
  SELECT 19, '库存快照与可用性缓存的供应商必须存在',
         (SELECT count(*) FROM availability_cache ac
           WHERE NOT EXISTS (SELECT 1 FROM supplier s WHERE s.id = ac.supplier_id))
  UNION ALL
  SELECT 20, '已出票凭证必须归属某个已确认预订',
         (SELECT count(*) FROM voucher v WHERE v.status IN ('issued','used')
           AND (v.booking_id IS NULL
                OR NOT EXISTS (SELECT 1 FROM booking b
                                WHERE b.id = v.booking_id AND b.status IN ('confirmed','ticketed'))))
)
SELECT seq, check_name, 0 AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM raw;

COMMENT ON VIEW v_invariant_checks IS '18+ 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';

-- =====================================================================================
-- 14. C 端读模型 Read Model —— 列表页 / 搜索 / 日历 的高频读取
--
-- 为什么单独建表：C 端列表页一页 20-50 个商品卡片，需要每个商品一次性拿到
-- 图、标题、评分、起价、可售天数、标签。这些字段散在 product / price_calendar /
-- product_session / inventory_snapshot / product_media 五张表里，实时 join 成本高，
-- 且「价格的新鲜度」与「库存的新鲜度」时序不同源，卡片上会自相矛盾。
--
-- 做法：后台刷新作业把这些字段物化成读模型，C 端查询只打这一张表。
-- 读模型可随时重建，主数据仍是唯一真相。
-- =====================================================================================

CREATE TABLE c_product_card (
    channel_id         BIGINT NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    product_id         BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    locale             TEXT NOT NULL DEFAULT 'zh-CN',
    title              TEXT NOT NULL,
    subtitle           TEXT,
    thumb_url          TEXT,
    city_id            BIGINT REFERENCES city(id) ON DELETE SET NULL,
    category_id        BIGINT REFERENCES category(id) ON DELETE SET NULL,
    rating             NUMERIC(3,2),
    review_count       INT NOT NULL DEFAULT 0,
    currency           CHAR(3) NOT NULL DEFAULT 'CNY',
    from_price         NUMERIC(12,2),      -- 未来窗口内的起价（含各票种）
    list_price         NUMERIC(12,2),
    next_available_date DATE,              -- 最近一个可售日
    available_days     INT NOT NULL DEFAULT 0,   -- 未来窗口内可售天数
    duration_minutes   INT,
    age_min            INT,
    tag_labels         JSONB NOT NULL DEFAULT '[]'::jsonb,  -- ["今日免费取消","手机出票"]
    selling_points     JSONB NOT NULL DEFAULT '[]'::jsonb,  -- 卡片上的一行卖点
    status             TEXT NOT NULL DEFAULT 'online'
                       CHECK (status IN ('online','offline','sold_out')),
    sort_weight        INT NOT NULL DEFAULT 0,
    synced_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT c_card_uk UNIQUE (channel_id, product_id, locale)
);
CREATE INDEX ix_card_channel_sort   ON c_product_card (channel_id, status, sort_weight DESC);
CREATE INDEX ix_card_channel_price  ON c_product_card (channel_id, status, from_price);
CREATE INDEX ix_card_channel_rating ON c_product_card (channel_id, status, rating DESC);
CREATE INDEX ix_card_city           ON c_product_card (city_id, status);

COMMENT ON TABLE c_product_card IS 'C端列表页读模型：一张卡片一行，反范式存储，可随时重建';

-- 日历格子：一个商品 × 一天
CREATE TABLE c_product_calendar (
    channel_id    BIGINT NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    product_id    BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    date          DATE NOT NULL,
    price_min     NUMERIC(12,2),
    price_max     NUMERIC(12,2),
    ticket_types  JSONB NOT NULL DEFAULT '[]'::jsonb,  -- [{"code":"adult","price":138,"status":"available"}]
    status        TEXT NOT NULL DEFAULT 'available'
                  CHECK (status IN ('available','sold_out','limited','closed','pending')),
    session_count INT NOT NULL DEFAULT 0,
    synced_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, product_id, date)
);
CREATE INDEX ix_cal_product_date ON c_product_calendar (product_id, date);

COMMENT ON TABLE c_product_calendar IS 'C端日历读模型：详情页日期条格子数据，status 供前端本地化展示';

-- =====================================================================================
-- 15. 展示内容（Marketing Content）—— 详情页真正要渲染的东西
--
-- 纪律：凡是"要按语言渲染给用户看"的文案，一律行级表 + locale 列；
--       product.attributes 只保留语言无关的结构化事实（时长、年龄门槛、可否手机出票）。
-- =====================================================================================

CREATE TABLE tag (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code       TEXT NOT NULL UNIQUE,
    name       TEXT NOT NULL,
    name_en    TEXT,
    group_code TEXT,          -- feature/policy/audience/scene
    sort_order INT NOT NULL DEFAULT 0,
    status     TEXT NOT NULL DEFAULT 'active'
);
COMMENT ON TABLE tag IS '商品标签：运营侧筛选与推荐的基础维度';

CREATE TABLE product_tag_link (
    product_id BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    tag_id     BIGINT NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    source     TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','rule','auto')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, tag_id)
);

CREATE TABLE product_highlight (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    locale     TEXT NOT NULL DEFAULT 'zh-CN',
    content    TEXT NOT NULL,
    sort_order INT NOT NULL DEFAULT 0
);
CREATE INDEX ix_highlight_product ON product_highlight (product_id, locale, sort_order);

CREATE TABLE product_inclusion (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    locale     TEXT NOT NULL DEFAULT 'zh-CN',
    kind       TEXT NOT NULL DEFAULT 'include' CHECK (kind IN ('include','exclude')),
    content    TEXT NOT NULL,
    sort_order INT NOT NULL DEFAULT 0
);
CREATE INDEX ix_inclusion_product ON product_inclusion (product_id, locale, kind, sort_order);

CREATE TABLE product_note (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    locale     TEXT NOT NULL DEFAULT 'zh-CN',
    kind       TEXT NOT NULL CHECK (kind IN ('important','cancellation','redeem','faq','age_policy','other')),
    title      TEXT,
    content    TEXT NOT NULL,
    sort_order INT NOT NULL DEFAULT 0
);
CREATE INDEX ix_note_product ON product_note (product_id, locale, kind, sort_order);

CREATE TABLE product_location (
    product_id    BIGINT PRIMARY KEY REFERENCES product(id) ON DELETE CASCADE,
    address       TEXT,
    address_en    TEXT,
    latitude      NUMERIC(10,7),
    longitude     NUMERIC(10,7),
    map_provider  TEXT,
    place_id      TEXT,
    meeting_point TEXT,        -- 集合点 / 换票点
    transit_note  TEXT,
    nearby        JSONB NOT NULL DEFAULT '[]'::jsonb
);

CREATE TABLE product_review (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id     BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    order_id       BIGINT REFERENCES sales_order(id) ON DELETE SET NULL,
    rating         INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    content        TEXT,
    images         JSONB NOT NULL DEFAULT '[]'::jsonb,
    reviewer_hash  TEXT,       -- 脱敏后的用户标识
    status         TEXT NOT NULL DEFAULT 'published'
                   CHECK (status IN ('pending','published','rejected')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_review_product ON product_review (product_id, status, created_at DESC);

-- =====================================================================================
-- 16. 购买漏斗（Conversion Funnel）
--     购物车 / 优惠券 / 结算必填规格 / 持票人 / 库存预占 / 核销端
-- =====================================================================================

CREATE TABLE cart (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cart_no     TEXT NOT NULL UNIQUE,
    channel_id  BIGINT NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    customer_id BIGINT REFERENCES customer(id) ON DELETE SET NULL,
    status      TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','converted','abandoned','expired')),
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_cart_customer ON cart (channel_id, customer_id, status);

CREATE TRIGGER trg_cart_updated BEFORE UPDATE ON cart
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE cart_item (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cart_id         BIGINT NOT NULL REFERENCES cart(id) ON DELETE CASCADE,
    product_id      BIGINT NOT NULL REFERENCES product(id),
    session_id      BIGINT REFERENCES product_session(id),
    ticket_type_id  BIGINT REFERENCES ticket_type(id),
    quantity        INT NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(12,2),
    price_snapshot  JSONB NOT NULL DEFAULT '{}'::jsonb,
    hold_id         BIGINT,      -- 关联库存预占
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT cart_item_uk UNIQUE (cart_id, product_id, session_id, ticket_type_id)
);

CREATE TABLE coupon (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code              TEXT NOT NULL UNIQUE,
    name              TEXT NOT NULL,
    channel_id        BIGINT REFERENCES channel(id) ON DELETE CASCADE,  -- 限定渠道，NULL=全渠道
    discount_type     TEXT NOT NULL CHECK (discount_type IN ('fixed','percent','free_item')),
    discount_value    NUMERIC(12,2),
    min_amount        NUMERIC(12,2),
    max_discount      NUMERIC(12,2),
    -- 适用范围：{"category_ids":[1],"product_ids":[5],"ticket_type_ids":[2]}
    applicable_scope  JSONB NOT NULL DEFAULT '{}'::jsonb,
    -- 有效期：{"from":"2026-11-01","to":"2026-11-30","validity_days":7}
    validity          JSONB NOT NULL DEFAULT '{}'::jsonb,
    usage_limit       INT,
    used_count        INT NOT NULL DEFAULT 0,
    per_customer_limit INT,
    status            TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','paused','expired')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT coupon_usage_ck CHECK (used_count >= 0 AND (usage_limit IS NULL OR used_count <= usage_limit))
);

CREATE TRIGGER trg_coupon_updated BEFORE UPDATE ON coupon
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

CREATE TABLE coupon_redemption (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    coupon_id        BIGINT NOT NULL REFERENCES coupon(id) ON DELETE CASCADE,
    order_id         BIGINT REFERENCES sales_order(id) ON DELETE SET NULL,
    customer_id      BIGINT REFERENCES customer(id) ON DELETE SET NULL,
    discount_amount  NUMERIC(12,2) NOT NULL,
    status           TEXT NOT NULL DEFAULT 'used'
                     CHECK (status IN ('used','revoked')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_coupon_redeem_coupon ON coupon_redemption (coupon_id);

-- 结算必填信息规格：按商品/票种/渠道定义「要收哪些字段、怎么校验」
CREATE TABLE checkout_requirement (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id     BIGINT REFERENCES product(id) ON DELETE CASCADE,
    ticket_type_id BIGINT REFERENCES ticket_type(id) ON DELETE CASCADE,
    channel_id     BIGINT REFERENCES channel(id) ON DELETE CASCADE,
    field_code     TEXT NOT NULL,   -- holder_name / id_number / dob / nationality
    label          TEXT NOT NULL,
    data_type      TEXT NOT NULL CHECK (data_type IN ('string','number','date','id_card','passport')),
    required       BOOLEAN NOT NULL DEFAULT true,
    max_length     INT,
    pattern        TEXT,
    min_age        INT,
    max_age        INT,
    privacy_level  TEXT NOT NULL DEFAULT 'internal'
                   CHECK (privacy_level IN ('public','internal','sensitive')),
    sort_order     INT NOT NULL DEFAULT 0
);
CREATE INDEX ix_checkout_req ON checkout_requirement (product_id, ticket_type_id, channel_id);

COMMENT ON TABLE checkout_requirement IS '结算表单规格：驱动 C 端动态渲染与提交校验，敏感字段须脱敏存储';

-- 持票人：下单时收集的原始输入（与 voucher.holder_snapshot 的关系：这里是输入，凭证里是快照）
CREATE TABLE order_holder (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      BIGINT NOT NULL REFERENCES sales_order(id) ON DELETE CASCADE,
    order_item_id BIGINT NOT NULL REFERENCES sales_order_item(id) ON DELETE CASCADE,
    ticket_type_id BIGINT REFERENCES ticket_type(id) ON DELETE SET NULL,
    sequence      INT NOT NULL DEFAULT 1,   -- 第几张票
    field_code    TEXT NOT NULL,
    value         TEXT,
    value_hash    TEXT,                      -- 敏感字段只存哈希
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_holder_order ON order_holder (order_id);
CREATE INDEX ix_holder_item  ON order_holder (order_item_id, sequence);

-- 库存预占：购物车/结算期占住库存，超时自动释放
CREATE TABLE inventory_hold (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    hold_no           TEXT NOT NULL UNIQUE,
    channel_id        BIGINT REFERENCES channel(id) ON DELETE SET NULL,
    product_session_id BIGINT NOT NULL REFERENCES product_session(id) ON DELETE CASCADE,
    ticket_type_id    BIGINT REFERENCES ticket_type(id) ON DELETE SET NULL,
    supplier_id       BIGINT REFERENCES supplier(id) ON DELETE SET NULL,
    quantity          INT NOT NULL CHECK (quantity > 0),
    status            TEXT NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','consumed','released','expired')),
    order_id          BIGINT REFERENCES sales_order(id) ON DELETE SET NULL,
    cart_id           BIGINT REFERENCES cart(id) ON DELETE SET NULL,
    expires_at        TIMESTAMPTZ NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at       TIMESTAMPTZ
);
CREATE INDEX ix_hold_expiry ON inventory_hold (expires_at) WHERE status = 'active';
CREATE INDEX ix_hold_cart   ON inventory_hold (cart_id) WHERE status = 'active';

-- 核销端（景区闸机 / 门店柜台 / 核销员）
CREATE TABLE gate (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id    BIGINT REFERENCES supplier(id) ON DELETE SET NULL,
    code           TEXT NOT NULL UNIQUE,
    name           TEXT NOT NULL,
    location_name  TEXT,
    latitude       NUMERIC(10,7),
    longitude      NUMERIC(10,7),
    status         TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE gate_operator (
    id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gate_id  BIGINT NOT NULL REFERENCES gate(id) ON DELETE CASCADE,
    code     TEXT NOT NULL UNIQUE,
    name     TEXT,
    status   TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive'))
);

-- C 端相关列补齐（DDL 只增不改：已发布表结构用 ALTER 演进）
ALTER TABLE sales_order ADD COLUMN cart_id        BIGINT REFERENCES cart(id) ON DELETE SET NULL;
ALTER TABLE sales_order ADD COLUMN coupon_id      BIGINT REFERENCES coupon(id) ON DELETE SET NULL;
ALTER TABLE sales_order ADD COLUMN discount_breakdown JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE voucher_redemption ADD COLUMN gate_id BIGINT REFERENCES gate(id) ON DELETE SET NULL;
ALTER TABLE voucher_redemption ADD COLUMN gate_operator_id BIGINT REFERENCES gate_operator(id) ON DELETE SET NULL;
-- 注：voucher_redemption.operator_id 是源侧操作员标识（TEXT），与本地核销员表 gate_operator 并存不冲突

-- =====================================================================================
-- 17. C 端视图
-- =====================================================================================

-- 17.1 列表页直出（读模型 + 标签 + 地点）
CREATE VIEW v_c_listing_feed AS
SELECT
    c.channel_id,
    ch.code        AS channel_code,
    c.product_id,
    c.locale,
    c.title,
    c.subtitle,
    c.thumb_url,
    c.from_price,
    c.list_price,
    c.currency,
    c.rating,
    c.review_count,
    c.duration_minutes,
    c.tag_labels,
    c.selling_points,
    c.next_available_date,
    c.available_days,
    ci.name         AS city_name,
    cat.name        AS category_name,
    pl.meeting_point,
    pl.latitude,
    pl.longitude,
    c.sort_weight,
    c.synced_at
FROM c_product_card c
JOIN channel ch    ON ch.id = c.channel_id
LEFT JOIN city ci      ON ci.id = c.city_id
LEFT JOIN category cat ON cat.id = c.category_id
LEFT JOIN product_location pl ON pl.product_id = c.product_id;

COMMENT ON VIEW v_c_listing_feed IS 'C端列表页直出视图：一行一卡片，无额外 join';

-- 17.2 详情页聚合：内容 + 标签 + 地点 + 评分分布
CREATE VIEW v_c_product_detail AS
SELECT
    p.id AS product_id,
    p.product_code,
    p.title,
    p.subtitle,
    p.description,
    p.attributes,
    p.validity_rule,
    p.refund_policy,
    p.rating,
    p.review_count,
    pl.address,
    pl.latitude,
    pl.longitude,
    pl.meeting_point,
    pl.transit_note,
    (SELECT jsonb_agg(jsonb_build_object('code', t.code, 'name', t.name) ORDER BY t.sort_order)
       FROM product_tag_link ptl JOIN tag t ON t.id = ptl.tag_id
      WHERE ptl.product_id = p.id) AS tags,
    (SELECT jsonb_agg(jsonb_build_object('content', h.content) ORDER BY h.sort_order)
       FROM product_highlight h WHERE h.product_id = p.id AND h.locale = 'zh-CN') AS highlights,
    (SELECT jsonb_agg(jsonb_build_object('kind', n.kind, 'title', n.title, 'content', n.content) ORDER BY n.kind, n.sort_order)
       FROM product_note n WHERE n.product_id = p.id AND n.locale = 'zh-CN') AS notes,
    (SELECT jsonb_agg(jsonb_build_object('kind', i.kind, 'content', i.content) ORDER BY i.kind, i.sort_order)
       FROM product_inclusion i WHERE i.product_id = p.id AND i.locale = 'zh-CN') AS inclusions,
    (SELECT jsonb_agg(jsonb_build_object('rating', r.rating) ORDER BY r.created_at DESC)
       FROM product_review r WHERE r.product_id = p.id AND r.status = 'published') AS reviews
FROM product p
LEFT JOIN product_location pl ON pl.product_id = p.id;

-- 17.3 结算页必填项汇总（驱动前端动态表单）
CREATE VIEW v_c_checkout_requirements AS
SELECT
    cr.product_id,
    cr.ticket_type_id,
    tt.code      AS ticket_type_code,
    cr.field_code,
    cr.label,
    cr.data_type,
    cr.required,
    cr.max_length,
    cr.pattern,
    cr.min_age,
    cr.max_age,
    cr.privacy_level,
    cr.sort_order
FROM checkout_requirement cr
LEFT JOIN ticket_type tt ON tt.id = cr.ticket_type_id;

COMMENT ON VIEW v_c_checkout_requirements IS '结算页动态表单规格：前端按此渲染，后端按此校验';

-- 17.4 读模型新鲜度：读模型起价与源价格日历是否已经不一致
CREATE VIEW v_c_readmodel_drift AS
SELECT
    c.channel_id,
    c.product_id,
    c.from_price       AS card_from_price,
    COALESCE(t.chan_min, t.base_min) AS truth_min_price,
    (c.from_price IS DISTINCT FROM COALESCE(t.chan_min, t.base_min)) AS drifted,
    c.synced_at,
    now() AS computed_at
FROM c_product_card c
LEFT JOIN LATERAL (
    SELECT
        MIN(pc.sell_price) FILTER (WHERE pc.channel_id = c.channel_id) AS chan_min,
        MIN(pc.sell_price) FILTER (WHERE pc.channel_id IS NULL)       AS base_min
    FROM price_calendar pc
    WHERE pc.product_id = c.product_id
      AND pc.status = 'active'
      AND pc.date >= current_date
      AND pc.date <= current_date + 30
      AND (pc.channel_id = c.channel_id OR pc.channel_id IS NULL)
) t ON true
WHERE c.status = 'online';

COMMENT ON VIEW v_c_readmodel_drift IS '读模型漂移检测：卡片起价与价格日历不一致即 drifted=true，说明刷新作业漏跑';

-- =====================================================================================
-- 18. 变体轴与可售单元（Variant Axes & Sellable Units）
--
-- 为什么要这一节：
--   环球影城这类商品的维度不是「商品 × 人群」两层，而是
--     人群 × 票种(1日/2日) × 园区组合(单园区/园区通票) × 加购件(快速通行证)
--   旧模型把「人群」硬编码进 ticket_type、把「日期」硬编码进 product_session，
--   维度一多就无处安放；而源侧分解方式还彼此不同：
--     Trip.com = 固定组合 SKU（一个 SKU = 一个完整组合）
--     自由行   = 参数化售卖方案（人群/园区是下单参数）
--   商品级映射 product_mapping 回答不了「这个源到底能供哪些组合」，
--   商品级路由 v_source_routing_candidates 也回答不了「这一单该走哪个源」。
--
-- 解法（三步，全部为新增，旧结构语义不变）：
--   1) 维度配置化   product_axis / product_axis_option
--      —— 维度不再往表结构里塞；人群维度沿用 ticket_type（历史订单语义不动）
--   2) 可售单元下沉 product_variant
--      —— product 的下一级不再是 ticket_type，而是「变体」；
--         旧的两层结构 = 只有人群一个轴的变体模型，是本模型的特例（可原地回填）
--   3) 覆盖语义映射 supplier_variant / supplier_variant_mapping
--      —— 源变体 → 规范变体不是一对一，而是「覆盖」；
--         coverage 回答「这个源能不能履约这个组合」，路由必须做覆盖校验
--
-- 演进说明：老数据不需要重写 —— 每个 (product, ticket_type) 生成一个 base 变体，
--           每个 supplier_ticket_type 生成一个源变体并做 1:1 覆盖映射，
--           售价/成本价回填变体 id 即可（见 db/seed.sql 第 16 节）。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 18.1 变体轴：商品有哪些可变维度（人群以外的维度全部配置化）
-- -------------------------------------------------------------------------------------
CREATE TABLE product_axis (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id  BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    axis_code   TEXT NOT NULL,          -- pass_type / park_scope / addon_type
    axis_name   TEXT NOT NULL,
    -- enum=单选枚举；set=单选但取值本身是集合（用 option_attrs.park_ids 承载）
    axis_kind   TEXT NOT NULL DEFAULT 'enum' CHECK (axis_kind IN ('enum','set')),
    is_required BOOLEAN NOT NULL DEFAULT true,
    -- 该轴是否影响价格/库存（影响则售价必须落到变体粒度）
    is_pricing  BOOLEAN NOT NULL DEFAULT true,
    sort_order  INT NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    CONSTRAINT product_axis_uk UNIQUE (product_id, axis_code)
);
CREATE INDEX ix_axis_product ON product_axis (product_id, status);
COMMENT ON TABLE product_axis IS '商品的可变维度：票种/园区范围/加购件类型…，维度配置化，不再往表结构里塞维度';

-- -------------------------------------------------------------------------------------
-- 18.2 轴取值（语言无关的结构化事实）
-- -------------------------------------------------------------------------------------
CREATE TABLE product_axis_option (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    axis_id     BIGINT NOT NULL REFERENCES product_axis(id) ON DELETE CASCADE,
    option_code TEXT NOT NULL,
    option_name TEXT NOT NULL,
    -- {"min_age":4,"max_age":11} / {"park_ids":["studio_tour","snw"]}
    option_attrs JSONB NOT NULL DEFAULT '{}'::jsonb,
    sort_order  INT NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive')),
    CONSTRAINT axis_option_uk UNIQUE (axis_id, option_code)
);
CREATE INDEX ix_axis_option_axis ON product_axis_option (axis_id, sort_order);
COMMENT ON TABLE product_axis_option IS '轴上的可选值；文案展示走 locale 表，本表只放语言无关的事实';

-- -------------------------------------------------------------------------------------
-- 18.3 规范可售变体 —— product 的下一级
-- -------------------------------------------------------------------------------------
CREATE TABLE product_variant (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id    BIGINT NOT NULL REFERENCES product(id) ON DELETE CASCADE,
    variant_code  TEXT NOT NULL,
    -- 稳定指纹：轴取值按 code 排序拼接，用于去重与外部引用
    variant_key   TEXT NOT NULL,
    title         TEXT NOT NULL,
    -- base=基础可售单元；addon=可叠加加购件（快速通行证/园区升级）；combo=打包
    variant_role  TEXT NOT NULL DEFAULT 'base' CHECK (variant_role IN ('base','addon','combo')),
    -- 人群锚点：沿用既有 ticket_type（人群维度不重复建模，历史订单语义不变）
    ticket_type_id BIGINT REFERENCES ticket_type(id) ON DELETE SET NULL,
    status        TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('draft','active','inactive','discontinued')),
    sort_order    INT NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT product_variant_uk UNIQUE (product_id, variant_code),
    CONSTRAINT product_variant_key_uk UNIQUE (product_id, variant_key)
);
CREATE INDEX ix_variant_product ON product_variant (product_id, status, sort_order);

CREATE TRIGGER trg_product_variant_updated BEFORE UPDATE ON product_variant
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE product_variant IS '规范可售单元：product 的下一级。旧的两层结构（product×ticket_type）是本表只有人群一个轴时的特例';

-- -------------------------------------------------------------------------------------
-- 18.4 变体 ↔ 轴取值（一个轴一个取值；多选语义由取值自身的集合承载）
-- -------------------------------------------------------------------------------------
CREATE TABLE product_variant_option (
    product_variant_id BIGINT NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    axis_id            BIGINT NOT NULL REFERENCES product_axis(id) ON DELETE CASCADE,
    axis_option_id     BIGINT NOT NULL REFERENCES product_axis_option(id) ON DELETE CASCADE,
    PRIMARY KEY (product_variant_id, axis_id)
);
CREATE INDEX ix_pvo_option ON product_variant_option (axis_option_id);
CREATE UNIQUE INDEX ux_pvo_option_unique ON product_variant_option (product_variant_id, axis_option_id);
COMMENT ON TABLE product_variant_option IS '变体在各轴上的取值；轴取值必须属于该商品的轴定义（不变量 27 把关）';

-- -------------------------------------------------------------------------------------
-- 18.5 变体间的可叠加关系（基础票 ← 快速通行证 / 园区升级）
-- -------------------------------------------------------------------------------------
CREATE TABLE product_variant_relation (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_variant_id BIGINT NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    child_variant_id  BIGINT NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    relation_type     TEXT NOT NULL DEFAULT 'optional_addon'
                      CHECK (relation_type IN ('optional_addon','included','supersedes')),
    -- 组合定价策略：{"mode":"separate"}=加购件单独计价；{"mode":"bundle"}=与父变体打包
    price_policy      JSONB NOT NULL DEFAULT '{}'::jsonb,
    sort_order        INT NOT NULL DEFAULT 0,
    CONSTRAINT pvr_uk UNIQUE (parent_variant_id, child_variant_id, relation_type),
    CONSTRAINT pvr_no_self CHECK (parent_variant_id <> child_variant_id)
);
CREATE INDEX ix_pvr_child ON product_variant_relation (child_variant_id);
COMMENT ON TABLE product_variant_relation IS '变体可叠加关系：园区通票=基础票+园区升级，快速通行证=基础票+加购件';

-- -------------------------------------------------------------------------------------
-- 18.6 源侧变体：固定组合型源的 SKU、参数化源的售卖方案
-- -------------------------------------------------------------------------------------
CREATE TABLE supplier_variant (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_product(id) ON DELETE CASCADE,
    external_variant_id TEXT NOT NULL,     -- 源侧 sku id / spec id / 售卖方案 id
    title               TEXT,
    -- 源侧原始轴取值（未归一）：{"audience":"adult","parks":["studio_tour"]}
    variant_attrs       JSONB NOT NULL DEFAULT '{}'::jsonb,
    raw_payload         JSONB NOT NULL DEFAULT '{}'::jsonb,
    status              TEXT NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','inactive','discontinued','pending_review')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT supplier_variant_uk UNIQUE (supplier_product_id, external_variant_id)
);
CREATE INDEX ix_sv_product ON supplier_variant (supplier_product_id, status);

CREATE TRIGGER trg_supplier_variant_updated BEFORE UPDATE ON supplier_variant
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE supplier_variant IS '源侧可售变体：Trip.com 的固定组合 SKU、自由行的参数化售卖方案';

-- -------------------------------------------------------------------------------------
-- 18.7 源变体 → 规范变体：覆盖语义映射（不是一对一）
-- -------------------------------------------------------------------------------------
CREATE TABLE supplier_variant_mapping (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_variant_id BIGINT NOT NULL REFERENCES supplier_variant(id) ON DELETE CASCADE,
    product_variant_id  BIGINT NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    -- 覆盖声明：该源变体能满足的轴取值集合
    --   {"axes":{"audience":["adult"],"pass_type":["1d"],"park_scope":["studio_only"]},
    --    "excludes":[]}
    -- 变体要求的每一项（人群 + 各轴取值）都落在 coverage.axes[axis] 内且不在 excludes 内
    -- → 该源可履约该变体。宽覆盖（一个源变体覆盖多个规范变体）用 is_exact=false 标记。
    coverage            JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_exact            BOOLEAN NOT NULL DEFAULT true,
    match_type          TEXT NOT NULL DEFAULT 'manual' CHECK (match_type IN ('auto','rule','manual')),
    confidence          NUMERIC(4,3) NOT NULL DEFAULT 1 CHECK (confidence >= 0 AND confidence <= 1),
    status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('pending_review','active','rejected')),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT svm_uk UNIQUE (supplier_variant_id, product_variant_id)
);
CREATE INDEX ix_svm_target ON supplier_variant_mapping (product_variant_id, status);
CREATE INDEX ix_svm_source ON supplier_variant_mapping (supplier_variant_id, status);

CREATE TRIGGER trg_svm_updated BEFORE UPDATE ON supplier_variant_mapping
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE supplier_variant_mapping IS '覆盖语义映射：一个源变体可覆盖多个规范变体；coverage 决定「这个源能不能履约这个组合」';

-- -------------------------------------------------------------------------------------
-- 18.8 领域服务：变体覆盖判定
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_variant_covered(p_coverage JSONB, p_variant_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM (
            -- 人群（沿用 ticket_type，不重复建模）
            SELECT 'audience' AS axis_code, tt.code AS option_code
              FROM product_variant pv
              JOIN ticket_type tt ON tt.id = pv.ticket_type_id
             WHERE pv.id = p_variant_id
            UNION ALL
            -- 变体在各个轴上的取值
            SELECT ax.axis_code, opt.option_code
              FROM product_variant_option pvo
              JOIN product_axis ax ON ax.id = pvo.axis_id
              JOIN product_axis_option opt ON opt.id = pvo.axis_option_id
             WHERE pvo.product_variant_id = p_variant_id
        ) req
        WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code)
           OR (COALESCE(p_coverage->'excludes', '[]'::jsonb) ? req.option_code)
    );
$$;
COMMENT ON FUNCTION fn_variant_covered(JSONB, BIGINT) IS '变体覆盖判定：源变体的 coverage 是否完整覆盖规范变体的全部能力（人群 + 各轴取值）';

CREATE OR REPLACE FUNCTION fn_variant_coverage_gaps(p_coverage JSONB, p_variant_id BIGINT)
RETURNS TEXT[]
LANGUAGE sql STABLE
AS $$
    SELECT COALESCE(array_agg(req.axis_code || ':' || req.option_code ORDER BY req.axis_code, req.option_code), '{}'::text[])
      FROM (
            SELECT 'audience' AS axis_code, tt.code AS option_code
              FROM product_variant pv
              JOIN ticket_type tt ON tt.id = pv.ticket_type_id
             WHERE pv.id = p_variant_id
            UNION ALL
            SELECT ax.axis_code, opt.option_code
              FROM product_variant_option pvo
              JOIN product_axis ax ON ax.id = pvo.axis_id
              JOIN product_axis_option opt ON opt.id = pvo.axis_option_id
             WHERE pvo.product_variant_id = p_variant_id
      ) req
     WHERE NOT (COALESCE(p_coverage->'axes'->req.axis_code, '[]'::jsonb) ? req.option_code)
        OR (COALESCE(p_coverage->'excludes', '[]'::jsonb) ? req.option_code);
$$;
COMMENT ON FUNCTION fn_variant_coverage_gaps(JSONB, BIGINT) IS '覆盖缺口：列出源变体缺哪些能力（运营排查用，如 "park_scope:studio_snw"）';

-- -------------------------------------------------------------------------------------
-- 18.9 把可售单元下沉到变体（全部为 ADD，旧列语义不变）
-- -------------------------------------------------------------------------------------
ALTER TABLE price_calendar         ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE supplier_price_calendar ADD COLUMN product_variant_id  BIGINT REFERENCES product_variant(id);
ALTER TABLE supplier_price_calendar ADD COLUMN supplier_variant_id BIGINT REFERENCES supplier_variant(id);
ALTER TABLE sales_order_item       ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE cart_item              ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE inventory_hold         ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE checkout_requirement   ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE booking                ADD COLUMN supplier_variant_id  BIGINT REFERENCES supplier_variant(id);
ALTER TABLE voucher                ADD COLUMN product_variant_id   BIGINT REFERENCES product_variant(id);
ALTER TABLE voucher                ADD COLUMN supplier_variant_id  BIGINT REFERENCES supplier_variant(id);

-- 计价基准：按人计价 vs 按团报价（日游的 priceSettingType=4/5）
-- per_person：total_price = unit_price * quantity（默认，历史行为不变）
-- per_group ：团总价直接落库，unit_price 记人均分摊价（允许每人 1 分以内取整误差），
--             团总价真值记在明细快照 detail_snapshot.group_total
ALTER TABLE sales_order_item ADD COLUMN pricing_basis TEXT NOT NULL DEFAULT 'per_person'
    CHECK (pricing_basis IN ('per_person','per_group'));
COMMENT ON COLUMN sales_order_item.pricing_basis IS
    '计价基准：per_person=按人计价(total=unit×qty)；per_group=按团报价(团总价落库, unit_price 为人均分摊价)';

-- 金额 CHECK 约束同步改为按计价基准分支：
-- 旧的 order_item_total_ck 只认「total = unit × qty」，对按团报价是错的（会算错钱）。
ALTER TABLE sales_order_item DROP CONSTRAINT order_item_total_ck;
ALTER TABLE sales_order_item ADD CONSTRAINT order_item_total_ck CHECK (
    CASE pricing_basis
      WHEN 'per_person' THEN total_price = unit_price * quantity
      ELSE total_price > 0 AND unit_price > 0
    END
);
COMMENT ON CONSTRAINT order_item_total_ck ON sales_order_item IS
    '按人计价：total_price = unit_price × quantity；按团报价：金额为团总价，与人数不成正比';

-- 价格保护：源侧标记该变体不得自主加价（携程 isPrivatePrice）
ALTER TABLE supplier_variant ADD COLUMN is_price_locked BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN supplier_variant.is_price_locked IS
    '源侧价格保护标记（携程 isPrivatePrice）：为真时该变体的对客售价必须原样等于源方挂牌价';

-- 平台侧的锁价落地：由源侧标记派生，锁价行的 sell_price 不得偏离源方挂牌价
ALTER TABLE price_calendar ADD COLUMN price_locked BOOLEAN NOT NULL DEFAULT false;
COMMENT ON COLUMN price_calendar.price_locked IS
    '锁价行：对客售价必须等于采纳源的挂牌价（价格保护），不允许自主加价。注意：锁价是**采纳源**的属性而非变体属性——同一变体若改由非保护源供货，售价即解锁';

-- 售价日历的唯一键必须下沉到变体：同一商品同一票种下可能并存多个变体
-- （成人·一日·单园区 / 成人·一日·园区通票），旧的 ux_price_scope 挡不住。
DROP INDEX IF EXISTS ux_price_scope;
CREATE UNIQUE INDEX ux_price_variant_scope
    ON price_calendar (product_variant_id, date, COALESCE(channel_id, 0), COALESCE(session_id, 0))
    WHERE product_variant_id IS NOT NULL;
CREATE UNIQUE INDEX ux_price_scope_legacy
    ON price_calendar (product_id, date, COALESCE(ticket_type_id, 0), COALESCE(channel_id, 0), COALESCE(session_id, 0))
    WHERE product_variant_id IS NULL;

-- 源成本价同理：一行 = 一个源变体在「某个规范组合」某个日期上的报价
-- （同一源变体覆盖多个规范变体时，各组合价格不同 —— 自由行「一日票」成人 520 / 儿童 448）
DROP INDEX IF EXISTS ux_spc_scope;
CREATE UNIQUE INDEX ux_spc_variant_scope
    ON supplier_price_calendar (supplier_variant_id, product_variant_id, date)
    WHERE supplier_variant_id IS NOT NULL;
CREATE UNIQUE INDEX ux_spc_scope_legacy
    ON supplier_price_calendar (supplier_product_id, date, COALESCE(supplier_ticket_type_id, 0), COALESCE(supplier_session_id, 0))
    WHERE supplier_variant_id IS NULL;

-- 购物车项的唯一键同理：同一商品同一票种可以同时存在多个变体（基础票 + 园区升级）
ALTER TABLE cart_item DROP CONSTRAINT cart_item_uk;
CREATE UNIQUE INDEX ux_cart_item_variant
    ON cart_item (cart_id, product_id, COALESCE(product_variant_id, 0), COALESCE(session_id, 0));

CREATE INDEX ix_pc_variant_date  ON price_calendar (product_variant_id, date);
CREATE INDEX ix_spc_supplier_variant ON supplier_price_calendar (supplier_variant_id, date);
CREATE INDEX ix_order_item_variant ON sales_order_item (product_variant_id);
CREATE INDEX ix_cart_item_variant  ON cart_item (product_variant_id);

-- 汇率留痕：售价行用的是哪一份快照、换算比例是多少，必须跟着金额一起存下来。
-- 少了这两列，成本只能靠「现在重新算一遍」来解释 —— 那不叫可对账。
-- fx_rate 的含义：1 单位源币种 = fx_rate 单位本行币种（即 cost_price = round(net_price * fx_rate, 2)）。
ALTER TABLE price_calendar ADD COLUMN fx_rate  NUMERIC(18,8);
ALTER TABLE price_calendar ADD COLUMN fx_as_of DATE;
COMMENT ON COLUMN price_calendar.fx_rate IS
    '本行成本从源币种折算到本行币种所用的汇率：1 源币种 = fx_rate 本行币种。同币种时为 1';
COMMENT ON COLUMN price_calendar.fx_as_of IS
    '折算所用的汇率快照日期；折算口径 = 该日或之前最近的一份快照（见 fn_fx_rate）';
CREATE INDEX ix_hold_variant       ON inventory_hold (product_variant_id);

-- -------------------------------------------------------------------------------------
-- 18.10 变体矩阵：商品下所有可售变体及其轴取值（前端变体选择器的数据源）
-- -------------------------------------------------------------------------------------
CREATE VIEW v_product_variant_matrix AS
SELECT
    pv.product_id,
    p.product_code,
    p.title AS product_title,
    pv.id AS product_variant_id,
    pv.variant_code,
    pv.variant_key,
    pv.title AS variant_title,
    pv.variant_role,
    tt.code AS ticket_type_code,
    tt.name AS ticket_type_name,
    (SELECT jsonb_agg(jsonb_build_object('axis', ax.axis_code, 'axis_name', ax.axis_name,
                                         'option', opt.option_code, 'option_name', opt.option_name,
                                         'attrs', opt.option_attrs)
                       ORDER BY ax.sort_order, opt.sort_order)
       FROM product_variant_option pvo
       JOIN product_axis ax ON ax.id = pvo.axis_id
       JOIN product_axis_option opt ON opt.id = pvo.axis_option_id
      WHERE pvo.product_variant_id = pv.id) AS axes,
    (SELECT count(*) FROM product_variant_relation r
      WHERE r.child_variant_id = pv.id AND r.relation_type = 'optional_addon') AS addon_count,
    pv.sort_order,
    pv.status
FROM product_variant pv
JOIN product p ON p.id = pv.product_id
LEFT JOIN ticket_type tt ON tt.id = pv.ticket_type_id;

COMMENT ON VIEW v_product_variant_matrix IS '变体矩阵：一个商品下有哪些可售组合、每个组合的轴取值与可叠加加购件';

-- -------------------------------------------------------------------------------------
-- 18.11 变体履约覆盖：每个规范变体到底有哪些源能供、缺什么
-- -------------------------------------------------------------------------------------
CREATE VIEW v_variant_source_coverage AS
SELECT
    pv.id AS product_variant_id,
    pv.variant_code,
    pv.title AS variant_title,
    pv.variant_role,
    p.product_code,
    p.title AS product_title,
    sup.code AS supplier_code,
    sv.external_variant_id,
    sv.title AS source_variant_title,
    svm.coverage,
    svm.is_exact,
    fn_variant_covered(svm.coverage, pv.id) AS can_fulfil,
    fn_variant_coverage_gaps(svm.coverage, pv.id) AS gaps
FROM supplier_variant_mapping svm
JOIN supplier_variant sv ON sv.id = svm.supplier_variant_id
JOIN supplier_product sp ON sp.id = sv.supplier_product_id
JOIN supplier sup ON sup.id = sp.supplier_id
JOIN product_variant pv ON pv.id = svm.product_variant_id
JOIN product p ON p.id = pv.product_id
WHERE svm.status = 'active';

COMMENT ON VIEW v_variant_source_coverage IS '变体级履约覆盖：can_fulfil=false 的源不得参与该变体的自动路由（缺口见 gaps）';

-- -------------------------------------------------------------------------------------
-- 6.1c-1 选源：路由与定价共用的唯一实现
--
-- 为什么必须是同一个实现：
--   路由决定「这一单走哪个源」，定价决定「这个源卖多少钱」。
--   两边各排一次序，一旦分叉，就会出现「按 A 源的价格卖、按 B 源出票」——
--   客诉与对账都无从查起。所以候选集、过滤条件、排序键都只写一份，
--   视图与定价函数都从这里取。
--
-- 排序键：折算到基准币种的成本（可比成本）→ priority → fallback_order → supplier_product_id。
--   成本第一：比价是自动选源的目的（SPEC §4.5）。
--   priority / fallback_order 只在成本相同时决定先后（越小越优先）。
--   supplier_product_id 兜底：同样的输入永远得到同样的选择（可复现）。
--
-- 候选必须同时满足：
--   - 该渠道的上架关系里挂着这个源（且 enabled）；
--   - 源变体覆盖得住这个变体（coverage 语义，覆盖不全的不许卖）；
--   - 当天有可用报价；
--   - 币种能折算到基准币种（成本可比）与目标币种（这个渠道的售价行算得出价）。
--     缺快照的源不参与比价：不可比的成本不能被当成便宜的候选。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_route_candidates(
    p_variant_id      BIGINT,
    p_date            DATE,
    p_channel_id      BIGINT,
    p_target_currency TEXT
)
RETURNS TABLE (
    supplier_product_id BIGINT,
    supplier_variant_id BIGINT,
    source_currency     TEXT,
    net_price           NUMERIC,
    supplier_price      NUMERIC,
    is_price_locked     BOOLEAN,
    source_min_margin   NUMERIC,
    cost_base           NUMERIC,
    fx_rate_to_target   NUMERIC,
    fx_as_of            DATE,
    priority            INT,
    fallback_order      INT,
    route_rank          INT
)
LANGUAGE sql STABLE AS $$
WITH ctx AS (
    SELECT cl.id AS listing_id
      FROM channel_listing cl
     WHERE cl.channel_id = p_channel_id
       AND cl.status = 'online'
       AND cl.product_id = (SELECT pv.product_id FROM product_variant pv WHERE pv.id = p_variant_id)
),
cand AS (
    SELECT spc.supplier_product_id,
           sv.id               AS supplier_variant_id,
           spc.currency        AS source_currency,
           spc.net_price,
           spc.supplier_price,
           sv.is_price_locked,
           cls.min_margin      AS source_min_margin,
           fn_convert(spc.net_price, spc.currency, fn_base_currency(), p_date) AS cost_base,
           -- 留痕因子按 8 位小数落库（price_calendar.fx_rate 是 NUMERIC(18,8)）：
           -- 函数返回值必须与落库值逐位相同，否则「行 == 函数输出」这条门禁永远差一点。
           round(fn_fx_pair_rate(spc.currency, p_target_currency, p_date), 8)    AS fx_rate_to_target,
           fn_fx_pair_snapshot_date(spc.currency, p_target_currency, p_date)    AS fx_as_of,
           cls.priority,
           cls.fallback_order
      FROM ctx
      JOIN supplier_variant_mapping svm
        ON svm.product_variant_id = p_variant_id AND svm.status = 'active'
      JOIN supplier_variant sv
        ON sv.id = svm.supplier_variant_id AND sv.status = 'active'
      JOIN supplier_price_calendar spc
        ON spc.supplier_variant_id = sv.id
       AND spc.product_variant_id = p_variant_id
       AND spc.date = p_date
       AND spc.status = 'available'
      JOIN channel_listing_source cls
        ON cls.channel_listing_id = ctx.listing_id
       AND cls.supplier_product_id = spc.supplier_product_id
       AND cls.enabled
     WHERE fn_variant_covered(svm.coverage, p_variant_id)
       AND fn_fx_rate(spc.currency, p_date) IS NOT NULL
       AND fn_fx_pair_rate(spc.currency, p_target_currency, p_date) IS NOT NULL
)
SELECT c.supplier_product_id,
       c.supplier_variant_id,
       c.source_currency,
       c.net_price,
       c.supplier_price,
       c.is_price_locked,
       c.source_min_margin,
       c.cost_base,
       c.fx_rate_to_target,
       c.fx_as_of,
       c.priority,
       c.fallback_order,
       ROW_NUMBER() OVER (ORDER BY c.cost_base, c.priority, c.fallback_order,
                                   c.supplier_product_id) AS route_rank
  FROM cand c;
$$;

COMMENT ON FUNCTION fn_route_candidates(BIGINT, DATE, BIGINT, TEXT)
  IS '选源的唯一实现：路由视图与定价函数共用同一候选集与同一排序键；route_rank=1 即首选源';

-- -------------------------------------------------------------------------------------
-- 18.12 变体级路由候选：自动选源的第二代，粒度到可售组合
--      与 v_source_routing_candidates 的区别：键是变体而不是 (商品, 票种)，
--      且强制做覆盖校验 —— 覆盖不全的源不进候选，避免卖出履约不了的票。
--
--      候选与排序来自 fn_route_candidates —— 视图不再自己排一次序，
--      否则「路由选中的源」和「定价采用的源」迟早分叉（见不变量 43）。
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_variant_routing_candidates AS
SELECT
    cl.channel_id,
    ch.code                AS channel_code,
    pv.id                  AS product_variant_id,
    pv.variant_code,
    pv.title               AS variant_title,
    p.product_code,
    p.title                AS product_title,
    pc.date,
    sup.code               AS supplier_code,
    rc.supplier_variant_id,
    sv.external_variant_id,
    svm.coverage,
    rc.source_currency,
    rc.supplier_price,
    rc.net_price,
    fn_fx_rate(rc.source_currency, pc.date) AS fx_rate,
    rc.cost_base,
    fn_base_currency()     AS base_currency,
    rc.priority,
    rc.fallback_order,
    sp.availability_mode,
    rc.route_rank
FROM channel_listing cl
JOIN channel ch          ON ch.id = cl.channel_id
JOIN product_variant pv   ON pv.product_id = cl.product_id AND pv.status = 'active'
JOIN product p            ON p.id = pv.product_id
JOIN (SELECT DISTINCT product_variant_id, date
        FROM price_calendar
       WHERE channel_id IS NULL AND status = 'active') pc
  ON pc.product_variant_id = pv.id
JOIN supplier_variant_mapping svm ON svm.product_variant_id = pv.id AND svm.status = 'active'
JOIN supplier_variant sv  ON sv.id = svm.supplier_variant_id AND sv.status = 'active'
JOIN supplier_product sp   ON sp.id = sv.supplier_product_id
JOIN supplier sup          ON sup.id = sp.supplier_id
JOIN LATERAL fn_route_candidates(
         pv.id,
         pc.date,
         cl.channel_id,
         -- 目标币种 = 这一行要按哪个币种卖：默认行归自营渠道（基准币种），
         -- 渠道专属行按该渠道的结算币种。
         CASE WHEN cl.channel_id = fn_default_context_channel()
              THEN fn_base_currency()
              ELSE ch.default_currency END) rc
  ON rc.supplier_variant_id = sv.id;

COMMENT ON VIEW v_variant_routing_candidates IS '变体级选源候选：route_rank=1 即该变体的首选源；覆盖不全的源已被过滤在外；排序口径与定价函数同源（fn_route_candidates）';

-- -------------------------------------------------------------------------------------
-- 6.1c 定价：选源 + 定价的唯一实现
--
-- 原来这件事有三份实现：两个 SQL 视图、scripts/mapping_dryrun.py 里一段 Python，
-- 外加 db/seed.sql 里手写的售价数字。三份口径不一致，Python 那份还拿浮点算钱、
-- 根本不折算汇率 —— 同一批源数据，三个地方给出三个价格。
--
-- 现在定价只有这一份实现，就在这个函数里。理由不是「函数比较优雅」：
--   - 钱必须是 NUMERIC（AGENTS.md 硬约束 5），Go 标准库没有十进制类型，
--     Python 那份已经在用 float() 算钱 —— 浮点算钱迟早差一分钱；
--   - 视图、Go 接入层、演练器都要用同一套口径，那就只能放在三者都够得着的地方。
--
-- 参数：
--   p_variant_id         算哪个变体
--   p_date               算哪一天的价格
--   p_context_channel_id 规则与可选源来自这个渠道的上架关系（channel_listing）
--   p_price_channel_id   售价行写给哪个渠道；NULL = 默认行（基准币种）
--
-- 定价口径（合同见 SPEC.md §4.6）：
--   1. 候选与排序 = fn_route_candidates（选源的唯一实现，与路由视图同源）：
--      该渠道上架过、覆盖得住这个变体、当天有报价、且币种能折算的源，
--      按「折算到基准币种的成本 → priority → fallback_order → supplier_product_id」排序。
--      缺汇率快照的源不参与比价 —— 不可比的成本不能被当成便宜的候选。
--   2. 采纳 = route_rank = 1 的候选。定价与路由必须选出同一个源，
--      否则会「按 A 源的价格卖、按 B 源出票」（不变量 43 就是守这一条）。
--   3. 锁价（采纳源是价格保护源）：售价 = 源方挂牌价折算到目标币种。
--      不加价、不套 min_margin、不套 floor；划线价 = 售价。
--   4. 按团报价（mode=per_group）：售价 = 源方团报价折算到目标币种，同样不加价。
--      团总价的毛利口径与单份不同，由商务单独约定，所以不套 min_margin。
--   5. 成本加价（mode=cost_plus，默认）：
--      售价 = max(成本 × (1 + percent/100), 成本 / (1 - min_margin), floor)。
--   6. min_margin 的生效值 = max(channel_listing.price_policy.min_margin,
--      采纳源的 channel_listing_source.min_margin) —— 渠道底线与该源的底线取严的。
--   7. 划线价 = 售价 × (1 + list_markup_percent)，缺省 0（即划线价 = 售价）。
--      锁价与按团报价行不虚构划线价（源方定价，平台不能编一个更高的「原价」）。
--   8. 币种：渠道专属价用该渠道的 default_currency，默认行用基准币种。
--      口径只有一处：fn_price_row_currency(channel_id)。
--   9. 汇率留痕：fx_rate = 1 单位源币种 = fx_rate 单位本行币种；
--      fx_as_of = 这一折算实际依赖的快照日期（两腿取较晚的那一天）。
--      同币种不折算 → fx_rate = 1、fx_as_of = NULL（没折算过就不假装折算过）。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_price_variant(
    p_variant_id         BIGINT,
    p_date               DATE,
    p_context_channel_id BIGINT,
    p_price_channel_id   BIGINT DEFAULT NULL
)
RETURNS TABLE (
    product_id          BIGINT,
    product_variant_id  BIGINT,
    date                DATE,
    currency            TEXT,
    supplier_product_id BIGINT,
    source_currency     TEXT,
    net_price           NUMERIC,
    fx_rate             NUMERIC,
    fx_as_of            DATE,
    cost_price          NUMERIC,
    sell_price          NUMERIC,
    list_price          NUMERIC,
    discount_pct        NUMERIC,
    price_locked        BOOLEAN,
    min_margin          NUMERIC,
    rule                JSONB
)
LANGUAGE sql STABLE AS $$
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
one AS (
    SELECT c.*,
           GREATEST(c.listing_min_margin, COALESCE(c.source_min_margin, 0)) AS effective_min_margin,
           (c.is_price_locked AND fn_bool_setting('price_locked_uses_source_list_price', true)) AS locked
    FROM cand c
),
calc AS (
    SELECT o.*,
           CASE
             WHEN o.locked
               THEN round(fn_convert(o.supplier_price, o.source_currency, o.target_currency, p_date), 2)
             WHEN o.mode = 'per_group'
               THEN round(fn_convert(o.supplier_price, o.source_currency, o.target_currency, p_date), 2)
             ELSE round(GREATEST(
                    o.cost_in_target * (1 + o.percent / 100),
                    CASE WHEN o.effective_min_margin > 0 AND o.effective_min_margin < 1
                         THEN o.cost_in_target / (1 - o.effective_min_margin)
                         ELSE o.cost_in_target END,
                    COALESCE(o.floor_price, o.cost_in_target)
             ), 2)
           END AS sell_price
    FROM one o
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
       c.price_policy AS rule
FROM calc c;
$$;

-- -------------------------------------------------------------------------------------
-- 6.1d 重新定价：把所有在售售价行按定价函数重算一遍
--
-- 什么时候用：
--   - 源成本变了、汇率快照换了、上架规则改了 → 重算对客售价；
--   - 种子数据 / 演练数据灌完之后 → 一次性把所有骨架行定价。
--
-- 为什么是函数而不是一段脚本：
--   演练器、接入层、种子数据都要重算同一批行。脚本有三份就会有三份口径，
--   而三份口径不会互相提醒 —— 门禁查得出「行 != 函数」，查不出「三份函数各不相同」。
-- -------------------------------------------------------------------------------------
CREATE FUNCTION fn_reprice_rows() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
  v_rows INTEGER;
BEGIN
  UPDATE price_calendar pc
     SET cost_price             = q.cost_price,
         cost_source_product_id = q.supplier_product_id,
         sell_price             = q.sell_price,
         list_price             = q.list_price,
         discount_pct           = q.discount_pct,
         price_locked           = COALESCE(q.price_locked, false),
         rule                   = COALESCE(q.rule, '{}'::jsonb),
         fx_rate                = q.fx_rate,
         fx_as_of               = q.fx_as_of,
         source                 = 'calc',
         synced_at              = now()
    FROM (SELECT id, product_variant_id, date, channel_id
            FROM price_calendar
           WHERE status = 'active'
             AND product_variant_id IS NOT NULL) p
    -- LEFT JOIN 而不是 CROSS JOIN：定价算不出来的那一行（源当天没报价、上架关系下线、
    -- 缺汇率快照）必须把价格清空，不能留着上一轮的价格继续卖。
    -- CROSS JOIN 会把这种行整行跳过 —— 价格停在旧值，等于卖一个已经买不到的东西。
    LEFT JOIN LATERAL fn_price_variant(p.product_variant_id,
                                       p.date,
                                       COALESCE(p.channel_id, fn_default_context_channel()),
                                       p.channel_id) q
      ON true
   WHERE pc.id = p.id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END $$;

-- -------------------------------------------------------------------------------------
-- 18.13 C 端读模型：变体级日历格子
-- -------------------------------------------------------------------------------------
CREATE TABLE c_variant_calendar (
    channel_id        BIGINT NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    product_variant_id BIGINT NOT NULL REFERENCES product_variant(id) ON DELETE CASCADE,
    date              DATE NOT NULL,
    price_min         NUMERIC(12,2),
    price_max         NUMERIC(12,2),
    status            TEXT NOT NULL DEFAULT 'available'
                      CHECK (status IN ('available','sold_out','limited','closed','pending')),
    source_count      INT NOT NULL DEFAULT 0,   -- 有几个源能履约这个变体
    synced_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (channel_id, product_variant_id, date)
);
CREATE INDEX ix_cvc_variant_date ON c_variant_calendar (product_variant_id, date);
COMMENT ON TABLE c_variant_calendar IS 'C 端变体级日历：同一天不同变体的价格与可履约源数不同，日历必须按变体出格';

-- 卡片起价不应把加购件算进去（加购件不是「入门价」）
CREATE OR REPLACE VIEW v_c_readmodel_drift AS
SELECT
    c.channel_id,
    c.product_id,
    c.from_price       AS card_from_price,
    COALESCE(t.chan_min, t.base_min) AS truth_min_price,
    (c.from_price IS DISTINCT FROM COALESCE(t.chan_min, t.base_min)) AS drifted,
    c.synced_at,
    now() AS computed_at
FROM c_product_card c
LEFT JOIN LATERAL (
    SELECT
        MIN(pc.sell_price) FILTER (WHERE pc.channel_id = c.channel_id) AS chan_min,
        MIN(pc.sell_price) FILTER (WHERE pc.channel_id IS NULL)       AS base_min
    FROM price_calendar pc
    WHERE pc.product_id = c.product_id
      AND pc.status = 'active'
      AND pc.date >= current_date
      AND pc.date <= current_date + 30
      AND (pc.channel_id = c.channel_id OR pc.channel_id IS NULL)
      AND NOT EXISTS (SELECT 1 FROM product_variant pv
                       WHERE pv.id = pc.product_variant_id AND pv.variant_role = 'addon')
) t ON true
WHERE c.status = 'online';

-- =====================================================================================
-- 19. 扩充不变量断言（21-34）
-- =====================================================================================
CREATE OR REPLACE VIEW v_invariant_checks AS
WITH raw(seq, check_name, actual) AS (
  SELECT 1, '规范商品必须有至少一个 active 源映射',
         (SELECT count(*) FROM product p WHERE NOT EXISTS (
            SELECT 1 FROM product_mapping m WHERE m.product_id = p.id AND m.status = 'active'))
  UNION ALL
  SELECT 2, '同一商品同一供应商最多一个 primary 映射',
         (SELECT count(*) FROM (SELECT 1 FROM product_mapping WHERE is_primary
                                GROUP BY product_id, supplier_id HAVING count(*) > 1) x)
  UNION ALL
  SELECT 3, '场次源绑定的源商品必须映射到同一规范商品',
         (SELECT count(*) FROM product_session_source pss
            JOIN product_session ps ON ps.id = pss.product_session_id
            JOIN supplier_product sp ON sp.id = pss.supplier_product_id
           WHERE NOT EXISTS (SELECT 1 FROM product_mapping m
                              WHERE m.supplier_product_id = sp.id
                                AND m.product_id = ps.product_id AND m.status = 'active'))
  UNION ALL
  SELECT 4, '订单金额自洽 total = subtotal - discount + tax',
         (SELECT count(*) FROM sales_order WHERE total <> subtotal - discount + tax)
  UNION ALL
  -- 5. 订单明细金额自洽
  --    per_person（按人计价）：total_price = unit_price * quantity
  --    per_group（按团报价）：团总价直接落库，unit_price 是人均分摊价，
  --      允许每人 1 分以内的分摊取整误差；团总价的真值记在明细快照 group_total
  SELECT 5, '订单明细金额自洽（按人计价 total=unit×qty；按团计价 团总价来自快照）',
         (SELECT count(*) FROM sales_order_item oi
           WHERE CASE oi.pricing_basis
             WHEN 'per_person' THEN oi.total_price <> oi.unit_price * oi.quantity
             ELSE NOT (oi.total_price > 0
                       AND oi.unit_price > 0
                       AND abs(oi.total_price - oi.unit_price * oi.quantity) <= oi.quantity * 0.01
                       AND oi.total_price = COALESCE(
                             (NULLIF(oi.detail_snapshot->>'group_total',''))::numeric, oi.total_price))
           END)
  UNION ALL
  SELECT 6, '订单行 supplier_id 与 supplier_product 所属供应商一致',
         (SELECT count(*) FROM sales_order_item oi JOIN supplier_product sp ON sp.id = oi.supplier_product_id
           WHERE sp.supplier_id <> oi.supplier_id)
  UNION ALL
  SELECT 7, '已确认预订必须有 external_booking_id',
         (SELECT count(*) FROM booking WHERE status = 'confirmed' AND external_booking_id IS NULL)
  UNION ALL
  SELECT 8, '同源同票码不得重复出票',
         (SELECT count(*) FROM (SELECT 1 FROM voucher WHERE code IS NOT NULL
                                GROUP BY supplier_id, code HAVING count(*) > 1) x)
  UNION ALL
  SELECT 9, '权益消耗数不得超过发放数',
         (SELECT count(*) FROM voucher_entitlement WHERE consumed_quantity > quantity)
  UNION ALL
  SELECT 10, '对客售价必须 ≥ 采纳成本（不得亏本销售）',
         (SELECT count(*) FROM price_calendar
           WHERE cost_price IS NOT NULL AND sell_price IS NOT NULL AND sell_price < cost_price)
  UNION ALL
  SELECT 11, '已支付订单必须有 succeeded 支付记录',
         (SELECT count(*) FROM sales_order o WHERE o.payment_status = 'paid'
           AND NOT EXISTS (SELECT 1 FROM sales_payment p WHERE p.order_id = o.id AND p.status = 'succeeded'))
  UNION ALL
  SELECT 12, '已履约订单必须有 issued/used 状态凭证',
         (SELECT count(*) FROM sales_order o WHERE o.fulfillment_status = 'fulfilled'
           AND NOT EXISTS (SELECT 1 FROM voucher v WHERE v.order_id = o.id AND v.status IN ('issued','used')))
  UNION ALL
  SELECT 13, '映射的 supplier_id 与源商品所属供应商一致',
         (SELECT count(*) FROM product_mapping m JOIN supplier_product sp ON sp.id = m.supplier_product_id
           WHERE m.supplier_id <> sp.supplier_id)
  UNION ALL
  SELECT 14, '所有在用币种（非基准币种）必须有汇率快照',
         (SELECT count(*) FROM (SELECT DISTINCT currency FROM supplier_price_calendar) c
           WHERE c.currency <> 'CNY'
             AND NOT EXISTS (SELECT 1 FROM fx_rate f
                              WHERE f.quote_currency = c.currency AND f.base_currency = 'CNY'))
  UNION ALL
  SELECT 15, '每个 online 渠道上架必须绑定至少一个启用源',
         (SELECT count(*) FROM channel_listing cl
           WHERE cl.status = 'online'
             AND NOT EXISTS (SELECT 1 FROM channel_listing_source cls
                             WHERE cls.channel_listing_id = cl.id AND cls.enabled))
  UNION ALL
  SELECT 16, '售价日历的采纳成本必须可追溯到具体源',
         (SELECT count(*) FROM price_calendar pc
           WHERE pc.cost_price IS NOT NULL AND pc.cost_source_product_id IS NULL)
  UNION ALL
  SELECT 17, 'booking.attempt_count 不得小于实际尝试记录数',
         (SELECT count(*) FROM booking b
           WHERE b.attempt_count < (SELECT count(*) FROM booking_attempt ba WHERE ba.booking_id = b.id))
  UNION ALL
  SELECT 18, '渠道内订单幂等键不得重复',
         (SELECT count(*) FROM (SELECT 1 FROM sales_order WHERE idempotency_key IS NOT NULL
                                GROUP BY channel_id, idempotency_key HAVING count(*) > 1) x)
  UNION ALL
  SELECT 19, '库存快照与可用性缓存的供应商必须存在',
         (SELECT count(*) FROM availability_cache ac
           WHERE NOT EXISTS (SELECT 1 FROM supplier s WHERE s.id = ac.supplier_id))
  UNION ALL
  SELECT 20, '已出票凭证必须归属某个已确认预订',
         (SELECT count(*) FROM voucher v WHERE v.status IN ('issued','used')
           AND (v.booking_id IS NULL
                OR NOT EXISTS (SELECT 1 FROM booking b
                                WHERE b.id = v.booking_id AND b.status IN ('confirmed','ticketed'))))
  UNION ALL
  -- 21. 购物车项若挂了库存预占，预占数量必须等于购物数量
  SELECT 21, '购物车项的库存预占数量必须一致',
         (SELECT count(*) FROM cart_item ci JOIN inventory_hold h ON h.id = ci.hold_id
           WHERE h.quantity <> ci.quantity)
  UNION ALL
  -- 22. 活跃预占必须挂在某个购物车或订单上（不能凭空占库存）
  SELECT 22, '活跃库存预占必须关联购物车或订单',
         (SELECT count(*) FROM inventory_hold h
           WHERE h.status = 'active' AND h.cart_id IS NULL AND h.order_id IS NULL)
  UNION ALL
  -- 23. 优惠券使用次数不得超过发放上限
  SELECT 23, '优惠券使用次数不得超过发放上限',
         (SELECT count(*) FROM coupon WHERE usage_limit IS NOT NULL AND used_count > usage_limit)
  UNION ALL
  -- 24. 使用了优惠券的订单必须有对应的核销记录
  SELECT 24, '订单引用的优惠券必须有核销记录',
         (SELECT count(*) FROM sales_order o WHERE o.coupon_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM coupon_redemption cr WHERE cr.order_id = o.id AND cr.status = 'used'))
  UNION ALL
  -- 25. 需要实名的票种，持票人数必须与票数一致（按订单所属渠道判定适用范围）
  SELECT 25, '要求实名的票种持票人数必须与票数一致',
         (SELECT count(*) FROM sales_order_item oi
           JOIN sales_order o ON o.id = oi.order_id
           JOIN checkout_requirement cr ON cr.product_id = oi.product_id
                                      AND (cr.ticket_type_id IS NULL OR cr.ticket_type_id = oi.ticket_type_id)
                                      AND (cr.channel_id IS NULL OR cr.channel_id = o.channel_id)
          WHERE cr.field_code = 'holder_name' AND cr.required
            AND (SELECT count(DISTINCT oh.sequence) FROM order_holder oh
                  WHERE oh.order_item_id = oi.id AND oh.field_code = 'holder_name') <> oi.quantity)
  UNION ALL
  -- 26. C 端读模型必须有价格日历背书（卡片起价不得脱离价格日历）
  SELECT 26, 'C端读模型卡片的起价必须能追溯到价格日历',
         (SELECT count(*) FROM c_product_card c
           WHERE c.status = 'online' AND c.from_price IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM price_calendar pc
                              WHERE pc.product_id = c.product_id AND pc.status = 'active'
                                AND (pc.channel_id = c.channel_id OR pc.channel_id IS NULL)
                                AND pc.date >= current_date AND pc.date <= current_date + 30))
  UNION ALL
  -- 27. 变体的轴取值必须属于该商品的轴定义（跨商品串轴 = 脏数据）
  SELECT 27, '变体轴取值必须属于该商品的轴定义',
         (SELECT count(*) FROM product_variant_option pvo
            JOIN product_variant pv ON pv.id = pvo.product_variant_id
            JOIN product_axis ax ON ax.id = pvo.axis_id
           WHERE ax.product_id <> pv.product_id)
  UNION ALL
  -- 28. 同一商品内 variant_key 不得重复（变体指纹是去重与外部引用的锚）
  SELECT 28, '同一商品内变体指纹不得重复',
         (SELECT count(*) FROM (SELECT 1 FROM product_variant
                                GROUP BY product_id, variant_key HAVING count(*) > 1) x)
  UNION ALL
  -- 29. active 变体必须有能力定义（人群或至少一个轴取值），不允许空变体占位
  SELECT 29, '在售变体必须有人群或轴取值定义',
         (SELECT count(*) FROM product_variant pv
           WHERE pv.status = 'active' AND pv.ticket_type_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM product_variant_option pvo
                              WHERE pvo.product_variant_id = pv.id))
  UNION ALL
  -- 30. 覆盖映射必须真的覆盖目标变体的全部能力（覆盖不全不得挂 active）
  SELECT 30, '源变体覆盖映射必须完整覆盖目标变体',
         (SELECT count(*) FROM supplier_variant_mapping svm
           WHERE svm.status = 'active'
             AND NOT fn_variant_covered(svm.coverage, svm.product_variant_id))
  UNION ALL
  -- 31. 在售售价日历必须绑定变体（售价粒度不得停留在商品/票种层）
  SELECT 31, '在售售价日历必须绑定变体',
         (SELECT count(*) FROM price_calendar
           WHERE status = 'active' AND product_variant_id IS NULL)
  UNION ALL
  -- 32. 订单明细的变体商品必须与明细商品一致
  SELECT 32, '订单明细的变体必须与明细商品一致',
         (SELECT count(*) FROM sales_order_item oi
            JOIN product_variant pv ON pv.id = oi.product_variant_id
           WHERE pv.product_id <> oi.product_id)
  UNION ALL
  -- 33. 加购件变体必须挂在至少一个基础变体上（不得成为孤儿）
  SELECT 33, '加购件变体必须挂在基础变体上',
         (SELECT count(*) FROM product_variant pv
           WHERE pv.variant_role = 'addon' AND pv.status = 'active'
             AND NOT EXISTS (SELECT 1 FROM product_variant_relation r
                              WHERE r.child_variant_id = pv.id
                                AND r.relation_type = 'optional_addon'))
  UNION ALL
  -- 34. 有售价的变体在其上架渠道必须至少有一个可履约源（防止卖出履约不了的组合）
  SELECT 34, '有售价的变体在其上架渠道必须至少有一个可履约源',
         (SELECT count(*) FROM (
            SELECT DISTINCT cl.channel_id, pc.product_variant_id
              FROM channel_listing cl
              JOIN price_calendar pc ON pc.product_id = cl.product_id
                                     AND pc.channel_id IS NULL
                                     AND pc.status = 'active'
             WHERE pc.product_variant_id IS NOT NULL
               -- 只管「正在卖」的变体。源被停用后重算会把这些行的售价清空，
               -- 那时它们已经不卖了，不该再算作违规 —— 留着的是一条待清理的骨架行。
               AND pc.sell_price IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM v_variant_routing_candidates vrc
                                WHERE vrc.channel_id = cl.channel_id
                                  AND vrc.product_variant_id = pc.product_variant_id)
          ) x)
  UNION ALL
  -- 35. 同一订单内同一商品的多个变体必须使用同一日期
  --     （对应携程错误码 B0042「多资源使用日期不一致」：一个订单里多个资源必须同日可用）
  --     作用域限定在同一商品内：跨商品的购物车订单日期不同是合法的。
  SELECT 35, '同一订单内同一商品的多个变体必须使用同一日期',
         (SELECT count(*) FROM (
            SELECT oi.order_id
              FROM sales_order_item oi
              JOIN product_session ps ON ps.id = oi.session_id
             GROUP BY oi.order_id, oi.product_id
            HAVING count(DISTINCT ps.session_date) > 1
          ) x)
  UNION ALL
  -- 36. 订单小计必须等于明细金额之和（按人计价与按团计价都适用）
  SELECT 36, '订单小计必须等于明细金额之和',
         (SELECT count(*) FROM (
            SELECT o.id
              FROM sales_order o
              JOIN sales_order_item oi ON oi.order_id = o.id
             GROUP BY o.id, o.subtotal
            HAVING o.subtotal <> sum(oi.total_price)
          ) x)
  UNION ALL
  -- 37. 锁价售价必须等于采纳源的挂牌价（携程 isPrivatePrice 价格保护）
  --     锁价不是变体的固定属性，而是「采纳源」的属性：
  --     锁价行必须存在一条「同源 + 同变体 + 同日 + 该源变体是价格保护源 + 售价=挂牌价」的记录。
  --     挂牌价在源币种，售价在本行币种 —— 必须先折算再比。
  --     （以前这里直接拿源币种的挂牌价跟本行币种的售价比，源币种与本行币种不同的锁价行
  --       会被误判成违规，或者更糟：真的相等的行被误判成不一致。）
  SELECT 37, '锁价售价必须等于采纳源的挂牌价',
         (SELECT count(*) FROM price_calendar pc
           WHERE pc.price_locked AND pc.status = 'active'
             AND NOT EXISTS (
               SELECT 1
                 FROM supplier_price_calendar spc
                 JOIN supplier_variant sv ON sv.id = spc.supplier_variant_id AND sv.is_price_locked
                WHERE spc.supplier_product_id = pc.cost_source_product_id
                  AND spc.product_variant_id = pc.product_variant_id
                  AND spc.date = pc.date
                  AND spc.status = 'available'
                  AND pc.sell_price = round(fn_convert(spc.supplier_price, spc.currency, pc.currency, pc.date), 2)))
  UNION ALL
  -- 38. 反向门禁：采纳了价格保护源的售价行必须锁价（防止漏锁导致擅自加价）
  SELECT 38, '采纳价格保护源的售价行必须锁价',
         (SELECT count(*) FROM price_calendar pc
           JOIN supplier_price_calendar spc
             ON spc.supplier_product_id = pc.cost_source_product_id
            AND spc.product_variant_id = pc.product_variant_id
            AND spc.date = pc.date
            AND spc.status = 'available'
           JOIN supplier_variant sv ON sv.id = spc.supplier_variant_id
          WHERE pc.status = 'active' AND sv.is_price_locked AND NOT pc.price_locked)
  UNION ALL
  -- 39. 在售源价格的币种必须可折算
  --     缺快照的币种没法和别的币种比价。以前这里是 COALESCE(rate, 1)：
  --     新币种上线当天没配汇率，价格会以 1:1 参与比价，选出一个便宜到不可能的源。
  --     现在这类行不进比价，这条不变量负责把它们喊出来。
  SELECT 39, '在售源价格的币种必须可折算到基准币种',
         (SELECT count(*) FROM supplier_price_calendar spc
           WHERE spc.status = 'available'
             AND fn_fx_rate(spc.currency, spc.date) IS NULL)
  UNION ALL
  -- 40. 售价行的成本必须等于采纳源成本按留痕汇率折算的结果
  --     声明了采纳源的售价行，必须同时满足：
  --       a) 那天那个源确实有报价（否则成本是凭空捏的）；
  --       b) cost_price = round(net_price * 留痕汇率, 2) —— 留痕汇率与成本自洽；
  --       c) cost_price = round(按当日快照折算, 2)      —— 留痕汇率与快照口径一致。
  --     这条同时挡住四类事故：漏折算（直接拿源币种数字当成本）、
  --     汇率快照换了但售价没重算、手算差一分钱、以及「成本来源那天根本没报价」。
  SELECT 40, '售价行的成本必须等于采纳源成本按留痕汇率折算的结果',
         (SELECT count(*) FROM price_calendar pc
           LEFT JOIN supplier_price_calendar spc
             ON spc.supplier_product_id = pc.cost_source_product_id
            AND spc.product_variant_id IS NOT DISTINCT FROM pc.product_variant_id
            AND spc.date = pc.date
            AND spc.status = 'available'
          WHERE pc.status = 'active'
            AND pc.cost_source_product_id IS NOT NULL
            AND (spc.id IS NULL
              OR pc.fx_rate IS NULL
              OR pc.cost_price IS DISTINCT FROM round(spc.net_price * pc.fx_rate, 2)
              OR pc.cost_price IS DISTINCT FROM round(fn_convert(spc.net_price, spc.currency, pc.currency, pc.date), 2)))
  UNION ALL
  -- 41. 在售售价行必须等于定价函数的输出
  --     定价只有一份实现（fn_price_variant）。库里这一行的金额如果是从别的路径写进去的
  --     （手写、旧脚本、另一个视图），成本和「按规则算出来的价」就会分叉，
  --     而两条分叉的线各自都能自圆其说 —— 只有拿函数重新算一遍才能发现。
  --     定价函数算不出结果的行（源当天没报价、上架关系下线、缺汇率快照）必须没有价格，
  --     否则就是「卖一个已经买不到的东西」。
  SELECT 41, '在售售价行必须等于定价函数的输出',
         (SELECT count(*)
            FROM price_calendar pc
            LEFT JOIN LATERAL fn_price_variant(pc.product_variant_id,
                                              pc.date,
                                              COALESCE(pc.channel_id, fn_default_context_channel()),
                                              pc.channel_id) v
              ON true
           WHERE pc.status = 'active'
             AND pc.product_variant_id IS NOT NULL
             AND ( (v.product_variant_id IS NULL
                    AND (pc.sell_price IS NOT NULL OR pc.cost_price IS NOT NULL))
                OR (v.product_variant_id IS NOT NULL
                    AND (pc.cost_price             IS DISTINCT FROM v.cost_price
                      OR pc.sell_price             IS DISTINCT FROM v.sell_price
                      OR pc.list_price             IS DISTINCT FROM v.list_price
                      OR pc.discount_pct           IS DISTINCT FROM v.discount_pct
                      OR pc.price_locked           IS DISTINCT FROM v.price_locked
                      OR pc.cost_source_product_id IS DISTINCT FROM v.supplier_product_id))))
  UNION ALL
  -- 42. 非锁价售价行的毛利率必须达到生效 min_margin
  --     生效 min_margin = max(渠道的 price_policy.min_margin, 采纳源的 channel_listing_source.min_margin)，
  --     两者取严。锁价行豁免（源方定价，平台无权加价）；按团报价行豁免
  --     （团总价的毛利口径与单份不同，由商务单独约定）。
  SELECT 42, '非锁价售价行的毛利率必须达到生效 min_margin',
         (SELECT count(*)
            FROM price_calendar pc
            JOIN channel_listing cl
              ON cl.product_id = pc.product_id
             AND cl.channel_id = COALESCE(pc.channel_id, fn_default_context_channel())
             AND cl.status = 'online'
            JOIN channel_listing_source cls
              ON cls.channel_listing_id = cl.id
             AND cls.supplier_product_id = pc.cost_source_product_id
             AND cls.enabled
           WHERE pc.status = 'active'
             AND NOT pc.price_locked
             AND COALESCE(NULLIF(cl.price_policy->>'mode', ''), 'cost_plus') = 'cost_plus'
             AND round((pc.sell_price - pc.cost_price) / NULLIF(pc.sell_price, 0), 6)
                 < GREATEST(COALESCE(NULLIF(cl.price_policy->>'min_margin', '')::numeric, 0),
                            COALESCE(cls.min_margin, 0)))
  UNION ALL
  -- 43. 定价采用的源必须就是路由选中的源
  --     路由决定「这一单走哪个源出票」，定价决定「这个源卖多少钱」。
  --     两边各排一次序，一旦分叉，就会出现「按 A 源的价格卖、按 B 源出票」——
  --     客诉、对账、佣金三头对不上，而且现场很难复现。
  --     现在两边共用 fn_route_candidates，这条不变量守住「共用的实现没被改回两份」。
  SELECT 43, '定价采用的源必须是路由选中的源',
         (SELECT count(*)
            FROM price_calendar pc
           WHERE pc.status = 'active'
             AND pc.product_variant_id IS NOT NULL
             AND pc.cost_source_product_id IS DISTINCT FROM (
                   SELECT rc.supplier_product_id
                     FROM fn_route_candidates(pc.product_variant_id,
                                              pc.date,
                                              COALESCE(pc.channel_id, fn_default_context_channel()),
                                              fn_price_row_currency(pc.channel_id)) rc
                    WHERE rc.route_rank = 1))
  UNION ALL
  -- 44. 售价行的币种必须等于该行的结算币种
  --     渠道专属行按该渠道的结算币种卖，默认行按基准币种卖。
  --     这一列以前是手填的：填错币种，售价就是「一个币种的数字标成另一个币种」，
  --     差个汇率就是差几十块，而且没人看得出来。
  SELECT 44, '售价行的币种必须等于该行的结算币种',
         (SELECT count(*) FROM price_calendar pc
           WHERE pc.status = 'active'
             AND pc.product_variant_id IS NOT NULL
             AND pc.currency IS DISTINCT FROM fn_price_row_currency(pc.channel_id))
  UNION ALL
  -- 45. 汇率留痕必须自洽：留痕日期能独立复算出同一个折算因子
  --     fx_rate 的口径是「1 单位源币种 = fx_rate 单位本行币种」，fx_as_of 是这次折算
  --     实际依赖的快照日期。两腿都有快照时取较晚的那一天，用它重算必然复现同一个因子。
  --     同币种不折算 → fx_rate = 1、fx_as_of = NULL：没折算过就不留假快照。
  SELECT 45, '售价行留痕的汇率与快照必须自洽',
         (SELECT count(*)
            FROM price_calendar pc
            JOIN supplier_price_calendar spc
              ON spc.supplier_product_id = pc.cost_source_product_id
             AND spc.product_variant_id IS NOT DISTINCT FROM pc.product_variant_id
             AND spc.date = pc.date
             AND spc.status = 'available'
           WHERE pc.status = 'active'
             AND pc.cost_source_product_id IS NOT NULL
             AND ( (spc.currency = pc.currency
                     AND (pc.fx_as_of IS NOT NULL OR pc.fx_rate IS DISTINCT FROM 1))
                OR (spc.currency <> pc.currency
                     AND (pc.fx_as_of IS NULL
                          OR pc.fx_rate IS DISTINCT FROM round(fn_fx_pair_rate(spc.currency, pc.currency, pc.fx_as_of), 8)))))
)
SELECT seq, check_name, 0 AS expected, actual,
       (actual = 0) AS passed,
       CASE WHEN actual = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM raw;

COMMENT ON VIEW v_invariant_checks IS '45 条业务不变量自检：任何一条 actual>0 即为数据违规，可直接接入 CI 门禁';

-- =====================================================================================
-- 20. 会话/事务与权限说明（生产环境由运维执行，不在迁移脚本内）
-- =====================================================================================
-- 应用账号建议：只授予业务表的 SELECT/INSERT/UPDATE，DDL 由迁移账号持有；
-- supplier.auth_config / supplier_raw_payload.response 含敏感信息，应单独加密或脱敏列存储；
-- order_holder.value / coupon_redemption 属个人敏感信息，需加密列或独立存储与访问审计。
