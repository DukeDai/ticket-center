-- =====================================================================================
-- Ticket Center — 种子数据
-- 目标库：PostgreSQL 15+     编码：UTF8
--
-- 这份种子刻意构造了 5 个"性格完全不同"的供应源，用来验证 schema 能否同时承载：
--   ingresso          巴西源 / 实时查库存 / 支持核销 / 不支持分拆预订
--   fonticket         欧洲源 / 实时查库存 / 不支持核销 / 按日期计价
--   goodfellows_jtb   港日源 / 定时拉取价格 / 按票种分档
--   globaltix         港源 / 实时 / 支持分拆预订（部分预订）
--   piaofutong        大陆源 / 源推送库存 / 本地核销
--
-- 以及 5 个规范商品，其中 P1「香港故宫文化馆」同时被 3 个源供给（跨源同商品），
-- P2 被 2 个源供给，P3/P4/P5 为单源商品。
--
-- 注意：供应商的商务参数（佣金率、结算周期、能力开关）在此为**示意值**，
-- 上线前必须以各源接入文档/商务合同为准。
-- =====================================================================================

BEGIN;

-- -------------------------------------------------------------------------------------
-- 1. 供应源注册表
-- -------------------------------------------------------------------------------------
INSERT INTO supplier (id, code, name, short_name, country_code, default_currency, timezone, status, capability, sync_policy, connector_version) OVERRIDING SYSTEM VALUE
VALUES
 (1,'ingresso','Ingresso','ING','BR','BRL','America/Sao_Paulo','active',
  '{"product":true,"price":true,"session":true,"availability":"live","booking":true,"cancel":true,"validate":true,"partial_booking":false,"partial_refund":false,"settlement":"postpaid"}',
  '{"catalog":"daily","price":"hourly","availability":"live","webhook":false}','v1'),
 (2,'fonticket','FonTicket','FON','IT','EUR','Europe/Rome','active',
  '{"product":true,"price":true,"session":true,"availability":"live","booking":true,"cancel":true,"validate":false,"partial_booking":false,"partial_refund":false,"settlement":"postpaid"}',
  '{"catalog":"daily","price":"daily","availability":"live","webhook":false}','v1'),
 (3,'goodfellows_jtb','Goodfellows / JTB','GFJ','HK','HKD','Asia/Hong_Kong','active',
  '{"product":true,"price":true,"session":true,"availability":"pull_sync","booking":true,"cancel":true,"validate":false,"partial_booking":false,"partial_refund":false,"settlement":"monthly"}',
  '{"catalog":"daily","price":"every_6h","availability":"every_30m","webhook":false}','v1'),
 (4,'globaltix','GlobalTix','GTX','HK','HKD','Asia/Hong_Kong','active',
  '{"product":true,"price":true,"session":true,"availability":"live","booking":true,"cancel":true,"validate":false,"partial_booking":true,"partial_refund":true,"settlement":"monthly"}',
  '{"catalog":"daily","price":"hourly","availability":"live","webhook":true}','v2'),
 (5,'piaofutong','票付通','PFT','CN','CNY','Asia/Shanghai','active',
  '{"product":true,"price":true,"session":true,"availability":"push","booking":true,"cancel":true,"validate":true,"partial_booking":true,"partial_refund":false,"settlement":"monthly"}',
  '{"catalog":"daily","price":"push","availability":"push","webhook":true}','v1');

-- -------------------------------------------------------------------------------------
-- 2. 基础维度
-- -------------------------------------------------------------------------------------
INSERT INTO category (id, code, name, parent_id, path, level, sort_order) OVERRIDING SYSTEM VALUE VALUES
 (1,'attraction','景点门票',NULL,'/attraction',1,10),
 (2,'tour','导览行程',NULL,'/tour',1,20),
 (3,'transport','接送交通',NULL,'/transport',1,30),
 (4,'experience','特色体验',NULL,'/experience',1,40);

INSERT INTO city (id, code, name, country_code, longitude, latitude, timezone) OVERRIDING SYSTEM VALUE VALUES
 (1,'HK','香港','HK',114.169400,22.319300,'Asia/Hong_Kong'),
 (2,'TYO','东京','JP',139.691700,35.689500,'Asia/Tokyo'),
 (3,'SAO','圣保罗','BR',-46.633300,-23.550500,'America/Sao_Paulo'),
 (4,'VCE','威尼斯','IT',12.315500,45.440800,'Europe/Rome'),
 (5,'SH','上海','CN',121.473700,31.230400,'Asia/Shanghai');

INSERT INTO attribute_definition (id, code, name, data_type, unit, scope, is_filterable, is_searchable, is_multi, enum_values, sort_order) OVERRIDING SYSTEM VALUE VALUES
 (1,'duration_minutes','时长','duration','分钟','product',true,true,false,NULL,10),
 (2,'age_limit','年龄限制','json',NULL,'product',true,false,false,NULL,20),
 (3,'includes','包含项目','string',NULL,'product',false,false,true,NULL,30),
 (4,'instant_confirmation','即时确认','bool',NULL,'product',false,true,false,NULL,40),
 (5,'mobile_voucher','移动券','bool',NULL,'product',false,true,false,NULL,50),
 (6,'free_child_limit','免票儿童数','number','名','product',true,false,false,NULL,60),
 (7,'pickup_point','取票点','string',NULL,'session',false,false,false,NULL,70);

-- -------------------------------------------------------------------------------------
-- 3. 汇率快照（跨币种比价的前提）
--
-- 快照日期写死，不跟 current_date 走：
--   - 种子数据必须是确定的，同样的输入每次跑出同样的成本，否则没法当回归基线；
--   - 折算口径是「价格当日或之前最近的一份快照」（fn_fx_rate），
--     写死日期后不管哪天重建，价格永远落在快照之后，口径稳定。
--
-- 每个币种给两份快照：2025-01-01 是老价，2026-01-01 是现价。
-- 折算必须取「当日之前最近的那份」，也就是 2026-01-01。
-- 如果哪天实现退化成「取最早的一份」，成本会立刻对不上 —— 这份种子就是拿来抓这种错的。
-- -------------------------------------------------------------------------------------
INSERT INTO app_setting (key, value, description) VALUES
 ('base_currency', 'CNY', '跨币种比价的基准币种：所有成本先折算到这个币种才可比');

INSERT INTO fx_rate (base_currency, quote_currency, rate, as_of_date, source) VALUES
 ('CNY','HKD',1.0950000, DATE '2025-01-01', 'demo'),
 ('CNY','JPY',21.4000000, DATE '2025-01-01', 'demo'),
 ('CNY','EUR',0.1310000, DATE '2025-01-01', 'demo'),
 ('CNY','BRL',0.8600000, DATE '2025-01-01', 'demo'),
 ('CNY','HKD',1.0833000, DATE '2026-01-01', 'demo'),
 ('CNY','JPY',21.1500000, DATE '2026-01-01', 'demo'),
 ('CNY','EUR',0.1290000, DATE '2026-01-01', 'demo'),
 ('CNY','BRL',0.8300000, DATE '2026-01-01', 'demo');

-- -------------------------------------------------------------------------------------
-- 4. 规范商品（Catalog）
-- -------------------------------------------------------------------------------------
INSERT INTO product (id, product_code, title, subtitle, description, category_id, city_id, country_code, product_type, status, canonical_key, attributes, fulfilment_type, validity_rule, refund_policy, rating, review_count) OVERRIDING SYSTEM VALUE
VALUES
 (1,'SKU-HK-PALACE','香港故宫文化馆 特展门票','电子票 现场扫码核销','含特展展厅入场，指定日期有效。',1,1,'HK','ticket','active','hk:palace:exhibition',
  '{"duration_minutes":120,"age_limit":{"min":4},"includes":["特展展厅","导览手册"],"instant_confirmation":true,"mobile_voucher":true,"free_child_limit":1}',
  'qr_pickup','{"validity":"session_date","single_use":true,"timezone":"Asia/Hong_Kong"}',
  '{"refundable":true,"cutoff_hours":48,"fee_percent":10}',4.6,1284),
 (2,'SKU-JP-SKYTREE','东京晴空塔 展望台快速通道票','免排队入场','快速通道直接进入 350m 展望台。',1,2,'JP','ticket','active','jp:skytree:fast',
  '{"duration_minutes":90,"age_limit":{"min":4},"includes":["快速通道","展望台"],"instant_confirmation":false,"mobile_voucher":true}',
  'qr_pickup','{"validity":"session_date","single_use":true,"timezone":"Asia/Tokyo"}',
  '{"refundable":true,"cutoff_hours":24}',4.4,862),
 (3,'SKU-BR-GASTRONOMY','圣保罗 美食步行之旅','本地美食 + 街区漫步','4 小时步行，6 站停靠。',2,3,'BR','package','active','br:sao:foodwalk',
  '{"duration_minutes":240,"age_limit":{"min":10},"includes":["导览","6站试吃","饮品"],"instant_confirmation":true}',
  'ticket_code','{"validity":"session_date","single_use":true,"timezone":"America/Sao_Paulo"}',
  '{"refundable":true,"cutoff_hours":72}',4.7,640),
 (4,'SKU-IT-DOGES','威尼斯总督宫 门票','含预留时段','官方通道入场。',1,4,'IT','ticket','active','it:venice:doge',
  '{"duration_minutes":120,"age_limit":{"min":0},"includes":["入场"],"instant_confirmation":true,"mobile_voucher":true}',
  'qr_pickup','{"validity":"session_date","single_use":true,"timezone":"Europe/Rome"}',
  '{"refundable":false,"cutoff_hours":0}',4.2,2310),
 (5,'SKU-CN-THEMEPARK','上海 主题乐园 全日票','一日通票 + 快速通行','含 3 个快速通行项目。',1,5,'CN','ticket','active','cn:sh:themepark',
  '{"duration_minutes":600,"age_limit":{"min":3},"includes":["一日通票","快速通行x3"],"instant_confirmation":true,"mobile_voucher":true,"free_child_limit":1}',
  'qr_pickup','{"validity":"session_date","single_use":true,"timezone":"Asia/Shanghai"}',
  '{"refundable":true,"cutoff_hours":24}',4.5,5310);

INSERT INTO product_translation (product_id, locale, title, subtitle, description) VALUES
 (1,'en-HK','Hong Kong Palace Museum Special Exhibition','E-ticket, scan on site',NULL),
 (1,'zh-HK','香港故宫文化馆 特展门票','电子票 现场扫码核销',NULL),
 (2,'ja-JP','東京スカイツリー 展望台 ファストパス','並ばずすぐ入場',NULL),
 (3,'pt-BR','Passeio gastronômico em São Paulo','Sabores locais e rua',NULL);

INSERT INTO product_media (product_id, media_type, url, thumbnail, caption, sort_order, is_primary) VALUES
 (1,'image','https://cdn.demo/palace/cover.jpg','https://cdn.demo/palace/cover_s.jpg','主图',0,true),
 (1,'image','https://cdn.demo/palace/exhibit-1.jpg',NULL,'特展现场',1,false),
 (2,'image','https://cdn.demo/skytree/cover.jpg',NULL,NULL,0,true);

-- 规范票种
INSERT INTO ticket_type (id, product_id, code, name, description, age_rule, stock_mode, sort_order) OVERRIDING SYSTEM VALUE VALUES
 (1,1,'adult','成人票','12岁以上', '{"min_age":12}','per_session',1),
 (2,1,'child','儿童票','4-11岁', '{"min_age":4,"max_age":11}','per_session',2),
 (3,2,'adult','成人票',NULL,'{"min_age":12}','per_session',1),
 (4,2,'child','儿童票',NULL,'{"min_age":4,"max_age":11}','per_session',2),
 (5,3,'adult','成人票',NULL,'{"min_age":12}','per_session',1),
 (6,4,'adult','成人票',NULL,'{"min_age":18}','per_session',1),
 (7,5,'adult','成人票',NULL,'{"min_age":12}','per_session',1),
 (8,5,'child','儿童票',NULL,'{"min_age":3,"max_age":11}','per_session',2);

-- -------------------------------------------------------------------------------------
-- 5. 源商品（原样层）
--    注意各源命名风格迥异：ingresso 用 "product"，fonticket 用 "event"，
--    jtb 用 "product"+"departures"，globaltix 用 "package"+"items"，票付通用 "goods"+"spec"。
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_product (id, supplier_id, external_id, external_code, external_url, raw_title, raw_payload, source_attributes, availability_mode, content_hash, status, last_synced_at) OVERRIDING SYSTEM VALUE
VALUES
 (1,1,'1234567','ING-1234567','https://ingresso.example/tour/1234567','Passeio gastronômico em São Paulo',
  '{"id":1234567,"name":"Passeio gastronômico em Sao Paulo","duration":240,"minAge":10,"city":"Sao Paulo","items":[{"id":"adult","name":"Adulto","price":120.00}]}',
  '{"duration":240,"minAge":10,"city":"Sao Paulo","items":[{"id":"adult","name":"Adulto","price":120.00}]}','live','h1','active',now()),
 (2,2,'FT-88901','FON-88901','https://fonticket.example/e/88901','Doge Palace Venice',
  '{"event":88901,"title":"Doge Palace Venice","window":{"from":"2026-11-05","to":"2026-12-20"},"categories":["adult"]}',
  '{"window":{"from":"2026-11-05","to":"2026-12-20"},"categories":["adult"]}','live','h2','active',now()),
 (3,3,'GF-55021','JTB-55021','https://gfj.example/p/55021','Hong Kong Palace Museum - Special Exhibition',
  '{"productCode":"JTB-55021","name":"Hong Kong Palace Museum - Special Exhibition","durationMin":120,"minAge":4,"departures":[{"id":"d1","date":"2026-11-05"}]}',
  '{"durationMin":120,"minAge":4,"departures":[{"id":"d1","date":"2026-11-05"}]}','pull_sync','h3','active',now()),
 (4,4,'GTX-77301','GTX77301','https://globaltix.example/p/77301','HK Palace Museum Special Exhibition',
  '{"id":"77301","packageName":"HK Palace Museum Special Exhibition","validityDays":1,"items":[{"itemId":"A","type":"Adult","price":120.00},{"itemId":"C","type":"Child","price":80.00}]}',
  '{"validityDays":1,"items":[{"itemId":"A","type":"Adult","price":120.00},{"itemId":"C","type":"Child","price":80.00}]}','live','h4','active',now()),
 (5,5,'PFT-2201','2201','https://pft.example/goods/2201','香港故宫文化馆 特展门票',
  '{"goodsId":2201,"goodsName":"香港故宫文化馆 特展门票","specList":[{"specId":1,"specName":"成人票","price":118.00},{"specId":2,"specName":"儿童票","price":78.00}]}',
  '{"specList":[{"specId":1,"specName":"成人票","price":118.00},{"specId":2,"specName":"儿童票","price":78.00}]}','push','h5','active',now()),
 (6,3,'GF-55022','JTB-55022','https://gfj.example/p/55022','Tokyo Skytree Fast Pass',
  '{"productCode":"JTB-55022","name":"Tokyo Skytree Fast Pass","durationMin":90,"minAge":4}',
  '{"durationMin":90,"minAge":4}','pull_sync','h6','active',now()),
 (7,4,'GTX-77302','GTX77302','https://globaltix.example/p/77302','Tokyo Skytree Fast Pass',
  '{"id":"77302","packageName":"Tokyo Skytree Fast Pass","validityDays":1,"items":[{"itemId":"A","type":"Adult","price":2600}]}',
  '{"validityDays":1,"items":[{"itemId":"A","type":"Adult","price":2600}]}','live','h7','active',now()),
 (8,5,'PFT-2202','2202','https://pft.example/goods/2202','上海 主题乐园 全日票',
  '{"goodsId":2202,"goodsName":"上海 主题乐园 全日票","specList":[{"specId":1,"specName":"成人票","price":298.00}]}',
  '{"specList":[{"specId":1,"specName":"成人票","price":298.00}]}','push','h8','active',now());

-- 源票种
INSERT INTO supplier_ticket_type (id, supplier_product_id, external_id, name, name_en, description, age_rule, is_optional, raw_payload) OVERRIDING SYSTEM VALUE VALUES
 (1,1,'adult','Adulto','Adult',NULL,'{"min_age":12}',false,'{"id":"adult","price":120.00}'),
 (2,2,'adult','Adulto','Adult',NULL,'{"min_age":18}',false,'{"id":"adult"}'),
 (3,3,'adult','Adult','Adult',NULL,'{"min_age":12}',false,'{"id":"adult"}'),
 (4,3,'child','Child','Child',NULL,'{"min_age":4,"max_age":11}',false,'{"id":"child"}'),
 (5,4,'A','成人票','Adult',NULL,'{"min_age":12}',false,'{"itemId":"A","price":120.00}'),
 (6,4,'C','儿童票','Child',NULL,'{"min_age":4,"max_age":11}',false,'{"itemId":"C","price":80.00}'),
 (7,5,'1','成人票','Adult',NULL,'{"min_age":12}',false,'{"specId":1,"price":118.00}'),
 (8,5,'2','儿童票','Child',NULL,'{"min_age":4,"max_age":11}',false,'{"specId":2,"price":78.00}'),
 (9,6,'adult','Adult','Adult',NULL,'{"min_age":12}',false,'{"id":"adult"}'),
 (10,7,'A','Adult','Adult',NULL,'{"min_age":12}',false,'{"itemId":"A","price":2600}'),
 (11,8,'1','成人票','Adult',NULL,'{"min_age":12}',false,'{"specId":1,"price":298.00}'),
 (12,6,'child','Child','Child',NULL,'{"min_age":4,"max_age":11}',false,'{"id":"child"}'),
 (13,7,'C','Child','Child',NULL,'{"min_age":4,"max_age":11}',false,'{"itemId":"C","price":2100}');

-- 源票种 ↔ 规范票种
INSERT INTO ticket_type_mapping (supplier_ticket_type_id, ticket_type_id, price_adjustment, quantity_multiplier) VALUES
 (1,5,'{}',1),          -- ingresso 成人 → P3 成人
 (2,6,'{}',1),          -- fonticket 成人 → P4 成人
 (3,1,'{}',1),          -- jtb 成人 → P1 成人
 (4,2,'{}',1),          -- jtb 儿童 → P1 儿童
 (5,1,'{}',1),          -- globaltix 成人 → P1 成人
 (6,2,'{}',1),          -- globaltix 儿童 → P1 儿童
 (7,1,'{}',1),          -- 票付通 成人 → P1 成人
 (8,2,'{}',1),          -- 票付通 儿童 → P1 儿童
 (9,3,'{}',1),          -- jtb 成人 → P2 成人
 (10,3,'{}',1),         -- globaltix 成人 → P2 成人
 (11,7,'{}',1),         -- 票付通 成人 → P5 成人
 (12,4,'{}',1),         -- jtb 儿童 → P2 儿童
 (13,4,'{}',1);         -- globaltix 儿童 → P2 儿童

-- -------------------------------------------------------------------------------------
-- 6. 源场次
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_session (id, supplier_product_id, supplier_ticket_type_id, external_id, session_date, start_at, end_at, timezone, local_start_label, meeting_point, address, latitude, longitude, capacity, status, raw_payload) OVERRIDING SYSTEM VALUE
VALUES
 -- P1 · globaltix（primary）
 (1,4,NULL,'GTX-D20261105', current_date+5, (current_date+5)::timestamptz + interval '10 hours', NULL,'Asia/Hong_Kong','10:00 - 12:00','特展入口 B2','西九龙文化区',22.304100,114.169500,NULL,'active','{"date":"2026-11-05","slots":["10:00-12:00"]}'),
 (2,4,NULL,'GTX-D20261106', current_date+6, (current_date+6)::timestamptz + interval '10 hours', NULL,'Asia/Hong_Kong','10:00 - 12:00','特展入口 B2','西九龙文化区',22.304100,114.169500,NULL,'active','{"date":"2026-11-06"}'),
 -- P1 · goodfellows_jtb（fallback）
 (3,3,NULL,'GFJ-D20261105', current_date+5, (current_date+5)::timestamptz + interval '9 hours', NULL,'Asia/Hong_Kong','09:00','特展正门','西九龙文化区',22.304300,114.170100,NULL,'active','{"date":"2026-11-05","time":"09:00"}'),
 (4,3,NULL,'GFJ-D20261106', current_date+6, (current_date+6)::timestamptz + interval '9 hours', NULL,'Asia/Hong_Kong','09:00','特展正门','西九龙文化区',22.304300,114.170100,NULL,'active','{"date":"2026-11-06","time":"09:00"}'),
 -- P1 · 票付通（fallback）
 (5,5,NULL,'PFT-D20261105', current_date+5, (current_date+5)::timestamptz + interval '10 hours 30 minutes', NULL,'Asia/Hong_Kong','10:30','特展入口 B2','西九龙文化区',22.304100,114.169500,NULL,'active','{"useDate":"2026-11-05","startTime":"10:30"}'),
 -- P2 · jtb / globaltix
 (6,6,NULL,'GFJ-D20261107', current_date+7, (current_date+7)::timestamptz + interval '11 hours', NULL,'Asia/Tokyo','11:00','350m 展望台','押上 2-3-2',35.710100,139.810700,NULL,'active','{"date":"2026-11-07"}'),
 (7,7,NULL,'GTX-D20261107', current_date+7, (current_date+7)::timestamptz + interval '11 hours', NULL,'Asia/Tokyo','11:00','350m 展望台','押上 2-3-2',35.710100,139.810700,NULL,'active','{"date":"2026-11-07"}'),
 -- P3 · ingresso
 (8,1,NULL,'ING-D20261108', current_date+8, (current_date+8)::timestamptz + interval '14 hours', NULL,'America/Sao_Paulo','14:00','Praça da Sé 集合','Praça da Sé, São Paulo',-23.547500,-46.638900,12,'active','{"departureDate":"2026-11-08","departureTime":"14:00","maxPax":12}'),
 -- P4 · fonticket
 (9,2,NULL,'FT-D20261109', current_date+9, (current_date+9)::timestamptz + interval '15 hours', NULL,'Europe/Rome','15:00','Doge 宫售票处','Piazza San Marco, Venezia',45.434200,12.338800,NULL,'active','{"slot":"15:00"}'),
 -- P5 · 票付通
 (10,8,NULL,'PFT-D20261110', current_date+10, (current_date+10)::timestamptz + interval '9 hours', NULL,'Asia/Shanghai','09:00','乐园 1 号门','浦东新区',31.238400,121.501100,NULL,'active','{"useDate":"2026-11-10"}');

-- -------------------------------------------------------------------------------------
-- 7. 跨源映射（多对多）
--    P1 由 globaltix(primary) + goodfellows_jtb(fallback) + 票付通(fallback) 三源供给
--    P2 由 goodfellows_jtb(primary) + globaltix(fallback) 两源供给
-- -------------------------------------------------------------------------------------
INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, match_type, confidence, match_evidence, is_primary, status, created_by)
VALUES
 (4,4,1,'manual',0.99,'{"signals":["title_exact","same_venue","same_exhibition"],"decided_by":"ops@demo"}',true,'active','ops@demo'),
 (3,3,1,'auto',0.92,'{"signals":["title_similarity:0.93","same_venue","same_date_range"]}',false,'active','system@matcher'),
 (5,5,1,'rule',0.88,'{"signals":["venue_geo:ok","attr_duration:ok"]}',false,'active','system@matcher'),
 (6,3,2,'manual',0.97,'{"signals":["title_exact","same_venue"]}',true,'active','ops@demo'),
 (7,4,2,'auto',0.90,'{"signals":["title_similarity:0.91","same_venue"]}',false,'active','system@matcher'),
 (1,1,3,'manual',0.96,'{"signals":["title_exact","same_city"]}',true,'active','ops@demo'),
 (2,2,4,'manual',0.95,'{"signals":["title_exact","same_venue"]}',true,'active','ops@demo'),
 (8,5,5,'manual',0.97,'{"signals":["title_exact","same_city"]}',true,'active','ops@demo');

-- -------------------------------------------------------------------------------------
-- 8. 规范场次 + 场次源绑定（多源冗余的核心）
-- -------------------------------------------------------------------------------------
INSERT INTO product_session (id, product_id, session_date, slot_key, start_at, end_at, timezone, meeting_point, status, min_adult, max_adult, max_child) OVERRIDING SYSTEM VALUE
VALUES
 (1,1, current_date+5, 'default', (current_date+5)::timestamptz + interval '10 hours', NULL,'Asia/Hong_Kong','特展入口 B2','active',1,10,4),
 (2,1, current_date+6, 'default', (current_date+6)::timestamptz + interval '10 hours', NULL,'Asia/Hong_Kong','特展入口 B2','active',1,10,4),
 (3,2, current_date+7, 'default', (current_date+7)::timestamptz + interval '11 hours', NULL,'Asia/Tokyo','350m 展望台','active',1,8,4),
 (4,3, current_date+8, 'default', (current_date+8)::timestamptz + interval '14 hours', NULL,'America/Sao_Paulo','Praça da Sé 集合','active',1,12,0),
 (5,4, current_date+9, 'default', (current_date+9)::timestamptz + interval '15 hours', NULL,'Europe/Rome','Doge 宫售票处','active',1,NULL,0),
 (6,5, current_date+10,'default', (current_date+10)::timestamptz + interval '9 hours', NULL,'Asia/Shanghai','乐园 1 号门','active',1,10,4);

INSERT INTO product_session_source (product_session_id, supplier_session_id, supplier_id, supplier_product_id, role, price_overlay, priority)
VALUES
 (1,1,4,4,'primary','{}',10),      -- globaltix 主源
 (1,3,3,3,'fallback','{}',20),     -- jtb 备源
 (1,5,5,5,'fallback','{}',30),     -- 票付通 备源
 (2,2,4,4,'primary','{}',10),
 (2,4,3,3,'fallback','{}',20),
 (3,6,3,6,'primary','{}',10),      -- jtb 主源
 (3,7,4,7,'fallback','{}',20),     -- globaltix 备源
 (4,8,1,1,'primary','{}',10),
 (5,9,2,2,'primary','{}',10),
 (6,10,5,8,'primary','{}',10);

-- -------------------------------------------------------------------------------------
-- 9. 源成本价日历 —— 同一商品、同一天，不同源成本不同（比价的基础）
--    P1 香港故宫：globaltix HKD 118 / jtb HKD 125 / 票付通 CNY 108(=HKD 99.7)
--    → 折算后票付通最便宜，globaltix 次之，jbv 最贵
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_price_calendar (supplier_product_id, supplier_ticket_type_id, supplier_session_id, product_id, date, currency, supplier_price, net_price, tax, min_qty, max_qty, status)
VALUES
 (4,5,1,1, current_date+5,'HKD',120.00,118.00,0,1,20,'available'),
 (4,6,1,1, current_date+5,'HKD', 80.00, 78.00,0,1,20,'available'),
 (3,3,3,1, current_date+5,'HKD',125.00,125.00,0,1,20,'available'),
 (3,4,3,1, current_date+5,'HKD', 85.00, 85.00,0,1,20,'available'),
 (5,7,5,1, current_date+5,'CNY',118.00,108.00,10,1,20,'available'),
 (5,8,5,1, current_date+5,'CNY', 78.00, 70.00, 8,1,20,'available'),
 (4,5,2,1, current_date+6,'HKD',120.00,118.00,0,1,20,'available'),
 (3,3,4,1, current_date+6,'HKD',125.00,125.00,0,1,20,'available'),
 (5,7,NULL,1,current_date+6,'CNY',118.00,108.00,10,1,20,'available'),
 -- 同一天也要有儿童票的源成本：售价日历给儿童票定了价，成本却找不到对应源行，
 -- 那是凭空捏出来的成本。不变量 40 会当场抓出来。
 (4,6,2,1, current_date+6,'HKD', 80.00, 78.00,0,1,20,'available'),
 (3,4,4,1, current_date+6,'HKD', 85.00, 85.00,0,1,20,'available'),
 (5,8,NULL,1,current_date+6,'CNY', 78.00, 70.00, 8,1,20,'available'),
 -- P2 东京：jtb JPY 2600 / globaltix JPY 2750
 (6,9,6,2, current_date+7,'JPY',2600.00,2600.00,0,1,10,'available'),
 (7,10,7,2,current_date+7,'JPY',2750.00,2750.00,0,1,10,'available'),
 (6,12,6,2, current_date+7,'JPY',2000.00,2000.00,0,1,10,'available'),
 (7,13,7,2, current_date+7,'JPY',2100.00,2100.00,0,1,10,'available'),
 -- P3 圣保罗：ingresso BRL 120
 (1,1,8,3, current_date+8,'BRL',120.00,120.00,0,1,12,'available'),
 -- P4 威尼斯：fonticket EUR 18
 (2,2,9,4, current_date+9,'EUR',18.00,18.00,0,1,NULL,'available'),
 -- P5 上海：票付通 CNY 298
 (8,11,10,5, current_date+10,'CNY',298.00,288.00,10,1,10,'available');

-- -------------------------------------------------------------------------------------
-- 10. 对客售价日历（基准币种 CNY）
--
-- 这里只写「要卖哪一行」：商品 / 场次 / 票种 / 渠道 / 日期。
-- 成本、售价、划线价一律由第 17 节的 fn_price_variant 算出来再回填 ——
-- 售价数字不再手写。手写的意思是同一批源数据有三个地方给出三个价格。
-- -------------------------------------------------------------------------------------
INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, status, source)
VALUES
 (1,1,1,NULL, current_date+5,'CNY','active','calc'),
 (1,1,2,NULL, current_date+5,'CNY','active','calc'),
 (1,2,1,NULL, current_date+6,'CNY','active','calc'),
 (1,2,2,NULL, current_date+6,'CNY','active','calc'),
 (2,3,3,NULL, current_date+7,'CNY','active','calc'),
 (2,3,4,NULL, current_date+7,'CNY','active','calc'),
 (3,4,5,NULL, current_date+8,'CNY','active','calc'),
 (4,5,6,NULL, current_date+9,'CNY','active','calc'),
 (5,6,7,NULL, current_date+10,'CNY','active','calc'),
 (5,6,8,NULL, current_date+10,'CNY','active','calc');

-- -------------------------------------------------------------------------------------
-- 11. 渠道（B端 / C端）
-- -------------------------------------------------------------------------------------
INSERT INTO channel (id, code, name, channel_type, settlement_mode, commission_rate, default_currency, tax_policy, status, config) OVERRIDING SYSTEM VALUE
VALUES
 (1,'C2C','OTA 自营 C 端','b2c_own','prepaid',0,'CNY','{"included":true,"rate":0.06}','active','{"payment_methods":["wechat","alipay","card"]}'),
 (2,'B2B_HK','B端分销-港代','b2b_distributor','postpaid',0.1200,'HKD','{"included":false,"rate":0}','active','{"credit_limit":500000,"settlement_days":30}'),
 (3,'CORP','企业客户-差旅','corporate','prepaid',0.0800,'CNY','{"included":true,"rate":0.06,"invoice":true}','active','{"need_company_profile":true}');

-- 上架
INSERT INTO channel_listing (id, channel_id, product_id, status, price_policy, stock_policy, booking_policy, min_order_qty, max_order_qty, sort_weight, published_at) OVERRIDING SYSTEM VALUE
VALUES
 -- price_policy 就是定价合同（SPEC.md §4.6）：
 --   percent              成本加价率
 --   min_margin           该渠道要求的最低毛利率（与所选源的 min_margin 取严）
 --   list_markup_percent  划线价相对售价的上浮率（缺省 0，即划线价 = 售价）
 --   mode                 cost_plus（默认）/ per_group（按团报价）
 (1,1,1,'online','{"mode":"cost_plus","percent":27.8,"min_margin":0.15,"list_markup_percent":21.7}','{"mode":"full"}','{"mode":"instant","confirm_deadline_min":30}',1,10,100,now()),
 (2,1,2,'online','{"mode":"cost_plus","percent":36.6,"min_margin":0.15,"list_markup_percent":17.9}','{"mode":"full"}','{"mode":"instant","confirm_deadline_min":30}',1,10,90,now()),
 (3,1,3,'online','{"mode":"cost_plus","percent":30.7,"min_margin":0.12,"list_markup_percent":15.7}','{"mode":"full"}','{"mode":"instant"}',1,6,80,now()),
 (4,1,4,'online','{"mode":"cost_plus","percent":37.5,"min_margin":0.10,"list_markup_percent":13.5}','{"mode":"full"}','{"mode":"instant"}',1,10,70,now()),
 (5,1,5,'online','{"mode":"cost_plus","percent":27.8,"min_margin":0.15,"list_markup_percent":16.3}','{"mode":"full"}','{"mode":"instant"}',1,10,60,now()),
 (6,2,1,'online','{"mode":"cost_plus","percent":18.0,"min_margin":0.08,"list_markup_percent":17.2}','{"mode":"full"}','{"mode":"instant"}',1,20,100,now()),
 (7,2,2,'online','{"mode":"cost_plus","percent":22.0,"min_margin":0.08,"list_markup_percent":16.7}','{"mode":"full"}','{"mode":"instant"}',1,20,90,now()),
 (8,3,1,'online','{"mode":"cost_plus","percent":20.0,"min_margin":0.10,"list_markup_percent":15.0}','{"mode":"limited","limit":5}','{"mode":"instant","need_deposit":false}',1,5,100,now());

-- 路由绑定：哪些源供给这个渠道上架，按 priority / fallback_order
INSERT INTO channel_listing_source (channel_listing_id, supplier_product_id, supplier_id, priority, fallback_order, min_margin, max_daily_qty, enabled)
VALUES
 (1,4,4,10,1,0.15,NULL,true),    -- C端 · globaltix 主
 (1,3,3,20,2,0.15,NULL,true),    -- C端 · jtb 备
 (1,5,5,30,3,0.12,50,true),      -- C端 · 票付通 备（限每日配额）
 (2,6,3,10,1,0.15,NULL,true),    -- C端 · P2 jtb 主
 (2,7,4,20,2,0.15,NULL,true),    -- C端 · P2 globaltix 备
 (3,1,1,10,1,0.12,NULL,true),
 (4,2,2,10,1,0.10,NULL,true),
 (5,8,5,10,1,0.15,NULL,true),
 (6,4,4,10,1,0.08,NULL,true),    -- B端 · globaltix 主
 (6,3,3,20,2,0.08,NULL,true),    -- B端 · jtb 备
 (7,6,3,10,1,0.08,NULL,true),    -- B端 · P2 jtb 主
 (7,7,4,20,2,0.08,NULL,true),    -- B端 · P2 globaltix 备
 (8,5,5,10,1,0.10,10,true);      -- 企业客户 · 票付通（限每日 10）

-- -------------------------------------------------------------------------------------
-- 12. 交易与履约
-- -------------------------------------------------------------------------------------
INSERT INTO customer (id, channel_id, customer_type, member_code, name, email, phone, country_code, locale) OVERRIDING SYSTEM VALUE VALUES
 (1,1,'c','C10001','陈小雅','chenxy@example.com','+85290000001','HK','zh-HK'),
 (2,2,'b','B20001','港中旅旅行社','ops@hcts.example','+85290000002','HK','zh-HK'),
 (3,3,'c','C10002','王大明','wangdm@example.com','+8613900000003','CN','zh-CN');

-- 订单 1：C端，已付款、预订成功、已出票、已核销
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, discount, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at, confirmed_at, completed_at) OVERRIDING SYSTEM VALUE
VALUES (1,'TC20261028000001',1,1,'fulfilled','paid','fulfilled','CNY',276.00,0.00,0.00,276.00,216.00,0.00,
 '{"rule":"cost_plus","sell_price":138.00,"cost":108.00,"currency":"CNY"}','{"name":"陈小雅","email":"chenxy@example.com"}',
 'idem-c2c-001', now() - interval '3 hours', now() - interval '2 hours 50 minutes', now() - interval '2 hours 40 minutes');

-- 订单 2：B端分销，已付款、预订成功、已出票（未核销）
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, discount, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at, confirmed_at, completed_at) OVERRIDING SYSTEM VALUE
VALUES (2,'TC20261028000002',2,2,'fulfilled','paid','fulfilled','HKD',276.00,0.00,0.00,276.00,236.00,33.12,
 '{"rule":"cost_plus","sell_price":138.00,"cost":118.00,"currency":"HKD","channel_override":true}','{"name":"港中旅旅行社"}',
 'idem-b2b-002', now() - interval '5 hours', now() - interval '4 hours 50 minutes', now() - interval '4 hours 40 minutes');

-- 订单 3：C端，已付款但源侧预订失败（演示改派/重报）
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, discount, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at) OVERRIDING SYSTEM VALUE
VALUES (3,'TC20261028000003',1,3,'booking_pending','paid','unfulfilled','CNY',368.00,0.00,0.00,368.00,288.00,0.00,
 '{"rule":"cost_plus","sell_price":368.00,"cost":288.00,"currency":"CNY"}','{"name":"王大明"}',
 'idem-c2c-003', now() - interval '40 minutes');

-- 订单 4：C端，未付款超时（演示过期路径）
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at, expires_at) OVERRIDING SYSTEM VALUE
VALUES (4,'TC20261028000004',1,3,'expired','unpaid','unfulfilled','CNY',188.50,0.00,188.50,144.58,0.00,
 '{"rule":"cost_plus","sell_price":188.50,"cost":144.58,"currency":"CNY"}','{"name":"王大明"}',
 'idem-c2c-004', now() - interval '2 days', now() - interval '2 days' + interval '30 minutes');

INSERT INTO sales_order_item (id, order_id, product_id, channel_listing_id, supplier_product_id, supplier_id, session_id, ticket_type_id, quantity, unit_price, unit_cost, total_price, currency, detail_snapshot, status) OVERRIDING SYSTEM VALUE
VALUES (1,1,1,1,5,5,1,1,2,138.00,108.00,276.00,'CNY',
 '{"title":"香港故宫文化馆 特展门票","date":"2026-11-05","slot":"10:00-12:00","meeting_point":"特展入口 B2","ticket_type":"成人票"}','ticketed'),
 (2,2,1,6,4,4,1,1,2,138.00,118.00,276.00,'HKD',
 '{"title":"香港故宫文化馆 特展门票","date":"2026-11-05","slot":"10:00-12:00","meeting_point":"特展入口 B2","ticket_type":"成人票"}','ticketed'),
 (3,3,5,5,8,5,6,7,1,368.00,288.00,368.00,'CNY',
 '{"title":"上海 主题乐园 全日票","date":"2026-11-10","slot":"09:00","meeting_point":"乐园 1 号门","ticket_type":"成人票"}','booking'),
 (4,4,3,3,1,1,4,5,1,188.50,144.58,188.50,'CNY',
 '{"title":"圣保罗 美食步行之旅","date":"2026-11-08","slot":"14:00","ticket_type":"成人票"}','cancelled');

INSERT INTO sales_payment (id, order_id, channel_id, payment_method, amount, currency, status, provider, provider_txn_id, paid_at) OVERRIDING SYSTEM VALUE
VALUES (1,1,1,'wechat',276.00,'CNY','succeeded','wechat_pay','WX88000001', now() - interval '2 hours 55 minutes'),
 (2,2,2,'credit',276.00,'HKD','succeeded','internal_credit',NULL, now() - interval '4 hours 55 minutes'),
 (3,3,1,'alipay',368.00,'CNY','succeeded','alipay','ALI88000003', now() - interval '35 minutes');

-- 预订（与订单分离的聚合）
INSERT INTO booking (id, booking_no, order_id, order_item_id, supplier_id, supplier_product_id, supplier_session_id, external_booking_id, status, attempt_count, next_retry_at, idempotency_key, request_payload, response_payload, confirmed_at) OVERRIDING SYSTEM VALUE
VALUES (1,'BK202610280001',1,1,5,5,5,'PFT-BK-99001','confirmed',1,NULL,'bk-idem-001',
 '{"goodsId":2201,"useDate":"2026-11-05","specId":1,"qty":2,"contact":{"name":"陈小雅"}}',
 '{"bookingId":"PFT-BK-99001","status":"confirmed","voucher":[{"code":"PFT90001"},{"code":"PFT90002"}]}', now() - interval '2 hours 55 minutes'),
 (2,'BK202610280002',2,2,4,4,1,'GTX-BK-77021','confirmed',1,NULL,'bk-idem-002',
 '{"packageId":77301,"itemId":"A","qty":2,"useDate":"2026-11-05"}',
 '{"bookingRef":"GTX-BK-77021","status":"OK"}', now() - interval '4 hours 55 minutes'),
 (3,'BK202610280003',3,3,5,8,10,NULL,'failed',3,NULL,'bk-idem-003',
 '{"goodsId":2202,"useDate":"2026-11-10","specId":1,"qty":1}',
 '{"error":{"code":"STOCK_LOCKED","message":"库存被占位，请改派其他源"}}', NULL);

INSERT INTO booking_attempt (id, booking_id, attempt_no, request, response, http_status, latency_ms, error_type, error_message) OVERRIDING SYSTEM VALUE VALUES
 (1,1,1,'{"goodsId":2201}','{"bookingId":"PFT-BK-99001"}',200,412,NULL,NULL),
 (2,2,1,'{"packageId":77301}','{"bookingRef":"GTX-BK-77021"}',200,688,NULL,NULL),
 (3,3,1,'{"goodsId":2202}','{"error":"timeout"}',NULL,30000,'timeout','连接超时'),
 (4,3,2,'{"goodsId":2202}','{"error":"timeout"}',NULL,30000,'timeout','连接超时'),
 (5,3,3,'{"goodsId":2202}','{"error":"STOCK_LOCKED"}',409,233,'fatal','库存被占位');

INSERT INTO booking_event (booking_id, from_status, to_status, event_type, payload) VALUES
 (1,NULL,'pending','BookingCreated','{"source":"c2c"}'),
 (1,'pending','requested','BookingRequested','{"attempt":1}'),
 (1,'requested','confirmed','BookingConfirmed','{"externalBookingId":"PFT-BK-99001"}'),
 (2,NULL,'pending','BookingCreated','{}'),
 (2,'pending','requested','BookingRequested','{"attempt":1}'),
 (2,'requested','confirmed','BookingConfirmed','{"externalBookingId":"GTX-BK-77021"}'),
 (3,NULL,'pending','BookingCreated','{}'),
 (3,'pending','requested','BookingRequested','{"attempt":1}'),
 (3,'requested','failed','BookingFailed','{"error":"STOCK_LOCKED"}');

-- 票券凭证
-- 券 2 已核销：核销时间落在券的有效期内（不变量 68），
-- 额度已用尽（不变量 67），并且重复扫过一次 —— 第二次记 duplicate，不覆盖事实（不变量 66）。
INSERT INTO voucher (id, voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id, ticket_type_id, session_id, code, qr_payload, status, issued_at, valid_from, valid_to, used_at, used_channel, holder_snapshot) OVERRIDING SYSTEM VALUE
VALUES (1,'VC20261028000001',1,1,1,1,5,1,1,'PFT90001','PFT90001|1|a3f9c2e1','issued',now() - interval '2 hours 55 minutes', (current_date+5)::timestamptz, (current_date+5)::timestamptz + interval '1 day',NULL,NULL,'{"name":"陈小雅"}'),
 (2,'VC20261028000002',1,1,1,1,5,1,1,'PFT90002','PFT90002|1|a3f9c2e1','used',now() - interval '2 hours 55 minutes', (current_date+5)::timestamptz, (current_date+5)::timestamptz + interval '1 day', (current_date+5)::timestamptz + interval '10 hours','C2C','{"name":"陈小雅"}'),
 (3,'VC20261028000003',2,2,2,1,4,1,1,'GTX77881','GTX77881|2|be72f0aa','issued',now() - interval '4 hours 55 minutes', (current_date+5)::timestamptz, (current_date+5)::timestamptz + interval '1 day',NULL,NULL,'{"name":"港中旅旅行社"}'),
 (4,'VC20261028000004',2,2,2,1,4,1,1,'GTX77882','GTX77882|2|be72f0aa','issued',now() - interval '4 hours 55 minutes', (current_date+5)::timestamptz, (current_date+5)::timestamptz + interval '1 day',NULL,NULL,'{"name":"港中旅旅行社"}');

INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, consumed_quantity, meta)
VALUES (1,'admission',1,0,'{"gate":"特展入口 B2"}'),
 (2,'admission',1,1,'{"gate":"特展入口 B2"}'),
 (3,'admission',1,0,'{"gate":"特展入口 B2"}'),
 (4,'admission',1,0,'{"gate":"特展入口 B2"}');

-- 核销记录：一次成功 + 一次重复扫票。
-- 重复扫票不是错误，是事实 —— 票务欺诈的入口就在这里，压掉就看不见了。
INSERT INTO voucher_redemption (voucher_id, supplier_id, result, scanned_at, gate_location, device_id, reason, consumed_quantity)
VALUES (2,5,'success', (current_date+5)::timestamptz + interval '10 hours','特展入口 B2','POS-HK-0117',NULL,1),
       (2,5,'duplicate', (current_date+5)::timestamptz + interval '10 hours 30 minutes','特展入口 B2','POS-HK-0117','already_redeemed',0);

-- -------------------------------------------------------------------------------------
-- 13. 结算
-- -------------------------------------------------------------------------------------
INSERT INTO settlement_statement (id, supplier_id, channel_id, statement_no, period_start, period_end, currency, status, gross_amount, fee_amount, tax_amount, net_amount, source, imported_at) OVERRIDING SYSTEM VALUE
VALUES (1,5,1,'ST-PFT-202610','2026-10-01','2026-10-31','CNY','disputed',216.00,0.00,20.00,196.00,'import', now() - interval '2 days'),
 (2,4,2,'ST-GTX-202610','2026-10-01','2026-10-31','HKD','reconciled',236.00,0.00,0.00,236.00,'auto', now() - interval '2 days');

INSERT INTO settlement_line (id, statement_id, booking_id, order_id, external_ref, quantity, gross_amount, fee_amount, net_amount, currency, discrepancy_type, discrepancy_amount, note) OVERRIDING SYSTEM VALUE
VALUES (1,1,1,1,'PFT-BK-99001',2,216.00,0.00,216.00,'CNY','amount_mismatch',20.00,'源侧结算含税 236，账面成本 216'),
 (2,2,2,2,'GTX-BK-77021',2,236.00,0.00,236.00,'HKD',NULL,NULL,NULL);

-- -------------------------------------------------------------------------------------
-- 14. 报文归档 / 同步日志 / 通知 / 事件
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_raw_payload (supplier_id, entity_type, entity_ref, direction, request, response, http_status, latency_ms, trace_id, occurred_at)
VALUES (4,'booking','GTX-BK-77021','outbound','{"packageId":77301,"qty":2}','{"bookingRef":"GTX-BK-77021"}',200,688,'tr-9f2a', now() - interval '4 hours 55 minutes'),
 (4,'booking','GTX-BK-77021','inbound',NULL,'{"bookingRef":"GTX-BK-77021","status":"OK"}',200,NULL,'tr-9f2a', now() - interval '4 hours 55 minutes'),
 (5,'booking','PFT-BK-99001','inbound',NULL,'{"bookingId":"PFT-BK-99001","status":"confirmed"}',200,NULL,'tr-7c11', now() - interval '2 hours 55 minutes'),
 (5,'booking','PFT-BK-99001','inbound',NULL,'{"error":{"code":"STOCK_LOCKED"}}',409,233,'tr-3b90', now() - interval '20 minutes'),
 (1,'product','1234567','inbound',NULL,'{"id":1234567,"name":"Passeio gastronômico"}',200,220,'tr-1a22', now() - interval '1 day'),
 (3,'price','GF-55021','inbound',NULL,'{"date":"2026-11-05","price":125.00}',200,150,'tr-5d44', now() - interval '3 hours');

INSERT INTO sync_job_log (supplier_id, job_type, scope, status, started_at, finished_at, stats) VALUES
 (3,'price_sync','{"from":"2026-10-28","to":"2026-11-30"}','success', now() - interval '3 hours', now() - interval '3 hours' + interval '4 minutes','{"scanned":120,"updated":38,"skipped":82,"failed":0}'),
 (3,'inventory_sync','{"from":"2026-10-28","to":"2026-11-30"}','partial', now() - interval '30 minutes', now() - interval '26 minutes','{"scanned":480,"updated":120,"skipped":355,"failed":5}'),
 (4,'catalog_sync','{}','success', now() - interval '1 day', now() - interval '1 day' + interval '9 minutes','{"scanned":64,"created":2,"updated":11,"failed":0}'),
 (5,'availability_sync','{}','success', now() - interval '10 minutes', now() - interval '9 minutes','{"scanned":210,"updated":210,"failed":0}');

-- 归一化映射规则（配置驱动）
INSERT INTO attribute_mapping_rule (attribute_code, supplier_id, source_path, target_path, transform, priority, enabled)
VALUES ('duration_minutes',1,'$.duration','duration_minutes','{"type":"direct"}',10,true),
 ('duration_minutes',3,'$.durationMin','duration_minutes','{"type":"direct"}',10,true),
 ('duration_minutes',5,'$.durationMinutes','duration_minutes','{"type":"direct"}',10,true),
 ('age_limit',1,'$.minAge','age_limit','{"type":"wrap_min_age"}',10,true),
 ('age_limit',3,'$.minAge','age_limit','{"type":"wrap_min_age"}',10,true),
 ('mobile_voucher',4,'$.mobileVoucher','mobile_voucher','{"type":"direct"}',10,true),
 ('free_child_limit',4,'$.freeChildLimit','free_child_limit','{"type":"direct"}',10,true);

INSERT INTO notification_outbox (channel, template_code, recipient, payload, channels, status, attempts, next_retry_at)
VALUES ('sms','TICKET_ISSUED','+85290000001','{"order_no":"TC20261028000001"}',
 '[{"type":"sms","status":"sent","at":"2026-10-28T10:00:00Z"},{"type":"lark","status":"sent","at":"2026-10-28T10:00:03Z"},{"type":"email","status":"failed","at":"2026-10-28T10:00:09Z","error":"smtp timeout"}]',
 'partial',2, now() + interval '10 minutes'),
 ('lark','BOOKING_FAILED_ALERT','ops@demo','{"booking_no":"BK202610280003","error":"STOCK_LOCKED"}',
 '[{"type":"lark","status":"pending"}]','pending',0, now());

INSERT INTO event_outbox (aggregate_type, aggregate_id, event_type, payload, status, published_at)
VALUES ('order',1,'OrderConfirmed','{"order_no":"TC20261028000001"}','published', now() - interval '2 hours 50 minutes'),
 ('order',1,'VoucherIssued','{"voucher_no":"VC20261028000001"}','published', now() - interval '2 hours 55 minutes'),
 ('order',2,'OrderConfirmed','{"order_no":"TC20261028000002"}','published', now() - interval '4 hours 50 minutes'),
 ('order',3,'BookingFailed','{"booking_no":"BK202610280003","error":"STOCK_LOCKED"}','pending', NULL),
 ('voucher',2,'VoucherRedeemed','{"voucher_no":"VC20261028000002","result":"success"}','published', now() - interval '40 minutes');

INSERT INTO idempotency_record (scope, idempotency_key, request_hash, response, status, expires_at)
VALUES ('booking', 'bk-idem-001','sha256:aa11','{"bookingId":"PFT-BK-99001"}','done', now() + interval '1 day'),
 ('booking', 'bk-idem-002','sha256:bb22','{"bookingRef":"GTX-BK-77021"}','done', now() + interval '1 day'),
 ('booking', 'bk-idem-003','sha256:cc33',NULL,'in_progress', now() + interval '1 day');

-- 库存快照（同步模式源的历史留痕）
INSERT INTO inventory_snapshot (supplier_session_id, supplier_ticket_type_id, session_date, available_qty, held_qty, sold_qty, status)
VALUES (1,5, current_date+5, 18,0,2,'available'),
 (1,6, current_date+5, 12,0,0,'available'),
 (3,3, current_date+5,  8,0,0,'limited'),
 (5,7, current_date+5, 20,0,2,'available'),
 (6,9, current_date+7,  6,0,0,'limited'),
 (8,1, current_date+8, 10,1,1,'available'),
 (10,11,current_date+10, 0,0,0,'sold_out');

-- 可用性缓存（live 模式的短 TTL 缓存）
INSERT INTO availability_cache (cache_key, supplier_id, supplier_product_id, supplier_session_id, product_id, session_date, available_qty, status, expires_at)
VALUES ('av|4|1|2026-11-05',4,4,1,1, current_date+5,18,'available', now() + interval '5 minutes'),
 ('av|3|1|2026-11-05',3,3,3,1, current_date+5, 8,'limited',   now() + interval '5 minutes'),
 ('av|5|1|2026-11-05',5,5,5,1, current_date+5,20,'available', now() + interval '5 minutes'),
 ('av|8|6|2026-11-10',5,8,10,5,current_date+10, 0,'sold_out', now() + interval '5 minutes');

-- =====================================================================================
-- 15. C 端：展示内容 + 读模型 + 购买漏斗
--     这段数据刻意构造一条完整的 C 端链路：
--     列表卡片 → 日历 → 购物车(库存预占) → 结算必填(实名) → 下单(用券) → 出票 → 核销
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 15.1 标签体系
-- -------------------------------------------------------------------------------------
INSERT INTO tag (id, code, name, name_en, group_code, sort_order) OVERRIDING SYSTEM VALUE
VALUES (1,'mobile_voucher','手机出票','Mobile voucher','feature',10),
       (2,'instant_confirmation','即时确认','Instant confirmation','policy',20),
       (3,'free_cancellation','免费取消','Free cancellation','policy',30),
       (4,'skip_the_line','免排队','Skip the line','feature',40),
       (5,'includes_transfer','含接送','Transfer included','feature',50),
       (6,'guided_tour','含导览','Guided tour','feature',60),
       (7,'family_friendly','亲子友好','Family friendly','audience',70),
       (8,'limited_offer','限量优惠','Limited offer','promotion',80);

INSERT INTO product_tag_link (product_id, tag_id, source) VALUES
 (1,1,'manual'), (1,2,'manual'), (1,3,'manual'), (1,6,'manual'), (1,7,'manual'),
 (2,4,'manual'), (2,1,'manual'),
 (3,6,'manual'), (3,2,'manual'),
 (4,1,'manual'),
 (5,2,'manual'), (5,7,'manual');

-- -------------------------------------------------------------------------------------
-- 15.2 详情页展示内容（带 locale）
-- -------------------------------------------------------------------------------------
INSERT INTO product_highlight (id, product_id, locale, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (1,1,'zh-CN','西九龙文化区地标，2022年新馆，展品阵容亚洲第一',1),
       (2,1,'zh-CN','特展「香江故事」限定场次，人流低于常设展',2),
       (3,1,'zh-CN','现场电子票扫码入场，无需打印',3),
       (4,1,'en-HK','West Kowloon landmark, opened in 2022',1),
       (5,2,'zh-CN','免排队直达350米展望台',1),
       (6,2,'zh-CN','含天台展望层与露天咖啡座',2),
       (7,3,'zh-CN','本地主厨带路，六站停靠',1),
       (8,5,'zh-CN','一日通票含三个快速通行项目',1);

INSERT INTO product_inclusion (id, product_id, locale, kind, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (1,1,'zh-CN','include','特展展厅入场（限时特展票）',1),
       (2,1,'zh-CN','include','中英双语导览手册（电子版）',2),
       (3,1,'zh-CN','include','特展专属纪念品兑换券',3),
       (4,1,'zh-CN','exclude','馆内餐饮与纪念品购物需自费',1),
       (5,1,'zh-CN','exclude','专业导览团（约60分钟）不含',2),
       (6,5,'zh-CN','include','一日通票（四大主题区）',1),
       (7,5,'zh-CN','include','快速通行 3 次',2),
       (8,5,'zh-CN','exclude','酒店接送与餐饮',1);

INSERT INTO product_note (id, product_id, locale, kind, title, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (1,1,'zh-CN','important','入场说明','请出示购票时填写的持票人证件原件，电子票需在手机亮度充足时展示。',1),
       (2,1,'zh-CN','cancellation','取消政策','使用前48小时可免费取消；48小时内取消收取10%手续费；开场后不可退。',1),
       (3,1,'zh-CN','redeem','换票方式','无需换票，电子票码直达闸机。',1),
       (4,1,'zh-CN','faq','特展会延长开放时间吗？','常规闭馆日为周二，特展期间可能开放至21:00，以入场当日公告为准。',1),
       (5,1,'zh-CN','faq','儿童票怎么定义？','4至11周岁；未满4周岁免票，需成人陪同，每名成人限带1名。',2),
       (6,5,'zh-CN','important','入园说明','一人一票，入园需刷身份证；身高1.2米以下免票。',1),
       (7,5,'zh-CN','cancellation','取消政策','使用前24小时可免费取消，逾期不可退。',1);

INSERT INTO product_location (product_id, address, address_en, latitude, longitude, map_provider, place_id, meeting_point, transit_note, nearby)
VALUES (1,'西九文化区 博物馆道 6 号','6 Museum Road, West Kowloon Cultural District',22.304100,114.169500,'amap','B0FFH1P4','特展入口 B2（负二楼）','港铁九龙站步行约8分钟，渡轮天星码头有接驳巴士',
        '[{"name":"西九文化区 M+ 博物馆","distance_m":300},{"name":"香港故宫文化馆艺术馆","distance_m":150},{"name":"维港 waterfront","distance_m":900}]'),
 (2,'东京 押上 2-3-2','2-3-2 Oshiage, Tokyo',35.710100,139.810700,'amap','B0FFJ2P7','350米展望台 4F 电梯口','东京 Metro 晴海町站 3 号口步行约5分钟',
        '[{"name":"晴空塔购物中心","distance_m":200},{"name":"Tokyo Skytree Town","distance_m":350}]'),
 (3,'圣保罗 Praça da Sé 集合点','Praça da Sé, São Paulo',-23.547500,-46.638900,'google','ChIJX123','Praça da Sé 喷泉旁','地铁 Sé 站 B 出口',
        '[{"name":"圣保罗市立剧场","distance_m":250},{"name":"Sé 教堂","distance_m":120}]'),
 (4,'威尼斯 圣马可广场 总督宫','Piazza San Marco, Venezia',45.434200,12.338800,'google','ChIJY456','Doge 宫售票处','从圣马可广场步行2分钟',
        '[{"name":"圣马可大教堂","distance_m":150},{"name":"钟楼","distance_m":80}]'),
 (5,'上海 浦东新区 乐园 1 号门','1 号门, 浦东新区',31.238400,121.501100,'amap','B0FFC3P9','乐园 1 号门 右手边自助售票亭','地铁 2 号线直达，1 号门出站步行2分钟',
        '[{"name":"地铁 2 号线入口","distance_m":120},{"name":"酒店接送点","distance_m":400}]');

INSERT INTO product_review (id, product_id, order_id, rating, content, images, reviewer_hash, status, created_at) OVERRIDING SYSTEM VALUE
VALUES (1,1,1,5,'特展人比常设展少很多，值回票价。建议提前 10 分钟到，先逛 B2。','["https://cdn.demo/rev/1-1.jpg"]','u_9f2a','published', now() - interval '2 days'),
       (2,1,NULL,4,'电子票很方便，但周六下午排了 20 分钟队。','[]','u_77b1','published', now() - interval '9 days'),
       (3,1,NULL,5,'带娃很合适，导览手册电子版在手机上就能看。','["https://cdn.demo/rev/1-3.jpg","https://cdn.demo/rev/1-4.jpg"]','u_31c5','published', now() - interval '21 days'),
       (4,5,NULL,5,'快速通行三次基本不用排队，孩子玩得很开心。','[]','u_a0d2','published', now() - interval '5 days'),
       (5,5,NULL,4,'园区很大，建议提前规划路线，不然腿会很累。','[]','u_55e9','published', now() - interval '12 days'),
       (6,2,NULL,3,'价格比现场便宜，但现场等位时间长。','[]','u_6f30','pending', now() - interval '1 day');

-- -------------------------------------------------------------------------------------
-- 15.3 C 端读模型：列表卡片
--     from_price 取未来30天价格日历最小值（票种起价）
-- -------------------------------------------------------------------------------------
INSERT INTO c_product_card (channel_id, product_id, locale, title, subtitle, thumb_url, city_id, category_id,
                            rating, review_count, currency, from_price, list_price, next_available_date, available_days,
                            duration_minutes, age_min, tag_labels, selling_points, status, sort_weight)
VALUES
 (1,1,'zh-CN','香港故宫文化馆 特展门票','电子票 现场扫码核销','https://cdn.demo/palace/cover_s.jpg',1,1,
  4.6,1284,'CNY',95.00,115.00, current_date+5, 2, 120, 4,
  '["手机出票","即时确认","免费取消","含导览","亲子友好"]','["特展限时场次，人流低于常设展","无需打印，电子票直达闸机"]','online',100),
 (1,2,'zh-CN','东京晴空塔 展望台快速通道票','免排队入场','https://cdn.demo/skytree/cover_s.jpg',2,1,
  4.4,862,'CNY',118.00,138.00, current_date+7, 1, 90, 4,
  '["免排队","手机出票"]','["免排队直达350米展望台"]','online',90),
 (1,3,'zh-CN','圣保罗 美食步行之旅','本地美食 + 街区漫步','https://cdn.demo/gastro/cover_s.jpg',3,2,
  4.7,640,'CNY',188.50,218.00, current_date+8, 1, 240, 10,
  '["含导览","即时确认"]','["本地主厨带路，六站停靠"]','online',80),
 (1,4,'zh-CN','威尼斯总督宫 门票','含预留时段','https://cdn.demo/doge/cover_s.jpg',4,1,
  4.2,2310,'CNY',189.50,215.00, current_date+9, 1, 120, 0,
  '["手机出票"]','["官方通道入场，含预留时段"]','online',70),
 (1,5,'zh-CN','上海 主题乐园 全日票','一日通票 + 快速通行','https://cdn.demo/park/cover_s.jpg',5,1,
  4.5,5310,'CNY',238.00,268.00, current_date+10, 1, 600, 3,
  '["即时确认","亲子友好"]','["一日通票含三个快速通行项目"]','online',60),
 (1,1,'en-HK','Hong Kong Palace Museum Special Exhibition','E-ticket, scan on site','https://cdn.demo/palace/cover_s.jpg',1,1,
  4.6,1284,'CNY',95.00,115.00, current_date+5, 2, 120, 4,
  '["Mobile voucher","Instant confirmation","Free cancellation"]','["Limited special exhibition, shorter queues"]','online',100),
 (2,1,'zh-HK','香港故宫文化馆 特展门票','電子票 現場掃碼核銷','https://cdn.demo/palace/cover_s.jpg',1,1,
  4.6,1284,'HKD',88.00,105.00, current_date+5, 2, 120, 4,
  '["手機出票","即時確認","免費取消"]','["特展限時場次，人流低於常設展"]','online',100);

-- -------------------------------------------------------------------------------------
-- 15.4 C 端读模型：日历格子
-- -------------------------------------------------------------------------------------
INSERT INTO c_product_calendar (channel_id, product_id, date, price_min, price_max, ticket_types, status, session_count)
VALUES
 (1,1, current_date+5, 95.00,138.00,
  '[{"code":"adult","price":138.00,"status":"available"},{"code":"child","price":95.00,"status":"available"}]','available',1),
 (1,1, current_date+6, 95.00,138.00,
  '[{"code":"adult","price":138.00,"status":"available"},{"code":"child","price":95.00,"status":"limited"}]','available',1),
 (1,1, current_date+7, NULL,NULL,'[]','sold_out',0),
 (1,2, current_date+7, 118.00,168.00,
  '[{"code":"adult","price":168.00,"status":"available"},{"code":"child","price":118.00,"status":"available"}]','available',1),
 (1,3, current_date+8, 188.50,188.50,
  '[{"code":"adult","price":188.50,"status":"limited"}]','limited',1),
 (1,4, current_date+9, 189.50,189.50,
  '[{"code":"adult","price":189.50,"status":"available"}]','available',1),
 (1,5, current_date+10, 238.00,368.00,
  '[{"code":"adult","price":368.00,"status":"available"},{"code":"child","price":238.00,"status":"available"}]','available',1),
 (1,1, current_date+8, NULL,NULL,'[]','closed',0),
 (1,5, current_date+11, NULL,NULL,'[]','closed',0);

-- -------------------------------------------------------------------------------------
-- 15.5 结算必填规格（实名）—— 驱动 C 端动态表单
-- -------------------------------------------------------------------------------------
INSERT INTO checkout_requirement (id, product_id, ticket_type_id, channel_id, field_code, label, data_type, required, max_length, min_age, max_age, privacy_level, sort_order) OVERRIDING SYSTEM VALUE
VALUES (1,1,1,1,'holder_name','持票人姓名','string',true,60,12,NULL,'sensitive',1),
       (2,1,1,1,'id_number','证件号码','id_card',true,30,12,NULL,'sensitive',2),
       (3,1,2,1,'holder_name','持票人姓名','string',true,60,4,11,'sensitive',1),
       (4,1,2,1,'id_number','证件号码','id_card',true,30,4,11,'sensitive',2),
       (5,5,7,1,'holder_name','持票人姓名','string',true,60,12,NULL,'sensitive',1),
       (6,5,8,1,'holder_name','持票人姓名','string',true,60,3,11,'sensitive',1),
       (7,3,5,1,'holder_name','持票人姓名','string',true,60,12,NULL,'internal',1);

-- 持票人：订单1 是 C2C 渠道、P1 成人票 2 张 → 必须有 2 组 holder_name
INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, sequence, field_code, value, value_hash)
VALUES (1,1,1,1,'holder_name','陈小雅','h1'),
       (1,1,1,1,'id_number','H123456789','h2'),
       (1,1,1,2,'holder_name','林家豪','h3'),
       (1,1,1,2,'id_number','H987654321','h4'),
       -- 订单3（P5 成人票 ×1，已付款）：C2C 渠道要求实名
       (3,3,7,1,'holder_name','王大明','h5'),
       -- 订单4（P3 成人票 ×1，已填表但支付超时）：表单数据仍在
       (4,4,5,1,'holder_name','王大明','h6');

-- -------------------------------------------------------------------------------------
-- 15.6 购物车 + 库存预占
-- -------------------------------------------------------------------------------------
INSERT INTO cart (id, cart_no, channel_id, customer_id, status, expires_at) OVERRIDING SYSTEM VALUE
VALUES (1,'CART20261028001',1,1,'active', now() + interval '30 minutes'),
       (2,'CART20261028002',1,1,'expired', now() - interval '2 hours'),
       (3,'CART20261028003',1,3,'converted', now() - interval '1 day');

-- 库存预占（009）：supplier_session_id 是预占占的源侧场次，consumed_quantity 是已兑现的量。
-- 预占 2 已被订单 1 吃掉（所以是 consumed，且兑现量 = 预占量）。
INSERT INTO inventory_hold (id, hold_no, channel_id, product_session_id, ticket_type_id, supplier_id, quantity, status, order_id, cart_id, expires_at, released_at, supplier_session_id, consumed_quantity, release_reason) OVERRIDING SYSTEM VALUE
VALUES (1,'HOLD20261028001',1,1,1,5,2,'active',NULL,1, now() + interval '30 minutes',NULL,5,0,NULL),
       (2,'HOLD20261028002',1,1,1,5,2,'consumed',1,3, now() - interval '3 hours',NULL,5,2,NULL),
       (3,'HOLD20261028003',1,6,7,5,1,'released',NULL,2, now() - interval '2 hours', now() - interval '2 hours',10,0,'cart_abandoned');

INSERT INTO cart_item (id, cart_id, product_id, session_id, ticket_type_id, quantity, unit_price, price_snapshot, hold_id)
OVERRIDING SYSTEM VALUE VALUES (1,1,1,1,1,2,138.00,'{"sell_price":138.00,"cost":108.00}',1),
       (2,2,5,6,7,1,368.00,'{"sell_price":368.00,"cost":288.00}',3),
       (3,3,1,1,1,2,138.00,'{"sell_price":138.00,"cost":108.00}',2);

-- -------------------------------------------------------------------------------------
-- 15.7 优惠券
-- -------------------------------------------------------------------------------------
INSERT INTO coupon (id, code, name, channel_id, discount_type, discount_value, min_amount, max_discount,
                    applicable_scope, validity, usage_limit, used_count, per_customer_limit, status)
OVERRIDING SYSTEM VALUE VALUES (1,'WELCOME20','新客立减20元',1,'fixed',20.00,100.00,NULL,
        '{"product_ids":[1,2,5]}','{"from":"2026-10-01","to":"2026-12-31"}',500,1,1,'active'),
 (2,'HKBAY10','港币立减10元',2,'fixed',10.00,200.00,NULL,
        '{"product_ids":[1]}','{"from":"2026-10-01","to":"2026-12-31"}',NULL,0,NULL,'active'),
 (3,'SAVE12PCT','全场85折',NULL,'percent',15.00,NULL,80.00,
        '{"category_ids":[1]}','{"from":"2026-11-01","to":"2026-11-30"}',1000,0,3,'active'),
 (4,'EXPIRED10','已过期券',1,'fixed',10.00,NULL,NULL,'{}','{"from":"2026-08-01","to":"2026-08-31"}',NULL,0,NULL,'expired');

INSERT INTO coupon_redemption (coupon_id, order_id, customer_id, discount_amount, status)
VALUES (1,1,1,20.00,'used');

-- 订单1 使用了优惠券：同步更新金额与折扣明细
UPDATE sales_order SET coupon_id = 1, discount = 20.00, total = 256.00,
       discount_breakdown = '{"coupon":{"code":"WELCOME20","amount":20.00},"promotion":{"amount":0.00}}'
 WHERE id = 1;
UPDATE sales_payment SET amount = 256.00 WHERE order_id = 1;
UPDATE cart SET status = 'converted' WHERE id = 3;

-- -------------------------------------------------------------------------------------
-- 15.8 核销端（闸机 / 核销员）
-- -------------------------------------------------------------------------------------
INSERT INTO gate (id, supplier_id, code, name, location_name, latitude, longitude) OVERRIDING SYSTEM VALUE
VALUES (1,5,'PFT-HK-EXH-B2','特展 B2 闸机','香港故宫文化馆 B2',22.304100,114.169500),
       (2,4,'GTX-HK-EXH-A1','特展 A1 闸机','香港故宫文化馆 A1',22.304050,114.169400);

INSERT INTO gate_operator (id, gate_id, code, name) OVERRIDING SYSTEM VALUE
VALUES (1,1,'OP-HK-0117','张伟');

UPDATE voucher_redemption SET gate_id = 1, gate_operator_id = 1 WHERE voucher_id = 2 AND result = 'success';

-- -------------------------------------------------------------------------------------
-- 15.9 B 端渠道专属价格（证明卡片起价按渠道隔离）
--     币种由渠道决定（B2B_HK = HKD），金额由第 17 节的定价函数按渠道规则算。
-- -------------------------------------------------------------------------------------
INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, status, source)
VALUES (1,1,1,2, current_date+5,'HKD','active','calc'),
       (1,1,2,2, current_date+5,'HKD','active','calc'),
       (1,2,1,2, current_date+6,'HKD','active','calc'),
       (2,3,3,2, current_date+7,'HKD','active','calc');

-- -------------------------------------------------------------------------------------
-- 15.10 券核销补齐：订单2 使用港币券
-- -------------------------------------------------------------------------------------
INSERT INTO coupon_redemption (coupon_id, order_id, customer_id, discount_amount, status)
VALUES (2,2,2,10.00,'used');
UPDATE sales_order SET coupon_id = 2, discount = 10.00, total = 266.00,
       discount_breakdown = '{"coupon":{"code":"HKBAY10","amount":10.00},"promotion":{"amount":0.00}}'
 WHERE id = 2;
UPDATE sales_payment SET amount = 266.00 WHERE order_id = 2;
UPDATE coupon SET used_count = 1 WHERE id = 2;

-- =====================================================================================
-- 16. 变体轴与可售单元 —— 种子数据
--
-- 这一段同时做三件事：
--   16.1-16.2 迁移：把老数据搬进变体模型（老结构 = 只有人群一个轴的变体模型）
--   16.3-16.9 新增「自由行」与「Trip.com」两个源 + 北京环球影城（多维组合商品）
--   16.10      变体级订单链路：明细 / 预订 / 出票 / 实名
--
-- 环球影城是这个模型的关键验证对象：
--   维度 = 人群(成人/儿童/老年) × 票种(一日/双日) × 园区范围(单园区/园区通票) × 加购件(快速通行证)
--   两个源的分解方式完全不同：
--     Trip.com = 固定组合 SKU（一个 SKU 就是一个完整组合）
--     自由行   = 参数化售卖方案（人群/园区是下单参数，一个源变体覆盖多个规范变体）
--   于是同一张「成人一日园区通票」，Trip.com 精确命中，自由行靠宽覆盖命中；
--   而「儿童园区通票」只有自由行能供 —— 商品级路由给不出这个答案，变体级路由能。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 16.1 先修一个种子数据缺口：P5 上海主题乐园「儿童票」有对客售价，但没有任何源能供
--     （新不变量 34「有售价的变体必须至少有一个可履约源」会当场抓出这一条）
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_ticket_type (id, supplier_product_id, external_id, name, name_en, description, age_rule, is_optional, raw_payload) OVERRIDING SYSTEM VALUE
VALUES (14,8,'2','儿童票','Child',NULL,'{"min_age":3,"max_age":11}',false,'{"specId":2,"price":198.00}');

INSERT INTO ticket_type_mapping (supplier_ticket_type_id, ticket_type_id, price_adjustment, quantity_multiplier)
VALUES (14,8,'{}',1);

INSERT INTO supplier_price_calendar (supplier_product_id, supplier_ticket_type_id, supplier_session_id, product_id, date, currency, supplier_price, net_price, tax, min_qty, max_qty, status)
VALUES (8,14,10,5, current_date+10,'CNY',198.00,180.00,10,1,10,'available');

-- -------------------------------------------------------------------------------------
-- 16.2 迁移：老数据 → 变体模型
--     规则一：每个 (product, ticket_type) 生成一个 base 变体
--     规则二：每个 supplier_ticket_type 生成一个源变体，与规范票种做 1:1 精确覆盖映射
--     规则三：售价 / 成本价回填变体 id（此后价格粒度与路由粒度统一到变体）
-- -------------------------------------------------------------------------------------
INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order) OVERRIDING SYSTEM VALUE
SELECT tt.id, tt.product_id,
       p.product_code || '-' || tt.code,
       p.product_code || ':' || tt.code,
       p.title || ' · ' || tt.name,
       'base', tt.id, 'active', tt.sort_order
FROM ticket_type tt
JOIN product p ON p.id = tt.product_id;

INSERT INTO supplier_variant (id, supplier_product_id, external_variant_id, title, variant_attrs, status) OVERRIDING SYSTEM VALUE
SELECT stt.id, stt.supplier_product_id, stt.external_id, stt.name,
       jsonb_build_object('audience', tt.code, 'migrated_from', 'supplier_ticket_type:' || stt.id),
       'active'
FROM supplier_ticket_type stt
JOIN ticket_type_mapping ttm ON ttm.supplier_ticket_type_id = stt.id
JOIN ticket_type tt ON tt.id = ttm.ticket_type_id
ON CONFLICT (supplier_product_id, external_variant_id) DO NOTHING;

INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status)
SELECT sv.id, pv.id,
       jsonb_build_object('axes', jsonb_build_object('audience', jsonb_build_array(tt.code)),
                          'excludes', '[]'::jsonb),
       true, 'rule', 1.000, 'active'
FROM ticket_type_mapping ttm
JOIN supplier_ticket_type stt ON stt.id = ttm.supplier_ticket_type_id
JOIN supplier_variant sv ON sv.supplier_product_id = stt.supplier_product_id
                        AND sv.external_variant_id = stt.external_id
JOIN ticket_type tt ON tt.id = ttm.ticket_type_id
JOIN product_variant pv ON pv.product_id = tt.product_id AND pv.ticket_type_id = tt.id;

UPDATE price_calendar pc
   SET product_variant_id = pv.id
  FROM product_variant pv
 WHERE pv.product_id = pc.product_id
   AND pv.ticket_type_id = pc.ticket_type_id
   AND pc.product_variant_id IS NULL;

UPDATE supplier_price_calendar spc
   SET supplier_variant_id = sv.id,
       product_variant_id  = pv.id
  FROM supplier_ticket_type stt
  JOIN supplier_variant sv ON sv.supplier_product_id = stt.supplier_product_id
                          AND sv.external_variant_id = stt.external_id
  JOIN ticket_type_mapping ttm ON ttm.supplier_ticket_type_id = stt.id
  JOIN ticket_type tt ON tt.id = ttm.ticket_type_id
  JOIN product_variant pv ON pv.product_id = tt.product_id AND pv.ticket_type_id = tt.id
 WHERE spc.supplier_ticket_type_id = stt.id
   AND spc.supplier_product_id = stt.supplier_product_id
   AND spc.supplier_variant_id IS NULL;

-- -------------------------------------------------------------------------------------
-- 16.3 新增两个供应源：Zowoyoo/自由行（参数化售卖方案 + 聚合层） / Trip.com（固定组合 PLU）
--     ⚠ 商务参数与报文结构为示意值，上线前必须以各家接入文档/商务合同为准
-- -------------------------------------------------------------------------------------
INSERT INTO supplier (id, code, name, short_name, country_code, default_currency, timezone, status, capability, sync_policy, connector_version) OVERRIDING SYSTEM VALUE
VALUES (6,'zowoyoo','Zowoyoo（自由行）','ZWO','CN','CNY','Asia/Shanghai','active',
  '{"product":true,"price":true,"session":true,"availability":"pull_sync","booking":true,"cancel":true,"validate":false,"partial_booking":false,"partial_refund":false,"settlement":"monthly"}',
  '{"catalog":"daily","price":"every_6h","availability":"every_30m","webhook":false}','v1'),
 (7,'trip_com','Trip.com','TCT','CN','CNY','Asia/Shanghai','active',
  '{"product":true,"price":true,"session":true,"availability":"live","booking":true,"cancel":true,"validate":false,"partial_booking":false,"partial_refund":false,"settlement":"monthly"}',
  '{"catalog":"daily","price":"hourly","availability":"live","webhook":false}','v1');

INSERT INTO attribute_mapping_rule (attribute_code, supplier_id, source_path, target_path, transform, priority, enabled)
VALUES ('duration_minutes',6,'$.durationMinutes','duration_minutes','{"type":"direct"}',10,true),
       ('duration_minutes',7,'$.duration','duration_minutes','{"type":"direct"}',10,true);

-- -------------------------------------------------------------------------------------
-- 16.4 规范侧：北京环球影城 + 轴 + 取值 + 变体 + 加购件关系
-- -------------------------------------------------------------------------------------
INSERT INTO city (id, code, name, country_code, longitude, latitude, timezone) OVERRIDING SYSTEM VALUE
VALUES (6,'BJ','北京','CN',116.407400,39.904200,'Asia/Shanghai');

INSERT INTO product (id, product_code, title, subtitle, description, category_id, city_id, country_code, product_type, status, canonical_key, attributes, fulfilment_type, validity_rule, refund_policy, rating, review_count) OVERRIDING SYSTEM VALUE
VALUES (6,'SKU-CN-USJ-BEIJING','北京环球影城 门票','一日/双日 · 单园区/园区通票','含工作室之旅；园区通票另含超级任天堂世界等主题园区。',1,6,'CN','ticket','active','cn:bj:usj',
  '{"duration_minutes":600,"age_limit":{"min":3},"includes":["工作室之旅","园区通票可选"],"instant_confirmation":true,"mobile_voucher":true,"free_child_limit":1}',
  'qr_pickup','{"validity":"session_date","single_use":true,"timezone":"Asia/Shanghai"}',
  '{"refundable":true,"cutoff_hours":48,"fee_percent":10}',4.6,15230);

-- 人群维度沿用 ticket_type（历史订单语义不变）
INSERT INTO ticket_type (id, product_id, code, name, description, age_rule, stock_mode, sort_order) OVERRIDING SYSTEM VALUE
VALUES (9,6,'adult','成人票','12岁以上','{"min_age":12}','per_session',1),
       (10,6,'child','儿童票','4-11岁','{"min_age":4,"max_age":11}','per_session',2),
       (11,6,'senior','老年票','65岁以上','{"min_age":65}','per_session',3);

-- 人群之外的维度全部配置化
INSERT INTO product_axis (id, product_id, axis_code, axis_name, axis_kind, is_required, is_pricing, sort_order, status) OVERRIDING SYSTEM VALUE
VALUES (1,6,'pass_type','票种','enum',true,true,10,'active'),
       (2,6,'park_scope','园区范围','set',true,true,20,'active'),
       (3,6,'addon_type','加购件','enum',false,true,30,'active');

-- valid_days 是「这条取值有效几天」（010）：从 option_attrs 搬到独立列 ——
-- 它要被计算、被门禁断言，得有自己的类型和约束。搬了家就不再在 jsonb 里留一份。
INSERT INTO product_axis_option (id, axis_id, option_code, option_name, option_attrs, valid_days, sort_order, status) OVERRIDING SYSTEM VALUE
VALUES (1,1,'1d','一日票','{}',1,10,'active'),
       (2,1,'2d','双日票','{}',2,20,'active'),
       (3,2,'studio_only','工作室之旅（单园区）','{"park_ids":["studio_tour"],"park_names":["工作室之旅"]}',NULL,10,'active'),
       (4,2,'studio_snw','工作室之旅 + 超级任天堂世界','{"park_ids":["studio_tour","snw"],"park_names":["工作室之旅","超级任天堂世界"]}',NULL,20,'active'),
       (5,2,'studio_minion_hp','工作室之旅 + 小黄人乐园 + 哈利波特','{"park_ids":["studio_tour","minion_land","harry_potter"],"park_names":["工作室之旅","小黄人乐园","哈利波特"]}',NULL,30,'active'),
       (6,3,'express','快速通行证（不限次）','{"addon":"express"}',NULL,10,'active');

-- 可售变体 = 人群 × 票种 × 园区范围；加购件是独立可售变体（role=addon）
INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order) OVERRIDING SYSTEM VALUE
VALUES (9,6,'USJ-ADULT-1D-STD','adult:1d:studio_only','成人票 · 一日 · 工作室之旅','base',9,'active',10),
       (10,6,'USJ-CHILD-1D-STD','child:1d:studio_only','儿童票 · 一日 · 工作室之旅','base',10,'active',20),
       (11,6,'USJ-SENIOR-1D-STD','senior:1d:studio_only','老年票 · 一日 · 工作室之旅','base',11,'active',30),
       (12,6,'USJ-ADULT-1D-SNW','adult:1d:studio_snw','成人票 · 一日 · 园区通票（工作室之旅+超级任天堂世界）','base',9,'active',40),
       (13,6,'USJ-CHILD-1D-SNW','child:1d:studio_snw','儿童票 · 一日 · 园区通票（工作室之旅+超级任天堂世界）','base',10,'active',50),
       (14,6,'USJ-ADULT-2D-STD','adult:2d:studio_only','成人票 · 双日 · 工作室之旅','base',9,'active',60),
       (15,6,'USJ-CHILD-2D-STD','child:2d:studio_only','儿童票 · 双日 · 工作室之旅','base',10,'active',70),
       (16,6,'USJ-EXPRESS','addon:express','快速通行证（不限次）','addon',NULL,'active',80);

INSERT INTO product_variant_option (product_variant_id, axis_id, axis_option_id)
VALUES (9,1,1),(9,2,3),
       (10,1,1),(10,2,3),
       (11,1,1),(11,2,3),
       (12,1,1),(12,2,4),
       (13,1,1),(13,2,4),
       (14,1,2),(14,2,3),
       (15,1,2),(15,2,3),
       (16,3,6);

-- 加购件挂到所有基础变体上
INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, price_policy, sort_order)
SELECT pv.id, 16, 'optional_addon', '{"mode":"separate"}', 10
FROM product_variant pv
WHERE pv.product_id = 6 AND pv.variant_role = 'base';

-- -------------------------------------------------------------------------------------
-- 16.5 源侧：两个源商品 + 源变体 + 覆盖语义映射
--     Trip.com：分销接口「产品 → 套餐(package) → 资源(resource, bandCode=人群)」，
--               resource = 唯一价格与库存的单位 ↔ 我们的 supplier_variant（1:1 精确映射）；
--               (package × resource) 的组合 = 我们的 product_variant。
--               ⚠ 下面的 raw_payload 是**截断示意**（只列了 3 个 resource，实际源变体有 6 个），
--                 字段名与层级取自「门票活动全球分销接口文档」V2.0.25。
--     自由行  ：参数化售卖方案，一个源变体覆盖多个规范变体（宽覆盖）
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_product (id, supplier_id, external_id, external_code, external_url, raw_title, raw_payload, source_attributes, availability_mode, content_hash, status, last_synced_at) OVERRIDING SYSTEM VALUE
VALUES (9,7,'TC-USJ-1001','TC1001','https://sopenservice.ctrip.com/openservice/serviceproxy.ashx','北京环球影城 门票（组合票）',
  '{"productID":21081935,"business":"ACTIVITY","category":{"categoryID":3,"categoryName":"门票"},"name":"北京环球影城 门票（组合票）","duration":600,"locale":"zh-CN","currency":"CNY","packageList":[{"packageID":810001,"name":"一日票 · 单园区","description":"含工作室之旅","advanceBooking":{"days":0,"time":"23:59"},"resourceList":[{"resourceID":900001,"bandID":1,"bandCode":"ADULT","name":"1日票 成人（工作室之旅）","unitQuantity":1,"saleAloneType":1,"minQuantity":1,"maxQuantity":20},{"resourceID":900002,"bandID":2,"bandCode":"CHILD","name":"1日票 儿童（工作室之旅）","unitQuantity":1,"saleAloneType":1,"minQuantity":1,"maxQuantity":20}]},{"packageID":810002,"name":"一日票 · 园区通票","description":"工作室之旅 + 超级任天堂世界","resourceList":[{"resourceID":900003,"bandID":1,"bandCode":"ADULT","name":"1日票 成人 园区通票","unitQuantity":1,"saleAloneType":1,"minQuantity":1,"maxQuantity":20}]}]}',
  '{"source":"dist","packageList":[{"packageID":810001,"attrs":{"passType":"1d","parkScope":"studio_only"}},{"packageID":810002,"attrs":{"passType":"1d","parkScope":"studio_snw"}}],"resourceList":[{"resourceID":900001,"bandCode":"ADULT"},{"resourceID":900002,"bandCode":"CHILD"},{"resourceID":900003,"bandCode":"ADULT"}]}','live','h9','active',now()),
 (10,6,'ZWO-USJ-2001','ZWO2001','https://www.zowoyooglobal.com/product/2001','北京环球影城 门票（自由行）',
  '{"goodsId":"ZWO-USJ-2001","goodsName":"北京环球影城 门票","durationMinutes":600,"source":"aggregated","specList":[{"specId":"ZWO-1D-BASE","name":"一日票 · 单园区","price":520.00,"options":{"audience":["adult","child","senior"],"park":["studio_tour"]}},{"specId":"ZWO-1D-PARK","name":"一日票 · 园区通票","price":568.00,"options":{"audience":["adult","child"],"park":["studio_tour","snw"]}}]}',
  '{"source":"aggregated","specList":[{"specId":"ZWO-1D-BASE"},{"specId":"ZWO-1D-PARK"}]}','pull_sync','h10','active',now());

INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, match_type, confidence, match_evidence, is_primary, status, created_by)
VALUES (9,7,6,'manual',0.99,'{"signals":["title_exact","same_venue","same_city"],"decided_by":"ops@demo"}',true,'active','ops@demo'),
       (10,6,6,'manual',0.97,'{"signals":["title_exact","same_venue","same_city"],"decided_by":"ops@demo"}',false,'active','ops@demo');

INSERT INTO supplier_variant (id, supplier_product_id, external_variant_id, title, variant_attrs, status) OVERRIDING SYSTEM VALUE
VALUES (15,9,'900001','1日票 成人（工作室之旅）','{"audience":"adult","passType":"1d","parks":["studio_tour"]}','active'),
       (16,9,'900002','1日票 儿童（工作室之旅）','{"audience":"child","passType":"1d","parks":["studio_tour"]}','active'),
       (17,9,'900004','1日票 老年（工作室之旅）','{"audience":"senior","passType":"1d","parks":["studio_tour"]}','active'),
       (18,9,'900003','1日票 成人 园区通票（工作室之旅+超级任天堂世界）','{"audience":"adult","passType":"1d","parks":["studio_tour","snw"]}','active'),
       (19,9,'900005','双日票 成人（工作室之旅）','{"audience":"adult","passType":"2d","parks":["studio_tour"]}','active'),
       (20,9,'900006','快速通行证（不限次）','{"addon":"express"}','active'),
       (21,10,'ZWO-1D-BASE','一日票 · 单园区（工作室之旅）','{"audience":["adult","child","senior"],"passType":["1d"],"parks":["studio_tour"]}','active'),
       (22,10,'ZWO-1D-PARK','一日票 · 园区通票（工作室之旅+超级任天堂世界）','{"audience":["adult","child"],"passType":["1d"],"parks":["studio_tour","snw"]}','active'),
       (23,10,'ZWO-2D-BASE','双日票 · 单园区（工作室之旅）','{"audience":["adult","child"],"passType":["2d"],"parks":["studio_tour"]}','active'),
       (24,10,'ZWO-EXPRESS','快速通行证（不限次）','{"addon":"express"}','active');

-- 覆盖语义映射：Trip.com 精确命中；自由行一个源变体宽覆盖多个规范变体
INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status)
VALUES
 -- Trip.com：固定组合 SKU → 精确覆盖
 (15, 9, '{"axes":{"audience":["adult"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',true,'manual',1.000,'active'),
 (16,10, '{"axes":{"audience":["child"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',true,'manual',1.000,'active'),
 (17,11, '{"axes":{"audience":["senior"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',true,'manual',1.000,'active'),
 (18,12, '{"axes":{"audience":["adult"],"pass_type":["1d"],"park_scope":["studio_snw"]},"excludes":[]}',true,'manual',1.000,'active'),
 (19,14, '{"axes":{"audience":["adult"],"pass_type":["2d"],"park_scope":["studio_only"]},"excludes":[]}',true,'manual',1.000,'active'),
 (20,16, '{"axes":{"addon_type":["express"]},"excludes":[]}',true,'manual',1.000,'active'),
 -- 自由行：参数化售卖方案 → 宽覆盖（一个源变体覆盖多个规范变体）
 (21, 9, '{"axes":{"audience":["adult","child","senior"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',false,'rule',0.95,'active'),
 (21,10, '{"axes":{"audience":["adult","child","senior"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',false,'rule',0.95,'active'),
 (21,11, '{"axes":{"audience":["adult","child","senior"],"pass_type":["1d"],"park_scope":["studio_only"]},"excludes":[]}',false,'rule',0.95,'active'),
 (22,12, '{"axes":{"audience":["adult","child"],"pass_type":["1d"],"park_scope":["studio_snw"]},"excludes":[]}',false,'rule',0.95,'active'),
 (22,13, '{"axes":{"audience":["adult","child"],"pass_type":["1d"],"park_scope":["studio_snw"]},"excludes":[]}',false,'rule',0.95,'active'),
 (23,14, '{"axes":{"audience":["adult","child"],"pass_type":["2d"],"park_scope":["studio_only"]},"excludes":[]}',false,'rule',0.95,'active'),
 (23,15, '{"axes":{"audience":["adult","child"],"pass_type":["2d"],"park_scope":["studio_only"]},"excludes":[]}',false,'rule',0.95,'active'),
 (24,16, '{"axes":{"addon_type":["express"]},"excludes":[]}',true,'manual',1.000,'active');

-- -------------------------------------------------------------------------------------
-- 16.6 场次 + 源场次 + 场次源绑定
-- -------------------------------------------------------------------------------------
INSERT INTO product_session (id, product_id, session_date, slot_key, start_at, end_at, timezone, meeting_point, status, min_adult, max_adult, max_child) OVERRIDING SYSTEM VALUE
VALUES (7,6, current_date+12, 'default', (current_date+12)::timestamptz + interval '9 hours', NULL,'Asia/Shanghai','环球影城 城市大道','active',1,10,6);

INSERT INTO supplier_session (id, supplier_product_id, supplier_ticket_type_id, external_id, session_date, start_at, end_at, timezone, local_start_label, meeting_point, address, latitude, longitude, capacity, status, raw_payload) OVERRIDING SYSTEM VALUE
VALUES (11,9,NULL,'TC-D20261116', current_date+12,(current_date+12)::timestamptz + interval '9 hours',NULL,'Asia/Shanghai','09:00 - 入场当日','环球影城 城市大道','北京市通州区北京环球度假区',39.856500,116.665600,NULL,'active','{"visitDate":"2026-11-16"}'),
 (12,10,NULL,'ZYX-D20261116', current_date+12,(current_date+12)::timestamptz + interval '9 hours',NULL,'Asia/Shanghai','09:00 - 入场当日','环球影城 城市大道','北京市通州区北京环球度假区',39.856500,116.665600,NULL,'active','{"useDate":"2026-11-16"}');

INSERT INTO product_session_source (product_session_id, supplier_session_id, supplier_id, supplier_product_id, role, price_overlay, priority) OVERRIDING SYSTEM VALUE
VALUES (7,11,7,9,'primary','{}',10),
       (7,12,6,10,'fallback','{}',20);

-- -------------------------------------------------------------------------------------
-- 16.7 源成本价（变体级）：一行 = 一个源变体 × 一个规范组合 × 一个日期
--     自由行「一日票·单园区」这一个源变体，在成人/儿童/老年三个组合上价格不同
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_price_calendar (supplier_product_id, supplier_ticket_type_id, supplier_session_id, product_id, date, currency, supplier_price, net_price, tax, min_qty, max_qty, status, product_variant_id, supplier_variant_id)
VALUES
 -- Trip.com
 (9,NULL,11,6, current_date+12,'CNY',558.00,545.00,0,1,20,'available',9,15),
 (9,NULL,11,6, current_date+12,'CNY',448.00,436.00,0,1,20,'available',10,16),
 (9,NULL,11,6, current_date+12,'CNY',498.00,486.00,0,1,20,'available',11,17),
 (9,NULL,11,6, current_date+12,'CNY',658.00,642.00,0,1,20,'available',12,18),
 (9,NULL,11,6, current_date+12,'CNY',998.00,975.00,0,1,10,'available',14,19),
 (9,NULL,11,6, current_date+12,'CNY',358.00,349.00,0,1,30,'available',16,20),
 -- 自由行
 (10,NULL,12,6, current_date+12,'CNY',520.00,505.00,0,1,20,'available',9,21),
 (10,NULL,12,6, current_date+12,'CNY',448.00,418.00,0,1,20,'available',10,21),
 (10,NULL,12,6, current_date+12,'CNY',508.00,505.00,0,1,20,'available',11,21),
 (10,NULL,12,6, current_date+12,'CNY',568.00,552.00,0,1,15,'available',12,22),
 (10,NULL,12,6, current_date+12,'CNY',496.00,482.00,0,1,15,'available',13,22),
 (10,NULL,12,6, current_date+12,'CNY',880.00,856.00,0,1,10,'available',14,23),
 (10,NULL,12,6, current_date+12,'CNY',788.00,766.00,0,1,10,'available',15,23),
 (10,NULL,12,6, current_date+12,'CNY',348.00,338.00,0,1,30,'available',16,24);

-- -------------------------------------------------------------------------------------
-- 16.8 对客售价（变体级）：成本取该变体在各源中的最优净价
--     同样只写骨架，金额由第 17 节的定价函数回填。
-- -------------------------------------------------------------------------------------
INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, status, source, product_variant_id)
VALUES (6,7,9,NULL, current_date+12,'CNY','active','calc',9),
       (6,7,10,NULL,current_date+12,'CNY','active','calc',10),
       (6,7,11,NULL,current_date+12,'CNY','active','calc',11),
       (6,7,9,NULL, current_date+12,'CNY','active','calc',12),
       (6,7,10,NULL,current_date+12,'CNY','active','calc',13),
       (6,7,9,NULL, current_date+12,'CNY','active','calc',14),
       (6,7,10,NULL,current_date+12,'CNY','active','calc',15),
       (6,7,NULL,NULL,current_date+12,'CNY','active','calc',16);

-- -------------------------------------------------------------------------------------
-- 16.9 渠道上架 + 上架源绑定 + C 端读模型
-- -------------------------------------------------------------------------------------
INSERT INTO channel_listing (id, channel_id, product_id, status, price_policy, stock_policy, booking_policy, min_order_qty, max_order_qty, sort_weight, published_at) OVERRIDING SYSTEM VALUE
VALUES (9,1,6,'online','{"mode":"cost_plus","percent":16.0,"min_margin":0.12,"list_markup_percent":12.5}','{"mode":"full"}','{"mode":"instant","confirm_deadline_min":30}',1,10,50,now());

INSERT INTO channel_listing_source (channel_listing_id, supplier_product_id, supplier_id, priority, fallback_order, min_margin, max_daily_qty, enabled)
VALUES (9,9,7,10,1,0.12,NULL,true),    -- C端 · Trip.com 主
       (9,10,6,20,2,0.12,50,true);      -- C端 · 自由行 备（限每日配额）

INSERT INTO product_tag_link (product_id, tag_id, source) VALUES (6,2,'manual'),(6,7,'manual');

INSERT INTO product_highlight (id, product_id, locale, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (9,6,'zh-CN','园区通票含超级任天堂世界，热门项目无需另购',1),
       (10,6,'zh-CN','电子票直接刷身份证入园，无需换票',2);

INSERT INTO product_inclusion (id, product_id, locale, kind, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (9,6,'zh-CN','include','工作室之旅 + 所选主题园区（按票种）',1),
       (10,6,'zh-CN','include','快速通行证为可选加购件，单独计价',2);

INSERT INTO product_note (id, product_id, locale, kind, title, content, sort_order) OVERRIDING SYSTEM VALUE
VALUES (8,6,'zh-CN','important','入园说明','一人一票，入园需刷身份证；儿童票需填写出生日期。',1),
       (9,6,'zh-CN','faq','园区通票和单日票区别？','园区通票额外包含超级任天堂世界等主题园区；工作日与周末价不同，以日历价格为准。',2);

INSERT INTO product_location (product_id, address, address_en, latitude, longitude, map_provider, place_id, meeting_point, transit_note, nearby)
VALUES (6,'北京市通州区北京环球度假区','Universal Beijing Resort',39.856500,116.665600,'amap','B0FFUSJ1','城市大道入口','地铁 7 号线万盛东站直达',
        '[{"name":"北京环球度假区酒店区","distance_m":800},{"name":"城市大道商业街","distance_m":300}]');

INSERT INTO c_product_card (channel_id, product_id, locale, title, subtitle, thumb_url, city_id, category_id,
                            rating, review_count, currency, from_price, list_price, next_available_date, available_days,
                            duration_minutes, age_min, tag_labels, selling_points, status, sort_weight)
VALUES (1,6,'zh-CN','北京环球影城 门票','一日/双日 · 单园区/园区通票','https://cdn.demo/usj/cover_s.jpg',6,1,
  4.6,15230,'CNY',495.00,556.00, current_date+12, 1, 600, 3,
  '["即时确认","亲子友好"]','["园区通票含超级任天堂世界"]','online',50);

-- 变体级日历：同一天不同变体价格不同、可履约源数不同
INSERT INTO c_variant_calendar (channel_id, product_variant_id, date, price_min, price_max, status, source_count)
VALUES (1,9, current_date+12,585.00,585.00,'available',2),
       (1,10,current_date+12,495.00,495.00,'available',2),
       (1,11,current_date+12,565.00,565.00,'available',2),
       (1,12,current_date+12,645.00,645.00,'available',2),
       (1,13,current_date+12,565.00,565.00,'available',1),
       (1,14,current_date+12,985.00,985.00,'available',2),
       (1,15,current_date+12,885.00,885.00,'available',1),
       (1,16,current_date+12,398.00,398.00,'available',2);

-- 变体级实名要求：成人要证件号，儿童要出生日期
INSERT INTO checkout_requirement (id, product_id, ticket_type_id, channel_id, field_code, label, data_type, required, max_length, min_age, max_age, privacy_level, sort_order, product_variant_id) OVERRIDING SYSTEM VALUE
VALUES (8,6,9,1,'holder_name','持票人姓名','string',true,60,12,NULL,'sensitive',1,9),
       (9,6,9,1,'id_number','证件号码','id_card',true,30,12,NULL,'sensitive',2,9),
       (10,6,10,1,'holder_name','持票人姓名','string',true,60,4,11,'sensitive',1,10),
       (11,6,10,1,'dob','出生日期','date',true,NULL,4,11,'sensitive',2,10);

-- 变体级购物车 + 库存预占（园区通票与单园区票的库存配额是分开的）
INSERT INTO cart (id, cart_no, channel_id, customer_id, status, expires_at) OVERRIDING SYSTEM VALUE
VALUES (4,'CART20261103004',1,3,'active', now() + interval '30 minutes');

INSERT INTO inventory_hold (id, hold_no, channel_id, product_session_id, ticket_type_id, supplier_id, quantity, status, order_id, cart_id, expires_at, released_at, product_variant_id, supplier_session_id, consumed_quantity) OVERRIDING SYSTEM VALUE
VALUES (4,'HOLD20261103004',1,7,9,6,1,'active',NULL,4, now() + interval '30 minutes',NULL,12,12,0);

INSERT INTO cart_item (id, cart_id, product_id, session_id, ticket_type_id, quantity, unit_price, price_snapshot, hold_id, product_variant_id)
OVERRIDING SYSTEM VALUE VALUES (4,4,6,7,9,1,645.00,'{"sell_price":645.00,"cost":552.00,"variant":"adult:1d:studio_snw"}',4,12);

-- -------------------------------------------------------------------------------------
-- 16.10 变体级交易链路：订单 → 明细 → 预订 → 出票 → 实名
--     一单两行明细：成人园区通票 + 儿童园区通票（同一商品、不同变体、不同人群）
-- -------------------------------------------------------------------------------------
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, discount, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at, confirmed_at, completed_at) OVERRIDING SYSTEM VALUE
VALUES (5,'TC20261103000005',1,3,'fulfilled','paid','fulfilled','CNY',1210.00,0.00,0.00,1210.00,1034.00,0.00,
 '{"rule":"cost_plus","variants":["adult:1d:studio_snw","child:1d:studio_snw"],"currency":"CNY"}','{"name":"王大明"}',
 'idem-c2c-005', now() - interval '3 hours', now() - interval '2 hours 55 minutes', now() - interval '2 hours 50 minutes');

INSERT INTO sales_order_item (id, order_id, product_id, channel_listing_id, supplier_product_id, supplier_id, session_id, ticket_type_id, quantity, unit_price, unit_cost, total_price, currency, detail_snapshot, status, product_variant_id) OVERRIDING SYSTEM VALUE
VALUES (5,5,6,9,10,6,7,9,1,645.00,552.00,645.00,'CNY',
 '{"title":"北京环球影城 门票","variant":"adult:1d:studio_snw","variant_title":"成人票 · 一日 · 园区通票","date":"2026-11-16","parks":["studio_tour","snw"],"meeting_point":"环球影城 城市大道","ticket_type":"成人票"}','ticketed',12),
 (6,5,6,9,10,6,7,10,1,565.00,482.00,565.00,'CNY',
 '{"title":"北京环球影城 门票","variant":"child:1d:studio_snw","variant_title":"儿童票 · 一日 · 园区通票","date":"2026-11-16","parks":["studio_tour","snw"],"meeting_point":"环球影城 城市大道","ticket_type":"儿童票"}','ticketed',13);

INSERT INTO sales_payment (id, order_id, channel_id, payment_method, amount, currency, status, provider, provider_txn_id, paid_at) OVERRIDING SYSTEM VALUE
VALUES (4,5,1,'alipay',1210.00,'CNY','succeeded','alipay','ALI88000005', now() - interval '2 hours 58 minutes');

INSERT INTO booking (id, booking_no, order_id, order_item_id, supplier_id, supplier_product_id, supplier_session_id, external_booking_id, status, attempt_count, next_retry_at, idempotency_key, request_payload, response_payload, confirmed_at, supplier_variant_id) OVERRIDING SYSTEM VALUE
VALUES (4,'BK202611030004',5,5,6,10,12,'ZWO-BK-20261116-A','confirmed',1,NULL,'bk-idem-004',
 '{"goodsId":"ZWO-USJ-2001","specId":"ZWO-1D-PARK","useDate":"2026-11-16","qty":1,"audience":"adult"}',
 '{"bookingRef":"ZYX-BK-20261116-A","status":"OK"}', now() - interval '2 hours 56 minutes',22),
 (5,'BK202611030005',5,6,6,10,12,'ZWO-BK-20261116-C','confirmed',1,NULL,'bk-idem-005',
 '{"goodsId":"ZWO-USJ-2001","specId":"ZWO-1D-PARK","useDate":"2026-11-16","qty":1,"audience":"child"}',
 '{"bookingRef":"ZYX-BK-20261116-C","status":"OK"}', now() - interval '2 hours 56 minutes',22);

INSERT INTO booking_attempt (id, booking_id, attempt_no, request, response, http_status, latency_ms, error_type, error_message) OVERRIDING SYSTEM VALUE
VALUES (6,4,1,'{"specId":"ZWO-1D-PARK"}','{"bookingRef":"ZYX-BK-20261116-A"}',200,531,NULL,NULL),
       (7,5,1,'{"specId":"ZWO-1D-PARK"}','{"bookingRef":"ZYX-BK-20261116-C"}',200,498,NULL,NULL);

INSERT INTO booking_event (booking_id, from_status, to_status, event_type, payload) VALUES
 (4,NULL,'pending','BookingCreated','{}'),
 (4,'pending','requested','BookingRequested','{"attempt":1}'),
 (4,'requested','confirmed','BookingConfirmed','{"externalBookingId":"ZYX-BK-20261116-A"}'),
 (5,NULL,'pending','BookingCreated','{}'),
 (5,'pending','requested','BookingRequested','{"attempt":1}'),
 (5,'requested','confirmed','BookingConfirmed','{"externalBookingId":"ZYX-BK-20261116-C"}');

INSERT INTO voucher (id, voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id, ticket_type_id, session_id, code, qr_payload, status, issued_at, valid_from, valid_to, holder_snapshot, product_variant_id, supplier_variant_id) OVERRIDING SYSTEM VALUE
VALUES (5,'VC20261103000005',5,5,4,6,6,9,7,'ZWO99001','ZWO99001|5|c1d2e3f4','issued', now() - interval '2 hours 56 minutes', (current_date+12)::timestamptz, (current_date+12)::timestamptz + interval '1 day','{"name":"王大明"}',12,22),
 (6,'VC20261103000006',5,6,5,6,6,10,7,'ZWO99002','ZWO99002|6|c1d2e3f4','issued', now() - interval '2 hours 56 minutes', (current_date+12)::timestamptz, (current_date+12)::timestamptz + interval '1 day','{"name":"王小明"}',13,22);

INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, consumed_quantity, meta)
VALUES (5,'admission',1,0,'{"gate":"环球影城 城市大道","parks":["studio_tour","snw"]}'),
       (6,'admission',1,0,'{"gate":"环球影城 城市大道","parks":["studio_tour","snw"]}');

-- 实名：成人票与儿童票各 1 人
INSERT INTO order_holder (order_id, order_item_id, ticket_type_id, sequence, field_code, value, value_hash)
VALUES (5,5,9,1,'holder_name','王大明','h7'),
       (5,5,9,1,'id_number','110101199001011234','h8'),
       (5,6,10,1,'holder_name','王小明','h9'),
       (5,6,10,1,'dob','2018-05-20','h10');

-- -------------------------------------------------------------------------------------
-- 16.11 按团报价（priceSettingType=4）与价格保护（isPrivatePrice）—— 两个真实场景
--
--   A. 锁价：Trip.com 的「成人·一日·单园区」资源带 isPrivatePrice，
--      对客售价必须原样等于携程卖价 558.00，不允许加价。
--   B. 按团报价：携程日游产品的 priceSettingType=4（按团报价、最少 6 人成团），
--      此时「总价 = 单价 × 份数」不成立 —— 明细按 pricing_basis='per_group' 落库：
--      total_price = 团总价，unit_price = 人均分摊价，团总价真值记在明细快照 group_total。
-- -------------------------------------------------------------------------------------

-- A. 锁价：源侧标记 → 平台侧售价锁定
--    锁价是**采纳源**的属性，不是变体的固定属性。
--    这里刻意选「老年·一日·单园区」：它的采纳成本恰好来自 Trip.com（486 < Zowoyoo 505），
--    而 Trip.com 的这个资源带 isPrivatePrice → 对客售价必须原样等于携程卖价 498.00。
--    同一商品的其他变体采纳的是 Zowoyoo（非保护源）→ 售价可自主定价，未锁。
--    平台侧的 sell_price / price_locked 由第 17 节的定价函数按这条源属性派生，
--    这里不再手写 —— 手写就意味着「锁价」和「定价」是两套逻辑。
UPDATE supplier_variant SET is_price_locked = true WHERE id = 17;

UPDATE c_variant_calendar SET price_min = 498.00, price_max = 498.00 WHERE product_variant_id = 11;

-- B. 按团报价：北京一日游 团队票（源 = Trip.com 分销侧日游品类）
INSERT INTO product (id, product_code, title, subtitle, description, category_id, city_id, country_code, product_type, status, canonical_key, attributes, fulfilment_type, validity_rule, refund_policy, rating, review_count) OVERRIDING SYSTEM VALUE
VALUES (7,'SKU-CN-BJ-DAYTOUR','北京一日游 · 团队票','按团报价 · 最少 6 人成团','含中文导览与车船接送，按整团计价，不按人头计价。',2,6,'CN','package','active','cn:bj:daytour',
  '{"duration_minutes":480,"age_limit":{"min":0},"includes":["中文导览","车船接送","门票"],"pricing":"per_group","group_min":6,"group_max":40}',
  'ticket_code','{"validity":"session_date","single_use":true,"timezone":"Asia/Shanghai"}',
  '{"refundable":true,"cutoff_hours":72,"fee_percent":20}',4.5,3260);

INSERT INTO ticket_type (id, product_id, code, name, description, age_rule, stock_mode, sort_order) OVERRIDING SYSTEM VALUE
VALUES (12,7,'standard','标准票（不区分人群）','按团计价，不区分人群','{"min_age":0}','per_session',1);

INSERT INTO product_axis (id, product_id, axis_code, axis_name, axis_kind, is_required, is_pricing, sort_order, status) OVERRIDING SYSTEM VALUE
VALUES (4,7,'pass_type','行程天数','enum',true,true,10,'active');

INSERT INTO product_axis_option (id, axis_id, option_code, option_name, option_attrs, valid_days, sort_order, status) OVERRIDING SYSTEM VALUE
VALUES (7,4,'1d','一日行程','{}',1,10,'active');

INSERT INTO product_variant (id, product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order) OVERRIDING SYSTEM VALUE
VALUES (17,7,'BJ-TOUR-GROUP-1D','standard:1d','一日游 · 团队票（按团报价）','base',12,'active',10);

INSERT INTO product_variant_option (product_variant_id, axis_id, axis_option_id) VALUES (17,4,7);

INSERT INTO supplier_product (id, supplier_id, external_id, external_code, external_url, raw_title, raw_payload, source_attributes, availability_mode, content_hash, status, last_synced_at) OVERRIDING SYSTEM VALUE
VALUES (11,7,'TC-BJ-TOUR-001','TC-TOUR-001','https://sopenservice.ctrip.com/openservice/serviceproxy.ashx','北京一日游 团队票',
  '{"productID":21082001,"business":"TOUR","category":{"categoryID":12,"categoryName":"一日游"},"name":"北京一日游 团队票","locale":"zh-CN","currency":"CNY","packageList":[{"packageID":810101,"name":"标准行程 · 按团报价","priceSettingType":4,"groupMinLimit":6,"groupMaxLimit":40,"resourceList":[{"resourceID":900101,"bandID":9,"bandCode":"STANDARD","name":"标准票（不区分人群）","unitQuantity":1,"saleAloneType":1,"minQuantity":1,"maxQuantity":40}]}]}',
  '{"source":"dist","priceSettingType":4,"groupMinLimit":6,"groupMaxLimit":40,"resourceList":[{"resourceID":900101,"bandCode":"STANDARD"}]}','live','h11','active',now());

INSERT INTO product_mapping (supplier_product_id, supplier_id, product_id, match_type, confidence, match_evidence, is_primary, status, created_by)
VALUES (11,7,7,'manual',0.95,'{"signals":["title_exact","same_city","category:一日游"],"decided_by":"ops@demo"}',true,'active','ops@demo');

INSERT INTO supplier_variant (id, supplier_product_id, external_variant_id, title, variant_attrs, status) OVERRIDING SYSTEM VALUE
VALUES (25,11,'900101','标准票（不区分人群）','{"audience":"standard","passType":"1d","pricing":"per_group"}','active');

INSERT INTO supplier_variant_mapping (supplier_variant_id, product_variant_id, coverage, is_exact, match_type, confidence, status)
VALUES (25,17,'{"axes":{"audience":["standard"],"pass_type":["1d"]},"excludes":[]}',true,'manual',1.000,'active');

INSERT INTO product_session (id, product_id, session_date, slot_key, start_at, end_at, timezone, meeting_point, status, min_adult, max_adult, max_child) OVERRIDING SYSTEM VALUE
VALUES (8,7, current_date+13, 'default', (current_date+13)::timestamptz + interval '8 hours', NULL,'Asia/Shanghai','东方广场集合点','active',6,40,0);

INSERT INTO supplier_session (id, supplier_product_id, supplier_ticket_type_id, external_id, session_date, start_at, end_at, timezone, local_start_label, meeting_point, address, latitude, longitude, capacity, status, raw_payload) OVERRIDING SYSTEM VALUE
VALUES (13,11,NULL,'TC-D20261117', current_date+13,(current_date+13)::timestamptz + interval '8 hours',NULL,'Asia/Shanghai','08:00 - 当日','东方广场集合点','北京市东城区',39.908800,116.418000,40,'active','{"visitDate":"2026-11-17"}');

INSERT INTO product_session_source (product_session_id, supplier_session_id, supplier_id, supplier_product_id, role, price_overlay, priority) OVERRIDING SYSTEM VALUE
VALUES (8,13,7,11,'primary','{}',10);

-- 源成本价：一行 = 一个源变体 × 一个规范变体 × 一个日期；此处金额是**团总价**
INSERT INTO supplier_price_calendar (supplier_product_id, supplier_ticket_type_id, supplier_session_id, product_id, date, currency, supplier_price, net_price, tax, min_qty, max_qty, status, product_variant_id, supplier_variant_id)
VALUES (11,NULL,13,7, current_date+13,'CNY',1200.00,1100.00,100.00,6,40,'available',17,25);

-- 对客售价：团总价（不是「单价 × 人数」）。金额由定价函数按 per_group 规则算：
--     售价 = 源方团报价（1200.00），平台不加价；毛利口径与单份不同，不套 min_margin。
INSERT INTO price_calendar (product_id, session_id, ticket_type_id, channel_id, date, currency, status, source, product_variant_id)
VALUES (7,8,12,NULL, current_date+13,'CNY','active','calc',17);

-- 按团报价的上架规则：售价 = 源方团报价，平台不加价（毛利口径由商务单独约定，不套 min_margin）。
INSERT INTO channel_listing (id, channel_id, product_id, status, price_policy, stock_policy, booking_policy, min_order_qty, max_order_qty, sort_weight, published_at) OVERRIDING SYSTEM VALUE
VALUES (10,1,7,'online','{"mode":"per_group","group_min":6,"list_markup_percent":15.0,"note":"按团报价：总价=团总价，与人数不成正比"}','{"mode":"full"}','{"mode":"instant"}',1,2,40,now());

INSERT INTO channel_listing_source (channel_listing_id, supplier_product_id, supplier_id, priority, fallback_order, min_margin, max_daily_qty, enabled)
VALUES (10,11,7,10,1,0,NULL,true);

INSERT INTO c_product_card (channel_id, product_id, locale, title, subtitle, thumb_url, city_id, category_id,
                            rating, review_count, currency, from_price, list_price, next_available_date, available_days,
                            duration_minutes, age_min, tag_labels, selling_points, status, sort_weight)
VALUES (1,7,'zh-CN','北京一日游 · 团队票','按团报价 · 最少 6 人成团','https://cdn.demo/daytour/cover_s.jpg',6,2,
  4.5,3260,'CNY',1200.00,1380.00, current_date+13, 1, 480, 0,
  '["即时确认","含导览"]','["按整团计价，最少 6 人成团"]','online',40);

INSERT INTO c_variant_calendar (channel_id, product_variant_id, date, price_min, price_max, status, source_count)
VALUES (1,17,current_date+13,1200.00,1200.00,'available',1);

-- 订单 6：按团报价的一单 —— 一行明细，7 人，团总价 1200.00，人均分摊 171.43
INSERT INTO sales_order (id, order_no, channel_id, customer_id, status, payment_status, fulfillment_status, currency, subtotal, discount, tax, total, cost_total, commission_amount, pricing_snapshot, contact_snapshot, idempotency_key, placed_at, confirmed_at, completed_at) OVERRIDING SYSTEM VALUE
VALUES (6,'TC20261103000006',1,3,'fulfilled','paid','fulfilled','CNY',1200.00,0.00,0.00,1200.00,1100.00,0.00,
 '{"rule":"per_group","group_total":1200.00,"group_size":7,"pricing_basis":"per_group","note":"按团报价，总价与人头数不成正比"}','{"name":"王大明"}',
 'idem-c2c-006', now() - interval '4 hours', now() - interval '3 hours 55 minutes', now() - interval '3 hours 50 minutes');

INSERT INTO sales_order_item (id, order_id, product_id, channel_listing_id, supplier_product_id, supplier_id, session_id, ticket_type_id, quantity, unit_price, unit_cost, total_price, currency, detail_snapshot, status, product_variant_id, pricing_basis) OVERRIDING SYSTEM VALUE
VALUES (7,6,7,10,11,7,8,12,7,171.43,157.14,1200.00,'CNY',
 '{"title":"北京一日游 · 团队票","date":"2026-11-17","group_total":1200.00,"group_size":7,"price_setting_type":4,"pricing_basis":"per_group","unit_quantity":1,"ticket_type":"标准票（不区分人群）","meeting_point":"东方广场集合点"}','ticketed',17,'per_group');

-- -------------------------------------------------------------------------------------
-- 16.13 订单侧的库存预占（009）
--
-- 每条订单明细都要有一条预占记录：「我们卖出去多少」必须查得到（不变量 69）。
-- 订单 1 的预占在上面（预占 2，已 consumed），这里补订单 2-6 的。
--
-- 订单 4 未付款超时 → 它的预占被作废了（voided），但仍挂在订单上：
-- 票卖过又收回来了，兑现量仍是 1（事实不能改写）。
--
-- consumed_quantity 是「这张预占里已经兑现的量」：被订单吃掉的那部分。
-- -------------------------------------------------------------------------------------
INSERT INTO inventory_hold (id, hold_no, channel_id, product_session_id, ticket_type_id, supplier_id,
                            quantity, status, order_id, cart_id, expires_at, released_at,
                            product_variant_id, supplier_session_id, consumed_quantity, release_reason)
OVERRIDING SYSTEM VALUE
VALUES (5,'HOLD20261028005',2,1,1,4,2,'consumed',2,NULL, now() - interval '5 hours',NULL,NULL,1,2,NULL),
       (6,'HOLD20261028006',1,6,7,5,1,'consumed',3,NULL, now() - interval '40 minutes',NULL,NULL,10,1,NULL),
       (7,'HOLD20261028007',1,4,5,1,1,'voided',4,NULL, now() - interval '2 days', now() - interval '2 days',NULL,8,1,'order_expired'),
       (8,'HOLD20261103008',1,7,9,6,1,'consumed',5,NULL, now() - interval '3 hours',NULL,12,12,1,NULL),
       (9,'HOLD20261103009',1,7,10,6,1,'consumed',5,NULL, now() - interval '3 hours',NULL,13,12,1,NULL),
       (10,'HOLD20261103010',1,8,12,7,7,'consumed',6,NULL, now() - interval '4 hours',NULL,17,13,7,NULL);

INSERT INTO sales_payment (id, order_id, channel_id, payment_method, amount, currency, status, provider, provider_txn_id, paid_at) OVERRIDING SYSTEM VALUE
VALUES (5,6,1,'alipay',1200.00,'CNY','succeeded','alipay','ALI88000006', now() - interval '3 hours 58 minutes');

INSERT INTO booking (id, booking_no, order_id, order_item_id, supplier_id, supplier_product_id, supplier_session_id, external_booking_id, status, attempt_count, next_retry_at, idempotency_key, request_payload, response_payload, confirmed_at, supplier_variant_id) OVERRIDING SYSTEM VALUE
VALUES (6,'BK202611030006',6,7,7,11,13,'TC-BK-TOUR-001','confirmed',1,NULL,'bk-idem-006',
 '{"productID":21082001,"resourceID":900101,"visitDate":"2026-11-17","groupSize":7}',
 '{"bookingRef":"TC-BK-TOUR-001","status":"OK"}', now() - interval '3 hours 56 minutes',25);

INSERT INTO booking_attempt (id, booking_id, attempt_no, request, response, http_status, latency_ms, error_type, error_message) OVERRIDING SYSTEM VALUE
VALUES (8,6,1,'{"resourceID":"900101"}','{"bookingRef":"TC-BK-TOUR-001"}',200,462,NULL,NULL);

INSERT INTO booking_event (booking_id, from_status, to_status, event_type, payload) VALUES
 (6,NULL,'pending','BookingCreated','{}'),
 (6,'pending','requested','BookingRequested','{"attempt":1}'),
 (6,'requested','confirmed','BookingConfirmed','{"externalBookingId":"TC-BK-TOUR-001"}');

INSERT INTO voucher (id, voucher_no, order_id, order_item_id, booking_id, product_id, supplier_id, ticket_type_id, session_id, code, qr_payload, status, issued_at, valid_from, valid_to, holder_snapshot, product_variant_id, supplier_variant_id) OVERRIDING SYSTEM VALUE
VALUES (7,'VC20261103000007',6,7,6,7,7,12,8,'TC99001','TC99001|7|e5f6a7b8','issued', now() - interval '3 hours 56 minutes', (current_date+13)::timestamptz, (current_date+13)::timestamptz + interval '1 day','{"name":"王大明","group_size":7}',17,25);

INSERT INTO voucher_entitlement (voucher_id, entitlement_type, quantity, consumed_quantity, meta)
VALUES (7,'admission',7,0,'{"gate":"东方广场集合点","group_size":7,"pricing_basis":"per_group"}');

-- -------------------------------------------------------------------------------------
-- 16.12 序列对齐：种子数据用了显式 id，identity 序列必须同步推进
--
-- 以前这里是 20 行手写的 setval，只覆盖了变体那轮改动过的表。
-- 结果 product / ticket_type / supplier_product / customer / cart / inventory_hold
-- 等 19 张表的序列停在 1，而 max(id) 已经到十几 —— 应用第一次 INSERT 就撞主键。
--
-- 改成遍历 public schema 下所有 identity 序列，新增表不会再漏。
--
-- 位置有讲究：**显式 id 的插入必须在这一段之前**（它们不会推进序列）；
-- 这一段之后的调用（函数自己取 id）会正常消耗序列，对齐不会被打破。
-- 第 18 节的组合套餐走真实下单链路，所以它放在这一段之后。
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
  r     record;
  mx    bigint;
  got   bigint;
  stale text := '';
BEGIN
  -- 用 pg_depend 找序列的归属，不走 pg_get_serial_sequence：
  -- 那个函数在遇到没有目标列的表时会直接报错（pg_statistic 就会踩到）。
  FOR r IN
    SELECT s.relname AS seq,
           c.relname AS tbl,
           a.attname AS col
    FROM pg_class s
    JOIN pg_depend d
      ON d.objid = s.oid
     AND d.classid = 'pg_class'::regclass
     AND d.deptype IN ('a', 'i')          -- a = serial 自增，i = identity 自增
    JOIN pg_class c ON c.oid = d.refobjid
    JOIN pg_attribute a
      ON a.attrelid = c.oid
     AND a.attnum = d.refobjsubid
     AND NOT a.attisdropped
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND s.relkind = 'S'
  LOOP
    EXECUTE format('SELECT COALESCE(max(%I),0) FROM %I', r.col, r.tbl) INTO mx;
    IF mx = 0 THEN
      -- 表是空的，序列归零到 1 且不消耗
      EXECUTE format('SELECT setval(%L, 1, false)', r.seq);
      CONTINUE;
    END IF;
    EXECUTE format('SELECT setval(%L, %s, true)', r.seq, mx);
    EXECUTE format('SELECT last_value FROM %s', r.seq) INTO got;
    IF got < mx THEN
      stale := stale || r.tbl || ' ';
    END IF;
  END LOOP;

  IF stale <> '' THEN
    RAISE EXCEPTION '序列未对齐（seed 之后应用无法插入）：%', stale;
  END IF;
END $$;

-- -------------------------------------------------------------------------------------
-- -------------------------------------------------------------------------------------
-- 17. 定价：唯一的实现在这
--
-- 前面所有 price_calendar 行都只写了骨架（卖哪一行），金额在这里一次性算出来：
--   fn_price_variant(变体, 日期, 规则来源渠道, 售价行写给哪个渠道)
-- 成本、售价、划线价、折扣、锁价标记、汇率留痕全部来自这个函数。
--
-- 为什么必须是它：
--   - 同一批源数据，视图、Go 接入层、演练器、种子数据要给出同一个价格；
--   - 钱必须是 NUMERIC（硬约束 5），Python 那份用 float() 算钱迟早差一分钱；
--   - 锁价、按团报价、折算口径如果各写一份，三份实现迟早各说各话。
--
-- 默认行（channel_id IS NULL）归 C 端自营渠道：规则与可选源都取自它的上架关系，
-- 由 fn_default_context_channel() 决定，不靠谁记得「默认行是 channel 1」。
-- -------------------------------------------------------------------------------------
-- UPDATE 的 FROM 项的参数里不能直接引用被更新的表（那是「引用 FROM-clause entry」错误的来源），
-- 所以重算逻辑放在数据库函数里：种子数据、演练器、接入层都调同一个 fn_reprice_rows()。
SELECT fn_reprice_rows();

-- 骨架必须全部定价成功：留下一行没有售价的价格 = 卖不出去也不报错。
DO $$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(format('变体%s@%s', pc.product_variant_id, pc.date), ', ')
    INTO v_missing
    FROM price_calendar pc
   WHERE pc.status = 'active'
     AND (pc.sell_price IS NULL OR pc.cost_price IS NULL);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '这些售价行没有被定价（缺源报价/缺上架关系/缺汇率快照）：%', v_missing;
  END IF;
END $$;

-- 17.1 C 端读模型跟着价格刷新
--     刷新动作只有一个实现：fn_refresh_read_models()（db/migrations/002_read_model_refresh.sql）。
--     种子、演练器、接入层、将来的定时作业都调它 —— 口径写在函数里，不写在调用方。
--     口径：渠道可见的售价行里未来 30 天的最小售价（渠道专属行优先），排除加购件。
SELECT * FROM fn_refresh_read_models();

-- =====================================================================================
-- 18. 组合套餐（异构融合方向 B）：家庭套票
--
-- 012 把「一个可售单元由多个源 SKU 按数量组成」这件事**表达**出来了：
--   规范侧声明组件与数量（product_variant_relation.quantity），
--   源侧给配方（supplier_variant_composition）。
-- 013 让它真的能卖：定价、预订、出券三条写路径都接组合。
--
-- 这一节是它的验证对象：
--   组合：家庭套票 = 2 份成人一日园区通票 + 1 份儿童一日园区通票
--   规范侧声明：成人成分（变体 9）× 2、儿童成分（变体 10）× 1
--   源侧配方：两个成分都由 Zowoyoo 的**同一个**源 SKU（sv 21）顶
--
-- 配方刻意用同一个源 SKU 顶两个成分：
--   Zowoyoo 的「一日票 · 单园区」是人群参数化的 SKU（成人/儿童/老年都在里面），
--   家庭套票就是「这个 SKU 订 3 份，其中 2 份成人、1 份儿童」。
--   012 的唯一键（一个组合里一个源 SKU 只出现一次）把这个形状拒了，
--   013 放宽成（组合, 成分, 源 SKU）—— 这是异构融合最常见的一种形状，
--   不放宽就只能接「源侧成人票、儿童票各自一个 SKU」的那一种。
--
-- 订单走**真实函数**建，不手写 INSERT：
--   fn_place_order → fn_record_payment → fn_create_bookings
--   → fn_request_booking → fn_complete_booking（出券在最后一步里）
--   手写 INSERT 只能证明「种子数据长得对」，证明不了「代码跑得通」。
--   这里的每一行成分行、每条预订、每张券，都是被测代码自己写出来的。
--
-- 这一节的组合**没有** price_calendar 行 —— 所以它还上不了 C 端日历。
-- 原因是组合的「有效期终点」和「人群标签」还没定（1 天还是 2 天？家庭还是成人+儿童？），
-- 硬塞进读模型就是让前端自己加一天、自己猜人群。
-- 那是下一段的事，见 013 迁移文首「这一段暂时没做的」。
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 18.1 规范侧：组合变体 + 组件声明
--
-- 组合变体自己没有票种（成人 + 儿童混在一张套餐里），
-- 它「是什么」由组件声明说：2 份成人一日园区通票 + 1 份儿童一日园区通票。
--
-- 组合变体的 id 由序列分配（后面一律用 variant_key 找它）：
-- 显式写 id 不会推进 identity 序列，序列就落后于 max(id) ——
-- 应用第一次 INSERT 就撞主键（016 序列对齐那段门禁就是查这个）。
-- -------------------------------------------------------------------------------------
INSERT INTO product_variant (product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order)
VALUES (6,'USJ-FAMILY-2A1C','family:2adult:1child:studio_only','家庭套票 · 2 成人 + 1 儿童（工作室之旅）','combo',NULL,'active',90);

-- 组件声明：声明的是**规范侧**的成分与数量（「卖的是 2 大 1 小」）。
INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 9, 'included', 2, '{}', 10
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult:1child:studio_only';

INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 10, 'included', 1, '{}', 20
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult:1child:studio_only';

-- -------------------------------------------------------------------------------------
-- 18.2 源侧配方：成分 ↔ 源 SKU ↔ 份数
--
-- 「配对关系记下来，不靠猜」：同一个源 SKU 顶成人成分还是儿童成分，
-- 靠这一行说清楚 —— 对账时逐行比，不用去猜。
-- -------------------------------------------------------------------------------------
INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 9, 21, 2, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult:1child:studio_only';

INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 10, 21, 1, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult:1child:studio_only';

-- -------------------------------------------------------------------------------------
-- 18.3 定价：组合的成本 = Σ 成分单价 × 成分数量
--
--   2 × 505.00（成人，单园区）+ 1 × 418.00（儿童，单园区）= 1428.00
--   售价 = 1428 × (1 + 16%) = 1656.48
--
-- 这里断言的是「定价的唯一实现算出来的数」，
-- 不是把数写死在种子里再让别的代码去凑 —— 写死就等于两份实现。
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    v_price    RECORD;
    v_variant  BIGINT;
    v_expected NUMERIC := 1428.00;
BEGIN
    SELECT id INTO v_variant
      FROM product_variant
     WHERE variant_key = 'family:2adult:1child:studio_only';

    IF v_variant IS NULL THEN
        RAISE EXCEPTION '组合套餐变体没建起来';
    END IF;

    SELECT * INTO v_price
      FROM fn_price_variant(v_variant, current_date + 12, 1, 1);

    IF NOT FOUND THEN
        RAISE EXCEPTION '组合套餐 % 定价失败（配方不齐 / 成分缺价 / 跨源 / 不同场次）', v_variant;
    END IF;

    IF v_price.cost_price <> v_expected THEN
        RAISE EXCEPTION '组合套餐成本算错：期望 %，实际 %', v_expected, v_price.cost_price;
    END IF;

    IF v_price.sell_price <> 1656.48 THEN
        RAISE EXCEPTION '组合套餐售价算错：期望 1656.48，实际 %', v_price.sell_price;
    END IF;

    IF NOT (v_price.rule->'combo' IS NOT NULL AND jsonb_array_length(v_price.rule->'combo') = 2) THEN
        RAISE EXCEPTION '组合套餐的价格快照里没有成分明细（rule->combo）';
    END IF;
END $$;

-- -------------------------------------------------------------------------------------
-- 18.4 交易链路：一张套餐 → 一条预订 → 三张券
--
-- 客户买的是**一份**套餐（订单里一行明细）。
--
-- 预订的单位是**源 SKU**，不是成分（014 修订）：
-- 成人票与儿童票在源侧是同一个参数化 SKU（ZWO-1D-BASE，人群是购买时选的一档），
-- 所以源侧只收一次单，我们要发三张券（2 成人 + 1 儿童）。
--
-- 如果按成分建预订，就是同一个源 SKU 被订两次 ——
-- 源侧看到两张订单单，我们这边一条客户订单对两个源单号，对账对不上。
-- 这一节跑的就是这条链路，并当场把「只有一条预订」断言住。
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    v_order_id BIGINT;
    v_order_no TEXT;
    v_total    NUMERIC;
    v_booking  BIGINT;
    v_item_id  BIGINT;
    v_variant  BIGINT;
BEGIN
    SELECT id INTO v_variant
      FROM product_variant
     WHERE variant_key = 'family:2adult:1child:studio_only';

    -- 下单：一份套餐，三位持票人（按成分分组：成人成分 2 人、儿童成分 1 人）
    SELECT o.order_id, o.order_no, o.order_total
      INTO v_order_id, v_order_no, v_total
      FROM fn_place_order(
               1,
               'idem-c2c-007-combo',
               jsonb_build_array(jsonb_build_object(
                   'variant_id', v_variant, 'quantity', 1, 'visit_date', current_date + 12)),
               3,
               jsonb_build_object('name', '王大明'),
               NULL,
               jsonb_build_array(
                   -- 成人成分（变体 9）2 人：姓名 + 证件
                   jsonb_build_object('variant_id', 9, 'sequence', 1, 'field_code', 'holder_name', 'value', '王大明'),
                   jsonb_build_object('variant_id', 9, 'sequence', 1, 'field_code', 'id_number',  'value', '110101199001011234'),
                   jsonb_build_object('variant_id', 9, 'sequence', 2, 'field_code', 'holder_name', 'value', '李大明'),
                   jsonb_build_object('variant_id', 9, 'sequence', 2, 'field_code', 'id_number',  'value', '110101199001011235'),
                   -- 儿童成分（变体 10）1 人：姓名 + 生日
                   jsonb_build_object('variant_id', 10, 'sequence', 1, 'field_code', 'holder_name', 'value', '王小明'),
                   jsonb_build_object('variant_id', 10, 'sequence', 1, 'field_code', 'dob',        'value', '2018-05-20'))
           ) o;

    IF v_order_id IS NULL THEN
        RAISE EXCEPTION '组合套餐下单失败';
    END IF;

    -- 支付
    PERFORM fn_record_payment(v_order_id, 'alipay', v_total, 'CNY', 'alipay', 'ALI88000007');

    -- 预订：一个源 SKU 一条预订（成人与儿童在源侧是同一个参数化 SKU）
    PERFORM fn_create_bookings(v_order_id);

    SELECT count(*) INTO v_booking
      FROM booking b
     WHERE b.order_id = v_order_id;

    IF v_booking <> 1 THEN
        RAISE EXCEPTION '组合套餐应该产生 1 条预订（同一个源 SKU 只订一次），实际 % 条', v_booking;
    END IF;

    SELECT min(id) INTO v_booking
      FROM booking b
     WHERE b.order_id = v_order_id;

    -- 这条预订覆盖两个成分、3 份入场（成分的拆分留在请求明细里）
    IF (SELECT count(*) FROM fn_booking_components(v_booking)) <> 2 THEN
        RAISE EXCEPTION '组合套餐的预订应该覆盖 2 个成分，实际 % 个',
          (SELECT count(*) FROM fn_booking_components(v_booking));
    END IF;

    IF (SELECT COALESCE(sum(c.admission_quantity), 0) FROM fn_booking_components(v_booking) c) <> 3 THEN
        RAISE EXCEPTION '组合套餐的预订应该覆盖 3 份入场（2 成人 + 1 儿童），实际 %',
          (SELECT COALESCE(sum(c.admission_quantity), 0) FROM fn_booking_components(v_booking) c);
    END IF;

    -- 向源侧下单并出券：票码按成分顺序给（成人 2 张 + 儿童 1 张 = 3 张）
    PERFORM fn_request_booking(v_booking);

    PERFORM fn_complete_booking(
        v_booking,
        'confirmed',
        'ZWO-BK-FAMILY-001',
        jsonb_build_object('bookingRef', 'ZYX-BK-FAMILY-001', 'status', 'OK'),
        NULL, NULL, ARRAY['ZWO99101','ZWO99102','ZWO99103']);

    -- ---- 断言：一份套餐 → 三张券 → 订单履约完成 ----
    SELECT id INTO v_item_id
      FROM sales_order_item
     WHERE order_id = v_order_id;

    IF (SELECT count(*) FROM sales_order_item WHERE order_id = v_order_id) <> 1 THEN
        RAISE EXCEPTION '组合套餐应该只有一行订单明细';
    END IF;

    IF (SELECT count(*) FROM sales_order_item_source WHERE order_item_id = v_item_id) <> 2 THEN
        RAISE EXCEPTION '组合套餐应该落 2 行成分';
    END IF;

    IF (SELECT count(*) FROM voucher WHERE order_item_id = v_item_id AND status = 'issued') <> 3 THEN
        RAISE EXCEPTION '组合套餐应该发 3 张券（2 成人 + 1 儿童），实际 % 张',
          (SELECT count(*) FROM voucher WHERE order_item_id = v_item_id AND status = 'issued');
    END IF;

    -- 三张券要分对成分：成人 2 张挂成分 9，儿童 1 张挂成分 10
    IF (SELECT count(*) FROM voucher
         WHERE order_item_id = v_item_id AND status = 'issued' AND product_variant_id = 9) <> 2 THEN
        RAISE EXCEPTION '组合套餐应该有 2 张成人券（成分 9），实际 % 张',
          (SELECT count(*) FROM voucher
            WHERE order_item_id = v_item_id AND status = 'issued' AND product_variant_id = 9);
    END IF;

    IF (SELECT count(*) FROM voucher
         WHERE order_item_id = v_item_id AND status = 'issued' AND product_variant_id = 10) <> 1 THEN
        RAISE EXCEPTION '组合套餐应该有 1 张儿童券（成分 10），实际 % 张',
          (SELECT count(*) FROM voucher
            WHERE order_item_id = v_item_id AND status = 'issued' AND product_variant_id = 10);
    END IF;

    -- 持票人按成分归位：儿童那张必须是王小明，不能挂到成人头上
    IF (SELECT holder_snapshot->>'holder_name' FROM voucher
         WHERE order_item_id = v_item_id AND product_variant_id = 10 AND status = 'issued') <> '王小明' THEN
        RAISE EXCEPTION '儿童券的持票人应该是王小明（按成分归位，不按票种）';
    END IF;

    IF (SELECT count(*) FROM voucher
         WHERE order_item_id = v_item_id AND status = 'issued'
           AND product_variant_id = 9
           AND holder_snapshot->>'holder_name' IN ('王大明', '李大明')) <> 2 THEN
        RAISE EXCEPTION '两张成人券的持票人应该是王大明与李大明';
    END IF;

    IF (SELECT status FROM sales_order WHERE id = v_order_id) <> 'fulfilled' THEN
        RAISE EXCEPTION '组合套餐出票后订单应为 fulfilled，实际 %',
          (SELECT status FROM sales_order WHERE id = v_order_id);
    END IF;

    IF (SELECT status FROM sales_order_item WHERE id = v_item_id) <> 'ticketed' THEN
        RAISE EXCEPTION '组合套餐出票后明细应为 ticketed，实际 %',
          (SELECT status FROM sales_order_item WHERE id = v_item_id);
    END IF;

    IF (SELECT count(*) FROM order_holder WHERE order_item_id = v_item_id) <> 6 THEN
        RAISE EXCEPTION '组合套餐应收 6 条持票人字段（成人 2 人 × 2 字段 + 儿童 1 人 × 2 字段），实际 % 条',
          (SELECT count(*) FROM order_holder WHERE order_item_id = v_item_id);
    END IF;

    IF (SELECT count(*) FROM inventory_hold WHERE order_id = v_order_id AND status = 'consumed') <> 2 THEN
        RAISE EXCEPTION '组合套餐应该有 2 张成分预占（每个成分一张），实际 % 张',
          (SELECT count(*) FROM inventory_hold WHERE order_id = v_order_id AND status = 'consumed');
    END IF;
END $$;

-- 18.5 组合套餐的退款：整单退，事实一起改
--
-- 套餐退起来不是「退一行」，是**退掉整张配方**：
-- 三张券全部作废、一条预订取消（源侧只收了一次单）、两条预占全部收回。
-- 这一节走的是真实退款函数（发起 → 放行 → 完成），不是 UPDATE。
--
-- 为什么种子要留一笔退过款的套餐：
--   退过款的订单，预占是 voided（卖过又收回，兑现量仍是原数）；
--   如果不变量只认 consumed，这笔订单就被自己判成「没预占」——
--   正好是「作废不是消失」这条规矩的反面。留着它，不变量 69 才有牙齿。
-- -------------------------------------------------------------------------------------
DO $$
DECLARE
    v_order_id  BIGINT;
    v_order_no  TEXT;
    v_total     NUMERIC;
    v_booking   BIGINT;
    v_refund_id BIGINT;
    v_variant   BIGINT;
BEGIN
    SELECT id INTO v_variant
      FROM product_variant
     WHERE variant_key = 'family:2adult:1child:studio_only';

    SELECT o.order_id, o.order_no, o.order_total
      INTO v_order_id, v_order_no, v_total
      FROM fn_place_order(
               1,
               'idem-c2c-008-combo-refund',
               jsonb_build_array(jsonb_build_object(
                   'variant_id', v_variant, 'quantity', 1, 'visit_date', current_date + 12)),
               3,
               jsonb_build_object('name', '赵小红'),
               NULL,
               jsonb_build_array(
                   jsonb_build_object('variant_id', 9, 'sequence', 1, 'field_code', 'holder_name', 'value', '赵小红'),
                   jsonb_build_object('variant_id', 9, 'sequence', 1, 'field_code', 'id_number',  'value', '110101199002022345'),
                   jsonb_build_object('variant_id', 9, 'sequence', 2, 'field_code', 'holder_name', 'value', '钱小红'),
                   jsonb_build_object('variant_id', 9, 'sequence', 2, 'field_code', 'id_number',  'value', '110101199002022346'),
                   jsonb_build_object('variant_id', 10, 'sequence', 1, 'field_code', 'holder_name', 'value', '孙小红'),
                   jsonb_build_object('variant_id', 10, 'sequence', 1, 'field_code', 'dob',        'value', '2019-03-11'))
           ) o;

    IF v_order_id IS NULL THEN
        RAISE EXCEPTION '组合套餐（待退款）下单失败';
    END IF;

    PERFORM fn_record_payment(v_order_id, 'wechat', v_total, 'CNY', 'wechat', 'WX88000008');
    PERFORM fn_create_bookings(v_order_id);

    -- 出券（和 18.4 同一个配方，不同票码）
    -- 预订的单位是源 SKU：成人与儿童共用一个参数化 SKU → 一条预订、三张券
    SELECT min(id) INTO v_booking
      FROM booking b
     WHERE b.order_id = v_order_id;

    IF v_booking IS NULL THEN
        RAISE EXCEPTION '组合套餐（待退款）没有预订';
    END IF;

    PERFORM fn_request_booking(v_booking);

    PERFORM fn_complete_booking(
        v_booking,
        'confirmed',
        'ZWO-BK-FAM2-001',
        jsonb_build_object('bookingRef', 'ZYX-BK-FAM2-001', 'status', 'OK'),
        NULL, NULL, ARRAY['ZWO99201','ZWO99202','ZWO99203']);

    -- 退款：发起 → 放行 → 完成
    SELECT r.refund_id INTO v_refund_id
      FROM fn_request_refund(v_order_id, v_total, '组合套餐整单退款', 'seed', 'idem-refund-combo-001') r;

    IF v_refund_id IS NULL THEN
        RAISE EXCEPTION '组合套餐退款发起失败';
    END IF;

    PERFORM fn_approve_refund(v_refund_id, 'seed');
    PERFORM fn_complete_refund(v_refund_id, TRUE, 'ZWO-RF-FAMILY-001');

    -- ---- 断言：整单退，事实一起改 ----
    IF (SELECT status FROM sales_order WHERE id = v_order_id) <> 'refunded' THEN
        RAISE EXCEPTION '组合套餐退款后订单应为 refunded，实际 %',
          (SELECT status FROM sales_order WHERE id = v_order_id);
    END IF;

    IF (SELECT count(*) FROM voucher WHERE order_id = v_order_id AND status = 'refunded') <> 3 THEN
        RAISE EXCEPTION '组合套餐退款应作废 3 张券，实际 % 张',
          (SELECT count(*) FROM voucher WHERE order_id = v_order_id AND status = 'refunded');
    END IF;

    IF (SELECT count(*) FROM booking WHERE order_id = v_order_id AND status = 'cancelled') <> 1 THEN
        RAISE EXCEPTION '组合套餐退款应取消 1 条预订（同一个源 SKU 只订了一次），实际 % 条',
          (SELECT count(*) FROM booking WHERE order_id = v_order_id AND status = 'cancelled');
    END IF;

    -- 预占：voided（卖过又收回），兑现量仍是原数 —— 事实不许被改写
    IF (SELECT count(*) FROM inventory_hold WHERE order_id = v_order_id AND status = 'voided') <> 2 THEN
        RAISE EXCEPTION '组合套餐退款应收回 2 条预占，实际 % 条',
          (SELECT count(*) FROM inventory_hold WHERE order_id = v_order_id AND status = 'voided');
    END IF;

    IF (SELECT count(*) FROM inventory_hold
         WHERE order_id = v_order_id AND status = 'voided' AND consumed_quantity <> quantity) <> 0 THEN
        RAISE EXCEPTION '组合套餐退款后预占的兑现量必须仍是原数（卖出的事实不许被改写）';
    END IF;
END $$;

-- -------------------------------------------------------------------------------------
-- 18.6 第二张套餐：2 日成人 + 1 日儿童（异构的真正难点）
--
-- 第一张套餐（2 份一日成人 + 1 份一日儿童）两个成分的窗口一样长 ——
-- 「组合的有效期 = 成分窗口的并集」在它身上看不出差别（并集 = 1 天）。
--
-- 这一张不一样：
--   - 有效期：成人是两日票、儿童是一日票 → 并集 = 2 天
--     （不是 1 天，也不是「2+1=3 天」）；
--   - 源 SKU：两个（ZWO-2D-BASE 顶成人、ZWO-1D-BASE 顶儿童），
--     同一个源（自由行），两个 SKU —— 这正是方向 B 的样子；
--   - C 端：日历格子的有效期终点必须是「格子日期 + 2 天」，
--     前端不许自己加一天。
--
-- 有了这一张，「组合的有效期 = 并集」这条口径才真的被验过：
-- 把规则改成「取最短」或「写死 1 天」，这里立刻红。
-- -------------------------------------------------------------------------------------
INSERT INTO product_variant (product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order)
VALUES (6,'USJ-FAMILY-2A2D1C','family:2adult2d:1child1d:studio_only','家庭套票 · 2 成人（两日）+ 1 儿童（一日）（工作室之旅）','combo',NULL,'active',91);

-- 成分声明：2 份两日成人 + 1 份一日儿童
INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 14, 'included', 2, '{}', 10
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult2d:1child1d:studio_only';

INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 10, 'included', 1, '{}', 20
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult2d:1child1d:studio_only';

-- 源侧配方：两个源 SKU，同一个源（自由行）
INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 14, 23, 2, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult2d:1child1d:studio_only';

INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 10, 21, 1, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'family:2adult2d:1child1d:studio_only';

DO $$
DECLARE
    v_variant BIGINT;
    v_price   RECORD;
BEGIN
    SELECT id INTO v_variant
      FROM product_variant
     WHERE variant_key = 'family:2adult2d:1child1d:studio_only';

    IF v_variant IS NULL THEN
        RAISE EXCEPTION '第二张套餐变体没建起来';
    END IF;

    -- 成分的窗口不一样：两日成人 + 一日儿童
    IF fn_variant_validity_days(14) <> 2 OR fn_variant_validity_days(10) <> 1 THEN
        RAISE EXCEPTION '成分的有效期不对：两日成人应为 2 天（实际 %），一日儿童应为 1 天（实际 %）',
          fn_variant_validity_days(14), fn_variant_validity_days(10);
    END IF;

    -- 组合的窗口 = 并集 = 最长的那个 = 2 天
    IF fn_variant_validity_days(v_variant) <> 2 THEN
        RAISE EXCEPTION '组合的有效期应为 2 天（成分窗口的并集），实际 % 天',
          fn_variant_validity_days(v_variant);
    END IF;

    -- 成本 = 2 × 两日成人 + 1 × 一日儿童
    SELECT * INTO v_price
      FROM fn_price_variant(v_variant, current_date + 12, 1, 1);

    IF NOT FOUND THEN
        RAISE EXCEPTION '第二张套餐定价失败（配方不齐 / 成分缺价 / 跨源 / 不同场次）';
    END IF;

    IF v_price.cost_price <> 2130.00 THEN
        RAISE EXCEPTION '第二张套餐成本算错：期望 2130.00，实际 %', v_price.cost_price;
    END IF;

    IF v_price.sell_price <> 2470.80 THEN
        RAISE EXCEPTION '第二张套餐售价算错：期望 2470.80，实际 %', v_price.sell_price;
    END IF;
END $$;

-- -------------------------------------------------------------------------------------
-- -------------------------------------------------------------------------------------
-- 18.7 第三张套餐：跨币种的一张（源侧日元，我们卖人民币）
--
-- 前两张套餐的成分都在人民币源上，售价 = Σ 成分价，没有折算这回事。
-- 这一张不一样：成分的源价是**日元**（goodfellows_jtb 的东京晴空塔快速通行证），
-- 我们卖的是人民币 —— 成本要折算，折算的留痕必须能独立复算。
--
-- 组合的顶层没有单一源币种，所以它的售价行上 fx_rate / fx_as_of 是空的
-- （那是「这里没有单一的值」，不是「同币种、汇率 1」）。
-- 逐成分的折算留痕在 rule->'combo' 里：
--
--   {"currency": "JPY", "fx_rate": 0.0464..., "fx_as_of": "2026-01-01", ...}
--
-- 这就是为什么这条路径需要自己的门禁：普通可售单元的折算留痕由不变量 45 复查
-- （它按 cost_source_product_id join 源价行），而组合的 cost_source_product_id 是空的 ——
-- 不变量 45 直接跳过组合。留痕没人复查 = 留了个假日期都没人知道。
-- 不变量 92 专门查这件事。
-- -------------------------------------------------------------------------------------
INSERT INTO product_variant (product_id, variant_code, variant_key, title, variant_role, ticket_type_id, status, sort_order)
VALUES (2,'JP-SKYTREE-FAMILY-2A1C','jp:family:2adult:1child','东京晴空塔家庭票 · 2 成人 + 1 儿童','combo',NULL,'active',80);

-- 成分声明：2 份成人 + 1 份儿童
INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 3, 'included', 2, '{}', 10
  FROM product_variant pv
 WHERE pv.variant_key = 'jp:family:2adult:1child';

INSERT INTO product_variant_relation (parent_variant_id, child_variant_id, relation_type, quantity, price_policy, sort_order)
SELECT pv.id, 4, 'included', 1, '{}', 20
  FROM product_variant pv
 WHERE pv.variant_key = 'jp:family:2adult:1child';

-- 源侧配方：两个源 SKU，同一个源（goodfellows_jtb，源币种 JPY）
INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 3, 9, 2, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'jp:family:2adult:1child';

INSERT INTO supplier_variant_composition (product_variant_id, component_variant_id, supplier_variant_id, quantity, status)
SELECT pv.id, 4, 12, 1, 'active'
  FROM product_variant pv
 WHERE pv.variant_key = 'jp:family:2adult:1child';

DO $$
DECLARE
    v_variant BIGINT;
    v_price   RECORD;
BEGIN
    SELECT id INTO v_variant
      FROM product_variant
     WHERE variant_key = 'jp:family:2adult:1child';

    IF v_variant IS NULL THEN
        RAISE EXCEPTION '跨币种套餐变体没建起来';
    END IF;

    SELECT * INTO v_price
      FROM fn_price_variant(v_variant, current_date + 7, 1, 1);

    IF NOT FOUND OR v_price.sell_price IS NULL THEN
        RAISE EXCEPTION '跨币种套餐定价失败（配方不齐 / 成分缺价 / 跨源 / 不同场次）';
    END IF;

    -- 源侧是日元，我们卖人民币 —— 折算必须真的发生
    IF v_price.currency <> 'CNY' THEN
        RAISE EXCEPTION '跨币种套餐的本行币种应为 CNY，实际 %', v_price.currency;
    END IF;

    -- 组合顶层没有单一源币种：源币种与源净价必须是空的
    -- （填成 1 就是声称「没折算过」，那会让对账去查一份不存在的折算）
    IF v_price.source_currency IS NOT NULL THEN
        RAISE EXCEPTION '组合不应有单一源币种，实际 %', v_price.source_currency;
    END IF;

    -- 逐成分的折算留痕必须在，且必须带快照日期（折算过就得留痕）
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_price.rule->'combo') c
         WHERE c->>'currency' = 'JPY'
           AND c->>'fx_as_of' IS NOT NULL
           AND (c->>'fx_rate')::numeric <> 1)
    THEN
        RAISE EXCEPTION '跨币种套餐的成分折算留痕缺失（成分必须带 JPY 的折算因子与快照日期）';
    END IF;
END $$;

-- 18.8 组合在 C 端：售价行 + 日历格子 + 读模型（015）
--
-- 组合在任何源侧都没有对应的商品条目 —— 它是我们自己的配方，
-- 源侧的目录同步作业看不见它。所以它的售价行与日历格子由它自己推：
--
--   fn_sync_combo_calendar()  按成分的售价行推出组合的售价行（金额来自定价函数），
--                              再按上架关系推出日历格子；
--   fn_refresh_read_models()  把格子里的价格、有效期终点、构成写进读模型。
--
-- 做完这一步，C 端才画得出这两张家庭套餐：价格、成分、各自管几天。
-- -------------------------------------------------------------------------------------
SELECT * FROM fn_sync_combo_calendar();
SELECT * FROM fn_refresh_read_models();

DO $$
DECLARE
    v_combo        BIGINT := (SELECT id FROM product_variant WHERE variant_key = 'family:2adult:1child:studio_only');
    v_combo_mixed  BIGINT := (SELECT id FROM product_variant WHERE variant_key = 'family:2adult2d:1child1d:studio_only');
    v_composition  INT;
    v_feed_rows    INT;
BEGIN
    -- 组合必须有一行售价（金额来自定价函数，不是手写的）
    IF (SELECT count(*) FROM price_calendar
         WHERE product_variant_id = v_combo AND status = 'active' AND sell_price IS NOT NULL) = 0 THEN
        RAISE EXCEPTION '组合必须有一行带售价的售价行（C 端画不出它）';
    END IF;

    -- 日历格子上必须有价格：挂着一个卖不了的套餐 = 白占一个位置
    IF (SELECT count(*) FROM c_variant_calendar
         WHERE product_variant_id = v_combo AND status = 'available' AND price_min IS NULL) <> 0 THEN
        RAISE EXCEPTION '组合的日历格子必须带价格';
    END IF;

    -- 读模型里必须看得见这张组合，且看得见它的成分
    SELECT count(*) INTO v_feed_rows
      FROM v_c_variant_feed
     WHERE product_variant_id = v_combo AND is_combo AND component_count = 2;
    IF v_feed_rows <> 1 THEN
        RAISE EXCEPTION 'C 端读模型里必须有一行组合（2 个成分），实际 % 行', v_feed_rows;
    END IF;

    SELECT count(*) INTO v_composition
      FROM v_c_variant_composition
     WHERE product_variant_id = v_combo;
    IF v_composition <> 2 THEN
        RAISE EXCEPTION 'C 端读模型里必须有两个成分行，实际 % 行', v_composition;
    END IF;

    -- 第一张套餐：两个成分都是 1 天 → 组合 1 天
    IF fn_variant_validity_days(v_combo) <> 1 THEN
        RAISE EXCEPTION '组合的有效期应为 1 天（两个成分都是 1 天），实际 % 天',
          fn_variant_validity_days(v_combo);
    END IF;

    -- 第二张套餐：并集 = 2 天，日历格子的有效期终点 = 格子日期 + 2 天
    IF fn_variant_validity_days(v_combo_mixed) <> 2 THEN
        RAISE EXCEPTION '第二张组合的有效期应为 2 天（成分窗口的并集），实际 % 天',
          fn_variant_validity_days(v_combo_mixed);
    END IF;

    IF (SELECT count(*) FROM c_variant_calendar
         WHERE product_variant_id = v_combo_mixed
           AND valid_to IS DISTINCT FROM date + 2) <> 0 THEN
        RAISE EXCEPTION '第二张组合的日历格子有效期终点必须是格子日期 + 2 天（前端不许自己加一天）';
    END IF;

    -- C 端必须看得见两个成分各自管几天
    IF (SELECT count(*) FROM v_c_variant_composition
         WHERE product_variant_id = v_combo_mixed
           AND ((audience_code = 'adult' AND valid_days = 2 AND quantity = 2)
             OR (audience_code = 'child' AND valid_days = 1 AND quantity = 1))) <> 2 THEN
        RAISE EXCEPTION '第二张组合的成分（2 份两日成人 + 1 份一日儿童）必须出现在 C 端读模型里';
    END IF;
END $$;

COMMIT;

-- 统计
SELECT 'suppliers'        AS entity, count(*) FROM supplier
UNION ALL SELECT 'supplier_products', count(*) FROM supplier_product
UNION ALL SELECT 'products',         count(*) FROM product
UNION ALL SELECT 'mappings',         count(*) FROM product_mapping
UNION ALL SELECT 'product_sessions', count(*) FROM product_session
UNION ALL SELECT 'session_sources',  count(*) FROM product_session_source
UNION ALL SELECT 'supplier_prices',  count(*) FROM supplier_price_calendar
UNION ALL SELECT 'orders',           count(*) FROM sales_order
UNION ALL SELECT 'bookings',         count(*) FROM booking
UNION ALL SELECT 'vouchers',         count(*) FROM voucher
UNION ALL SELECT 'channels',         count(*) FROM channel
UNION ALL SELECT 'listings',         count(*) FROM channel_listing
UNION ALL SELECT 'c_cards',          count(*) FROM c_product_card
UNION ALL SELECT 'c_calendars',      count(*) FROM c_product_calendar
UNION ALL SELECT 'c_coupons',        count(*) FROM coupon
UNION ALL SELECT 'c_carts',          count(*) FROM cart
UNION ALL SELECT 'c_holds',          count(*) FROM inventory_hold
UNION ALL SELECT 'c_requirements',   count(*) FROM checkout_requirement
UNION ALL SELECT 'c_holders',        count(*) FROM order_holder
UNION ALL SELECT 'c_reviews',        count(*) FROM product_review
UNION ALL SELECT 'product_axes',     count(*) FROM product_axis
UNION ALL SELECT 'axis_options',     count(*) FROM product_axis_option
UNION ALL SELECT 'product_variants', count(*) FROM product_variant
UNION ALL SELECT 'variant_options',  count(*) FROM product_variant_option
UNION ALL SELECT 'variant_relations',count(*) FROM product_variant_relation
UNION ALL SELECT 'supplier_variants',count(*) FROM supplier_variant
UNION ALL SELECT 'variant_mappings', count(*) FROM supplier_variant_mapping
UNION ALL SELECT 'c_variant_cal',    count(*) FROM c_variant_calendar
UNION ALL SELECT 'locked_prices',    count(*) FROM price_calendar WHERE price_locked
UNION ALL SELECT 'per_group_items',  count(*) FROM sales_order_item WHERE pricing_basis='per_group';
