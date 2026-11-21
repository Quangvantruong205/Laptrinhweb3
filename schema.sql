-- Fashion E-commerce & Flash Sale (THE C.I.U-inspired educational project)
-- Schema version 2.1 - validated on MySQL 8.0.x / InnoDB. Run as a database administrator.
-- Each microservice owns one database. Do not create cross-database foreign keys.
-- Production usage: split this bootstrap script into per-service Flyway migrations.
--
-- Changes vs 2.0 (see README "Changelog"):
--   * Money is whole-dong DECIMAL(14,0); orders/order_items have total-consistency CHECKs.
--   * product_variants: color/size NOT NULL with defaults (NULL broke the unique key);
--     product -> variants is RESTRICT (soft delete); image/variant ownership enforced.
--   * carts: one ACTIVE cart per user (CONVERTED carts no longer block a new cart).
--   * inventory_db: outbox_events + inbox_messages added; one ACTIVE flash allocation per
--     (variant, location); movements log all four buckets; reservations unique per
--     (order, variant); one default online fulfilment location.
--   * orders: request_hash (idempotency payload check), payment_due_at, cancel_reason.
--   * flash_sale_items.allocation_status tracks the Flash Sale -> Inventory handshake.
--
-- All DATETIME values are UTC. Run MySQL with default-time-zone='+00:00' and use
-- connectionTimeZone=UTC in JDBC; CURRENT_TIMESTAMP follows the session time zone.

SET NAMES utf8mb4;
SET time_zone = '+00:00';

CREATE DATABASE IF NOT EXISTS auth_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS product_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS inventory_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS order_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE IF NOT EXISTS flashsale_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- ============================================================
-- AUTH SERVICE: auth_db
-- ============================================================
USE auth_db;

CREATE TABLE IF NOT EXISTS users (
    id CHAR(36) NOT NULL,
    email VARCHAR(190) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(150) NOT NULL,
    phone VARCHAR(30) NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_users_email (email),
    KEY idx_users_status (status),
    CONSTRAINT chk_users_status CHECK (status IN ('ACTIVE', 'LOCKED', 'DISABLED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS roles (
    id CHAR(36) NOT NULL,
    role_code VARCHAR(40) NOT NULL,
    description VARCHAR(150) NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_roles_code (role_code)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS user_roles (
    user_id CHAR(36) NOT NULL,
    role_id CHAR(36) NOT NULL,
    PRIMARY KEY (user_id, role_id),
    CONSTRAINT fk_user_roles_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT fk_user_roles_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Refresh-token rotation with reuse detection: every token belongs to a family.
-- If a revoked token is presented again, revoke the whole family.
CREATE TABLE IF NOT EXISTS refresh_tokens (
    id CHAR(36) NOT NULL,
    user_id CHAR(36) NOT NULL,
    family_id CHAR(36) NOT NULL,
    token_hash VARCHAR(255) NOT NULL,
    replaced_by_id CHAR(36) NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_refresh_token_hash (token_hash),
    KEY idx_refresh_user_expiry (user_id, expires_at),
    KEY idx_refresh_family (family_id),
    CONSTRAINT fk_refresh_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- PRODUCT SERVICE: product_db
-- ============================================================
USE product_db;

CREATE TABLE IF NOT EXISTS categories (
    id CHAR(36) NOT NULL,
    parent_id CHAR(36) NULL,
    name VARCHAR(120) NOT NULL,
    slug VARCHAR(150) NOT NULL,
    description VARCHAR(500) NULL,
    sort_order INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_categories_slug (slug),
    KEY idx_categories_parent_sort (parent_id, sort_order),
    CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id) REFERENCES categories(id),
    CONSTRAINT chk_categories_status CHECK (status IN ('ACTIVE', 'INACTIVE'))
) ENGINE=InnoDB;

-- Search note: the default InnoDB FULLTEXT parser ignores tokens shorter than
-- innodb_ft_min_token_size (3), so short Vietnamese words such as "ao" would never match.
-- The MVP therefore searches with a prefix/contains LIKE on name (idx_products_name).
CREATE TABLE IF NOT EXISTS products (
    id CHAR(36) NOT NULL,
    category_id CHAR(36) NOT NULL,
    name VARCHAR(220) NOT NULL,
    slug VARCHAR(240) NOT NULL,
    description TEXT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_products_slug (slug),
    KEY idx_products_category_status (category_id, status),
    KEY idx_products_status_created (status, created_at),
    KEY idx_products_name (name),
    CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories(id),
    CONSTRAINT chk_products_status CHECK (status IN ('DRAFT', 'ACTIVE', 'INACTIVE', 'ARCHIVED'))
) ENGINE=InnoDB;

-- color_name / size_label are NOT NULL on purpose: a UNIQUE key treats NULLs as distinct,
-- which would allow duplicate free-size variants. Use 'DEFAULT' / 'ONE_SIZE' when n/a.
-- Business rows are never hard-deleted: deactivate via status. Deleting a product that still
-- has variants is blocked (RESTRICT) because inventory/orders reference variant ids externally.
CREATE TABLE IF NOT EXISTS product_variants (
    id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL,
    sku VARCHAR(80) NOT NULL,
    color_name VARCHAR(80) NOT NULL DEFAULT 'DEFAULT',
    color_hex CHAR(7) NULL,
    size_label VARCHAR(30) NOT NULL DEFAULT 'ONE_SIZE',
    price DECIMAL(14,0) NOT NULL,
    compare_at_price DECIMAL(14,0) NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    sort_order INT NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_variants_sku (sku),
    UNIQUE KEY uk_variants_product_color_size (product_id, color_name, size_label),
    UNIQUE KEY uk_variants_id_product (id, product_id),
    KEY idx_variants_product_status (product_id, status, sort_order),
    CONSTRAINT fk_variants_product FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT,
    CONSTRAINT chk_variants_price CHECK (price >= 0 AND (compare_at_price IS NULL OR compare_at_price >= price)),
    CONSTRAINT chk_variants_status CHECK (status IN ('ACTIVE', 'INACTIVE', 'OUT_OF_CATALOG'))
) ENGINE=InnoDB;

-- variant_id NULL = product-level image. When set, the composite FK guarantees the
-- variant belongs to the same product as the image.
CREATE TABLE IF NOT EXISTS product_images (
    id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL,
    variant_id CHAR(36) NULL COMMENT 'NULL = product-level image; set = variant/color-specific image',
    image_url VARCHAR(1000) NOT NULL,
    alt_text VARCHAR(255) NULL,
    sort_order INT NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_product_images_product_sort (product_id, sort_order),
    KEY idx_product_images_variant_sort (variant_id, product_id, sort_order),
    CONSTRAINT fk_product_images_product FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE,
    CONSTRAINT fk_product_images_variant FOREIGN KEY (variant_id, product_id)
        REFERENCES product_variants(id, product_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS product_attributes (
    id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL,
    attribute_name VARCHAR(80) NOT NULL COMMENT 'e.g. material, fit, composition, design_detail',
    attribute_value VARCHAR(500) NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY uk_product_attribute_name (product_id, attribute_name),
    CONSTRAINT fk_product_attributes_product FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- Merchandising groups. "Featured" is a collection (no is_featured flag on products).
-- ON_SALE is derived from active Flash Sale campaigns, never stored here.
CREATE TABLE IF NOT EXISTS collections (
    id CHAR(36) NOT NULL,
    name VARCHAR(120) NOT NULL,
    slug VARCHAR(150) NOT NULL,
    description VARCHAR(500) NULL,
    collection_type VARCHAR(30) NOT NULL DEFAULT 'MANUAL',
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    sort_order INT NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_collections_slug (slug),
    CONSTRAINT chk_collections_type CHECK (collection_type IN ('MANUAL', 'NEW_ARRIVALS', 'BEST_SELLER', 'FEATURED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS collection_products (
    collection_id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    PRIMARY KEY (collection_id, product_id),
    KEY idx_collection_products_sort (collection_id, sort_order),
    CONSTRAINT fk_collection_products_collection FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE,
    CONSTRAINT fk_collection_products_product FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- INVENTORY SERVICE: inventory_db
-- ============================================================
USE inventory_db;

-- Exactly one location may be flagged is_online_default (the online fulfilment location
-- used by checkout). online_default_key is NULL for all other rows, so the UNIQUE key
-- allows many NULLs but only a single 1.
CREATE TABLE IF NOT EXISTS inventory_locations (
    id CHAR(36) NOT NULL,
    code VARCHAR(40) NOT NULL,
    name VARCHAR(150) NOT NULL,
    location_type VARCHAR(30) NOT NULL,
    is_online_default TINYINT(1) NOT NULL DEFAULT 0,
    online_default_key TINYINT GENERATED ALWAYS AS (CASE WHEN is_online_default = 1 THEN 1 ELSE NULL END) VIRTUAL,
    address_line VARCHAR(255) NULL,
    ward VARCHAR(100) NULL,
    district VARCHAR(100) NULL,
    province VARCHAR(100) NULL,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_inventory_locations_code (code),
    UNIQUE KEY uk_inventory_locations_online_default (online_default_key),
    CONSTRAINT chk_inventory_location_type CHECK (location_type IN ('ONLINE_WAREHOUSE', 'STORE')),
    CONSTRAINT chk_inventory_location_default CHECK (is_online_default = 0 OR location_type = 'ONLINE_WAREHOUSE')
) ENGINE=InnoDB;

-- Stock rows are created by the Inventory admin API after validating the variant with
-- Product Service. version is for diagnostics/optimistic admin edits; correctness on the
-- hot path comes from row locks / conditional updates, not from version.
CREATE TABLE IF NOT EXISTS inventory_stock (
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant ID',
    location_id CHAR(36) NOT NULL,
    on_hand_qty INT NOT NULL DEFAULT 0,
    regular_available_qty INT NOT NULL DEFAULT 0,
    flash_available_qty INT NOT NULL DEFAULT 0,
    reserved_qty INT NOT NULL DEFAULT 0,
    version BIGINT NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (variant_id, location_id),
    KEY idx_inventory_stock_location (location_id),
    CONSTRAINT fk_inventory_stock_location FOREIGN KEY (location_id) REFERENCES inventory_locations(id),
    CONSTRAINT chk_inventory_stock_nonnegative CHECK (
        on_hand_qty >= 0 AND regular_available_qty >= 0 AND
        flash_available_qty >= 0 AND reserved_qty >= 0
    ),
    CONSTRAINT chk_inventory_stock_bucket_equation CHECK (
        on_hand_qty = regular_available_qty + flash_available_qty + reserved_qty
    )
) ENGINE=InnoDB;

-- One allocation = quantity of one variant at one location earmarked for one campaign item.
-- Quantity semantics:
--   available_qty  can still be reserved
--   reserved_qty   held by HELD reservations
--   sold_qty       confirmed sales
--   released_qty   returned to regular stock when the campaign/allocation was CLOSED
-- A reservation release moves reserved_qty back to available_qty (NOT to released_qty).
-- Invariant (reconciliation job): stock.flash_available_qty = available_qty of the single
-- ACTIVE allocation for that (variant, location), or 0 when none is ACTIVE.
CREATE TABLE IF NOT EXISTS flash_sale_allocations (
    id CHAR(36) NOT NULL,
    campaign_item_id CHAR(36) NOT NULL COMMENT 'External Flash Sale Service item ID',
    campaign_id CHAR(36) NOT NULL COMMENT 'External Flash Sale Service campaign ID',
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant ID',
    location_id CHAR(36) NOT NULL,
    allocated_qty INT NOT NULL,
    available_qty INT NOT NULL,
    reserved_qty INT NOT NULL DEFAULT 0,
    sold_qty INT NOT NULL DEFAULT 0,
    released_qty INT NOT NULL DEFAULT 0,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    active_slot VARCHAR(73) GENERATED ALWAYS AS (
        CASE WHEN status = 'ACTIVE' THEN CONCAT(variant_id, ':', location_id) ELSE NULL END
    ) VIRTUAL,
    closed_at DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_flash_allocation_item_location (campaign_item_id, location_id),
    UNIQUE KEY uk_flash_allocation_id_variant_location (id, variant_id, location_id),
    UNIQUE KEY uk_flash_allocation_active_slot (active_slot),
    KEY idx_flash_allocation_campaign (campaign_id),
    KEY idx_flash_allocation_variant_location (variant_id, location_id),
    CONSTRAINT fk_flash_allocation_location FOREIGN KEY (location_id) REFERENCES inventory_locations(id),
    CONSTRAINT fk_flash_allocation_stock FOREIGN KEY (variant_id, location_id)
        REFERENCES inventory_stock(variant_id, location_id),
    CONSTRAINT chk_flash_allocation_quantities CHECK (
        allocated_qty > 0 AND available_qty >= 0 AND reserved_qty >= 0 AND
        sold_qty >= 0 AND released_qty >= 0 AND
        allocated_qty = available_qty + reserved_qty + sold_qty + released_qty
    ),
    CONSTRAINT chk_flash_allocation_status CHECK (status IN ('ACTIVE', 'CLOSED')),
    CONSTRAINT chk_flash_allocation_closed_empty CHECK (status = 'ACTIVE' OR available_qty = 0)
) ENGINE=InnoDB;

-- Rows are created lazily: INSERT ... ON DUPLICATE KEY UPDATE (no-op) then SELECT ... FOR UPDATE.
CREATE TABLE IF NOT EXISTS flash_sale_user_limits (
    campaign_item_id CHAR(36) NOT NULL COMMENT 'External Flash Sale Service item ID',
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service user ID',
    max_qty_per_user INT NOT NULL,
    reserved_qty INT NOT NULL DEFAULT 0,
    purchased_qty INT NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (campaign_item_id, user_id),
    CONSTRAINT chk_flash_user_limit_qty CHECK (
        max_qty_per_user > 0 AND reserved_qty >= 0 AND purchased_qty >= 0 AND
        reserved_qty + purchased_qty <= max_qty_per_user
    )
) ENGINE=InnoDB;

-- One reservation per (order, variant). order_id is generated by Order Service before the
-- order row is inserted (status CREATING), so (order_id, variant_id) is the natural
-- idempotency key: repeating the request returns the existing reservation.
-- expires_at here is the AUTHORITATIVE hold expiry; Order Service learns about it through
-- the inventory.reservation-expired event.
CREATE TABLE IF NOT EXISTS reservations (
    id CHAR(36) NOT NULL,
    order_id CHAR(36) NOT NULL COMMENT 'External Order Service ID (pre-generated)',
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service ID',
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant ID',
    location_id CHAR(36) NOT NULL,
    allocation_id CHAR(36) NULL,
    reservation_type VARCHAR(20) NOT NULL,
    quantity INT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'HELD',
    expires_at DATETIME(6) NOT NULL,
    confirmed_at DATETIME(6) NULL,
    released_at DATETIME(6) NULL,
    release_reason VARCHAR(40) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_reservation_order_variant (order_id, variant_id),
    KEY idx_reservations_expiry (status, expires_at),
    KEY idx_reservations_allocation (allocation_id),
    KEY idx_reservations_user (user_id, created_at),
    CONSTRAINT fk_reservation_stock FOREIGN KEY (variant_id, location_id)
        REFERENCES inventory_stock(variant_id, location_id),
    CONSTRAINT fk_reservation_location FOREIGN KEY (location_id) REFERENCES inventory_locations(id),
    CONSTRAINT fk_reservation_allocation_variant_location FOREIGN KEY (allocation_id, variant_id, location_id)
        REFERENCES flash_sale_allocations(id, variant_id, location_id),
    CONSTRAINT chk_reservation_quantity CHECK (quantity > 0),
    CONSTRAINT chk_reservation_type CHECK (reservation_type IN ('NORMAL', 'FLASH_SALE')),
    CONSTRAINT chk_reservation_status CHECK (status IN ('HELD', 'CONFIRMED', 'RELEASED', 'EXPIRED')),
    CONSTRAINT chk_reservation_allocation_type CHECK (
        (reservation_type = 'NORMAL' AND allocation_id IS NULL) OR
        (reservation_type = 'FLASH_SALE' AND allocation_id IS NOT NULL)
    )
) ENGINE=InnoDB;

-- Append-only audit log. Every movement records the signed delta and the resulting balance
-- of all four buckets, so any stock row can be rebuilt/verified from the log.
-- reference_id = reservation id for reservation movements, allocation id for allocate/close.
-- UNIQUE (reference_type, reference_id, movement_type) makes each movement idempotent.
CREATE TABLE IF NOT EXISTS inventory_movements (
    id CHAR(36) NOT NULL,
    variant_id CHAR(36) NOT NULL,
    location_id CHAR(36) NOT NULL,
    reference_type VARCHAR(40) NOT NULL,
    reference_id CHAR(36) NULL,
    movement_type VARCHAR(40) NOT NULL,
    quantity INT NOT NULL,
    delta_on_hand INT NOT NULL,
    delta_regular INT NOT NULL,
    delta_flash INT NOT NULL,
    delta_reserved INT NOT NULL,
    after_on_hand INT NOT NULL,
    after_regular INT NOT NULL,
    after_flash INT NOT NULL,
    after_reserved INT NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_inventory_movement_ref (reference_type, reference_id, movement_type),
    KEY idx_inventory_movements_variant_date (variant_id, location_id, created_at),
    CONSTRAINT fk_inventory_movement_stock FOREIGN KEY (variant_id, location_id)
        REFERENCES inventory_stock(variant_id, location_id),
    CONSTRAINT chk_inventory_movement_type CHECK (movement_type IN (
        'INITIAL_STOCK', 'STOCK_ADJUSTMENT', 'ALLOCATE_FLASH', 'CLOSE_CAMPAIGN',
        'RESERVE_NORMAL', 'RESERVE_FLASH', 'CONFIRM', 'RELEASE', 'EXPIRE')),
    CONSTRAINT chk_inventory_movement_delta CHECK (
        delta_on_hand = delta_regular + delta_flash + delta_reserved),
    CONSTRAINT chk_inventory_movement_after CHECK (
        after_on_hand = after_regular + after_flash + after_reserved AND
        after_on_hand >= 0 AND after_regular >= 0 AND after_flash >= 0 AND after_reserved >= 0)
) ENGINE=InnoDB;

-- Inventory publishes inventory.reservation-expired (outbox) and consumes order.confirmed,
-- order.cancelled, order.expired (inbox). Outbox publishers with several instances must
-- claim rows with SELECT ... FOR UPDATE SKIP LOCKED.
CREATE TABLE IF NOT EXISTS outbox_events (
    id CHAR(36) NOT NULL,
    aggregate_type VARCHAR(80) NOT NULL,
    aggregate_id CHAR(36) NOT NULL,
    event_type VARCHAR(120) NOT NULL,
    event_version INT NOT NULL DEFAULT 1,
    routing_key VARCHAR(150) NOT NULL,
    correlation_id VARCHAR(64) NULL,
    payload JSON NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    attempts INT NOT NULL DEFAULT 0,
    next_attempt_at DATETIME(6) NULL,
    published_at DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_outbox_pending (status, next_attempt_at, created_at),
    CONSTRAINT chk_outbox_status CHECK (status IN ('PENDING', 'PUBLISHED', 'FAILED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS inbox_messages (
    consumer_name VARCHAR(100) NOT NULL,
    message_id CHAR(36) NOT NULL,
    processed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (consumer_name, message_id),
    KEY idx_inbox_processed (processed_at)
) ENGINE=InnoDB;

-- ============================================================
-- ORDER SERVICE: order_db
-- ============================================================
USE order_db;

-- Exactly one ACTIVE cart per user. active_user_id is NULL for CONVERTED carts, so a user
-- keeps a history of converted carts and can still create a new active one.
CREATE TABLE IF NOT EXISTS carts (
    id CHAR(36) NOT NULL,
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service user ID',
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    active_user_id CHAR(36) GENERATED ALWAYS AS (CASE WHEN status = 'ACTIVE' THEN user_id ELSE NULL END) VIRTUAL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_carts_active_user (active_user_id),
    KEY idx_carts_user (user_id),
    CONSTRAINT chk_carts_status CHECK (status IN ('ACTIVE', 'CONVERTED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS cart_items (
    id CHAR(36) NOT NULL,
    cart_id CHAR(36) NOT NULL,
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant ID',
    quantity INT NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_cart_variant (cart_id, variant_id),
    CONSTRAINT fk_cart_items_cart FOREIGN KEY (cart_id) REFERENCES carts(id) ON DELETE CASCADE,
    CONSTRAINT chk_cart_items_quantity CHECK (quantity > 0)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS wishlists (
    id CHAR(36) NOT NULL,
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service user ID',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_wishlists_user (user_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS wishlist_items (
    id CHAR(36) NOT NULL,
    wishlist_id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL COMMENT 'External Product Service product ID',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_wishlist_product (wishlist_id, product_id),
    CONSTRAINT fk_wishlist_items_wishlist FOREIGN KEY (wishlist_id) REFERENCES wishlists(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS customer_addresses (
    id CHAR(36) NOT NULL,
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service user ID',
    recipient_name VARCHAR(150) NOT NULL,
    phone VARCHAR(30) NOT NULL,
    province VARCHAR(120) NOT NULL,
    district VARCHAR(120) NULL,
    ward VARCHAR(120) NULL,
    address_line VARCHAR(255) NOT NULL,
    delivery_note VARCHAR(500) NULL,
    is_default TINYINT(1) NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_customer_addresses_user (user_id, is_default)
) ENGINE=InnoDB;

-- id is generated by the application BEFORE any call to Inventory and is the reservation
-- order_id. Money is whole VND (DECIMAL(14,0)).
-- Idempotency: (user_id, idempotency_key) is unique and request_hash (SHA-256 hex of the
-- canonical request body) must match on replay; same key + different hash => 422.
-- payment_due_at is informational for the UI/payment flow; the authoritative hold expiry
-- lives in inventory_db.reservations.expires_at.
CREATE TABLE IF NOT EXISTS orders (
    id CHAR(36) NOT NULL,
    order_number VARCHAR(40) NOT NULL,
    user_id CHAR(36) NOT NULL COMMENT 'External Auth Service user ID',
    order_type VARCHAR(20) NOT NULL DEFAULT 'STANDARD',
    status VARCHAR(30) NOT NULL DEFAULT 'CREATING',
    payment_status VARCHAR(20) NOT NULL DEFAULT 'UNPAID',
    payment_method VARCHAR(30) NOT NULL,
    shipping_method VARCHAR(30) NOT NULL DEFAULT 'STANDARD',
    currency CHAR(3) NOT NULL DEFAULT 'VND',
    subtotal DECIMAL(14,0) NOT NULL,
    discount_total DECIMAL(14,0) NOT NULL DEFAULT 0,
    shipping_fee DECIMAL(14,0) NOT NULL DEFAULT 0,
    grand_total DECIMAL(14,0) NOT NULL,
    recipient_name VARCHAR(150) NOT NULL,
    recipient_phone VARCHAR(30) NOT NULL,
    recipient_province VARCHAR(120) NOT NULL,
    recipient_district VARCHAR(120) NULL,
    recipient_ward VARCHAR(120) NULL,
    recipient_address_line VARCHAR(255) NOT NULL,
    delivery_note VARCHAR(500) NULL,
    idempotency_key VARCHAR(100) NOT NULL,
    request_hash CHAR(64) NOT NULL,
    payment_due_at DATETIME(6) NULL,
    confirmed_at DATETIME(6) NULL,
    cancel_reason VARCHAR(60) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_orders_number (order_number),
    UNIQUE KEY uk_orders_user_idempotency (user_id, idempotency_key),
    KEY idx_orders_user_created (user_id, created_at),
    KEY idx_orders_status_created (status, created_at),
    CONSTRAINT chk_orders_type CHECK (order_type IN ('STANDARD', 'FLASH_SALE')),
    CONSTRAINT chk_orders_status CHECK (status IN ('CREATING', 'PENDING_PAYMENT', 'PENDING_COD', 'PAID', 'PROCESSING', 'SHIPPED', 'COMPLETED', 'CANCELLED', 'EXPIRED', 'FAILED')),
    CONSTRAINT chk_orders_payment_status CHECK (payment_status IN ('UNPAID', 'PENDING', 'PAID', 'FAILED', 'REFUNDED')),
    CONSTRAINT chk_orders_payment_method CHECK (payment_method IN ('COD', 'BANK_TRANSFER', 'MOCK_ONLINE')),
    CONSTRAINT chk_orders_shipping_method CHECK (shipping_method IN ('STANDARD', 'EXPRESS')),
    CONSTRAINT chk_orders_currency CHECK (currency = 'VND'),
    CONSTRAINT chk_orders_amounts CHECK (subtotal >= 0 AND discount_total >= 0 AND shipping_fee >= 0 AND grand_total >= 0),
    CONSTRAINT chk_orders_grand_total CHECK (grand_total = subtotal - discount_total + shipping_fee)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS order_items (
    id CHAR(36) NOT NULL,
    order_id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL COMMENT 'External Product Service ID',
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant ID',
    product_name_snapshot VARCHAR(220) NOT NULL,
    sku_snapshot VARCHAR(80) NOT NULL,
    color_snapshot VARCHAR(80) NULL,
    size_snapshot VARCHAR(30) NULL,
    image_url_snapshot VARCHAR(1000) NULL,
    unit_price DECIMAL(14,0) NOT NULL,
    quantity INT NOT NULL,
    discount_amount DECIMAL(14,0) NOT NULL DEFAULT 0,
    line_total DECIMAL(14,0) NOT NULL,
    campaign_id CHAR(36) NULL COMMENT 'External Flash Sale Service ID',
    campaign_item_id CHAR(36) NULL COMMENT 'External Flash Sale Service ID',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_items_order_variant (order_id, variant_id),
    CONSTRAINT fk_order_items_order FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
    CONSTRAINT chk_order_items_values CHECK (unit_price >= 0 AND quantity > 0 AND discount_amount >= 0 AND line_total >= 0),
    CONSTRAINT chk_order_items_line_total CHECK (line_total = unit_price * quantity - discount_amount)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS payment_attempts (
    id CHAR(36) NOT NULL,
    order_id CHAR(36) NOT NULL,
    method VARCHAR(30) NOT NULL,
    provider VARCHAR(30) NOT NULL DEFAULT 'MOCK',
    payment_reference VARCHAR(100) NOT NULL,
    amount DECIMAL(14,0) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'INITIATED',
    idempotency_key VARCHAR(100) NOT NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_payment_reference (payment_reference),
    UNIQUE KEY uk_payment_order_idempotency (order_id, idempotency_key),
    KEY idx_payment_attempts_order (order_id),
    CONSTRAINT fk_payment_attempts_order FOREIGN KEY (order_id) REFERENCES orders(id),
    CONSTRAINT chk_payment_attempt_method CHECK (method IN ('BANK_TRANSFER', 'MOCK_ONLINE')),
    CONSTRAINT chk_payment_attempt_amount CHECK (amount >= 0),
    CONSTRAINT chk_payment_attempt_status CHECK (status IN ('INITIATED', 'SUCCEEDED', 'FAILED', 'REFUNDED'))
) ENGINE=InnoDB;

-- The saga row is inserted in the SAME transaction as the order row (status CREATING),
-- before any call to Product/Inventory. A recovery job picks up RUNNING/COMPENSATING sagas
-- whose next_retry_at has passed.
CREATE TABLE IF NOT EXISTS checkout_sagas (
    id CHAR(36) NOT NULL,
    order_id CHAR(36) NOT NULL,
    saga_type VARCHAR(30) NOT NULL,
    current_step VARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'RUNNING',
    retry_count INT NOT NULL DEFAULT 0,
    next_retry_at DATETIME(6) NULL,
    last_error VARCHAR(1000) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_checkout_saga_order (order_id),
    KEY idx_checkout_saga_recovery (status, next_retry_at),
    CONSTRAINT fk_checkout_saga_order FOREIGN KEY (order_id) REFERENCES orders(id),
    CONSTRAINT chk_checkout_saga_status CHECK (status IN ('RUNNING', 'COMPLETED', 'COMPENSATING', 'FAILED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS outbox_events (
    id CHAR(36) NOT NULL,
    aggregate_type VARCHAR(80) NOT NULL,
    aggregate_id CHAR(36) NOT NULL,
    event_type VARCHAR(120) NOT NULL,
    event_version INT NOT NULL DEFAULT 1,
    routing_key VARCHAR(150) NOT NULL,
    correlation_id VARCHAR(64) NULL,
    payload JSON NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    attempts INT NOT NULL DEFAULT 0,
    next_attempt_at DATETIME(6) NULL,
    published_at DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    KEY idx_outbox_pending (status, next_attempt_at, created_at),
    CONSTRAINT chk_outbox_status CHECK (status IN ('PENDING', 'PUBLISHED', 'FAILED'))
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS inbox_messages (
    consumer_name VARCHAR(100) NOT NULL,
    message_id CHAR(36) NOT NULL,
    processed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (consumer_name, message_id),
    KEY idx_inbox_processed (processed_at)
) ENGINE=InnoDB;

-- ============================================================
-- FLASH SALE SERVICE: flashsale_db
-- ============================================================
USE flashsale_db;

CREATE TABLE IF NOT EXISTS flash_sale_campaigns (
    id CHAR(36) NOT NULL,
    name VARCHAR(180) NOT NULL,
    code VARCHAR(80) NOT NULL,
    description VARCHAR(1000) NULL,
    starts_at DATETIME(6) NOT NULL,
    ends_at DATETIME(6) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_flash_campaign_code (code),
    KEY idx_flash_campaign_status_time (status, starts_at, ends_at),
    CONSTRAINT chk_flash_campaign_time CHECK (ends_at > starts_at),
    CONSTRAINT chk_flash_campaign_status CHECK (status IN ('DRAFT', 'SCHEDULED', 'ACTIVE', 'ENDED', 'CANCELLED'))
) ENGINE=InnoDB;

-- allocation_status tracks the handshake with Inventory Service:
--   PENDING   -> publish requested, allocation not confirmed yet
--   ALLOCATED -> Inventory confirmed the allocation (idempotent by item id)
--   FAILED    -> allocation rejected (e.g. insufficient regular stock); see allocation_error
--   CLOSED    -> unreserved quantity returned to regular stock
-- A campaign may only become SCHEDULED when all its items are ALLOCATED.
CREATE TABLE IF NOT EXISTS flash_sale_items (
    id CHAR(36) NOT NULL,
    campaign_id CHAR(36) NOT NULL,
    product_id CHAR(36) NOT NULL COMMENT 'External Product Service product ID',
    variant_id CHAR(36) NOT NULL COMMENT 'External Product Service variant/SKU ID',
    sale_price DECIMAL(14,0) NOT NULL,
    planned_qty INT NOT NULL,
    max_qty_per_user INT NOT NULL DEFAULT 1,
    status VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    allocation_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    allocation_error VARCHAR(500) NULL,
    created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
    PRIMARY KEY (id),
    UNIQUE KEY uk_flash_campaign_variant (campaign_id, variant_id),
    KEY idx_flash_items_product (product_id),
    KEY idx_flash_items_allocation (allocation_status),
    CONSTRAINT fk_flash_items_campaign FOREIGN KEY (campaign_id) REFERENCES flash_sale_campaigns(id) ON DELETE CASCADE,
    CONSTRAINT chk_flash_item_values CHECK (sale_price >= 0 AND planned_qty > 0 AND max_qty_per_user > 0 AND max_qty_per_user <= planned_qty),
    CONSTRAINT chk_flash_item_status CHECK (status IN ('ACTIVE', 'INACTIVE')),
    CONSTRAINT chk_flash_item_alloc_status CHECK (allocation_status IN ('PENDING', 'ALLOCATED', 'FAILED', 'CLOSED'))
) ENGINE=InnoDB;

-- ============================================================
-- Suggested seed records (execute separately after creating UUIDs):
-- product_db.categories: Ao, Ao-khoac, Bo, Chan-vay, Dam, Phu-kien, Quan, Yem
-- inventory_db.inventory_locations: ONLINE_MAIN (is_online_default=1), STORE_01, STORE_02 (demo only)
-- auth_db.roles: ROLE_USER, ROLE_ADMIN
-- ============================================================
