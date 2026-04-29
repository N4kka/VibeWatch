-- VibeWatch default-list deduplication runbook.
-- Run section 1 first in the Supabase SQL editor and inspect the result.
-- Run section 2 only after the dry-run output looks correct.

-- ---------------------------------------------------------------------------
-- 1. Dry-run: duplicate default lists that would be merged.
-- ---------------------------------------------------------------------------
WITH default_lists AS (
    SELECT
        l.id,
        l.user_id,
        l.type,
        l.name,
        l.created_at,
        l.updated_at,
        COUNT(li.id) FILTER (WHERE li.deleted_at IS NULL) AS item_count
    FROM lists l
    LEFT JOIN list_items li
        ON li.list_id = l.id
       AND li.deleted_at IS NULL
    WHERE l.deleted_at IS NULL
      AND l.type IN ('watchlist', 'seen', 'liked', 'disliked')
    GROUP BY l.id, l.user_id, l.type, l.name, l.created_at, l.updated_at
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, type
            ORDER BY item_count DESC, COALESCE(updated_at, created_at) DESC, created_at DESC, id
        ) AS rn,
        COUNT(*) OVER (PARTITION BY user_id, type) AS duplicate_count
    FROM default_lists
)
SELECT
    user_id,
    type,
    id AS list_id,
    name,
    item_count,
    rn AS merge_rank,
    duplicate_count,
    created_at,
    updated_at
FROM ranked
WHERE duplicate_count > 1
ORDER BY user_id, type, rn;

-- ---------------------------------------------------------------------------
-- 1b. Dry-run: item moves and duplicate rows per duplicate list.
-- ---------------------------------------------------------------------------
WITH default_lists AS (
    SELECT
        l.id,
        l.user_id,
        l.type,
        l.name,
        l.created_at,
        l.updated_at,
        COUNT(li.id) FILTER (WHERE li.deleted_at IS NULL) AS item_count
    FROM lists l
    LEFT JOIN list_items li
        ON li.list_id = l.id
       AND li.deleted_at IS NULL
    WHERE l.deleted_at IS NULL
      AND l.type IN ('watchlist', 'seen', 'liked', 'disliked')
    GROUP BY l.id, l.user_id, l.type, l.name, l.created_at, l.updated_at
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY user_id, type
            ORDER BY item_count DESC, COALESCE(updated_at, created_at) DESC, created_at DESC, id
        ) AS rn
    FROM default_lists
),
merge_map AS (
    SELECT
        d.user_id,
        d.type,
        d.id AS duplicate_list_id,
        c.id AS canonical_list_id
    FROM ranked d
    JOIN ranked c
      ON c.user_id = d.user_id
     AND c.type = d.type
     AND c.rn = 1
    WHERE d.rn > 1
)
SELECT
    m.user_id,
    m.type,
    m.duplicate_list_id,
    m.canonical_list_id,
    COUNT(li.id) FILTER (
        WHERE NOT EXISTS (
            SELECT 1
            FROM list_items existing
            WHERE existing.list_id = m.canonical_list_id
              AND existing.media_id = li.media_id
              AND existing.media_type = li.media_type
              AND existing.deleted_at IS NULL
        )
    ) AS unique_items_to_move,
    COUNT(li.id) FILTER (
        WHERE EXISTS (
            SELECT 1
            FROM list_items existing
            WHERE existing.list_id = m.canonical_list_id
              AND existing.media_id = li.media_id
              AND existing.media_type = li.media_type
              AND existing.deleted_at IS NULL
        )
    ) AS duplicate_items_to_soft_delete,
    COUNT(li.id) AS active_items_in_duplicate_list
FROM merge_map m
LEFT JOIN list_items li
  ON li.list_id = m.duplicate_list_id
 AND li.deleted_at IS NULL
GROUP BY m.user_id, m.type, m.duplicate_list_id, m.canonical_list_id
ORDER BY m.user_id, m.type, active_items_in_duplicate_list DESC;

-- ---------------------------------------------------------------------------
-- 2. Execute: merge duplicate default lists into the canonical list.
-- ---------------------------------------------------------------------------
BEGIN;

CREATE TEMP TABLE default_list_rank AS
WITH default_lists AS (
    SELECT
        l.id,
        l.user_id,
        l.type,
        l.name,
        l.created_at,
        l.updated_at,
        COUNT(li.id) FILTER (WHERE li.deleted_at IS NULL) AS item_count
    FROM lists l
    LEFT JOIN list_items li
        ON li.list_id = l.id
       AND li.deleted_at IS NULL
    WHERE l.deleted_at IS NULL
      AND l.type IN ('watchlist', 'seen', 'liked', 'disliked')
    GROUP BY l.id, l.user_id, l.type, l.name, l.created_at, l.updated_at
)
SELECT
    *,
    ROW_NUMBER() OVER (
        PARTITION BY user_id, type
        ORDER BY item_count DESC, COALESCE(updated_at, created_at) DESC, created_at DESC, id
    ) AS rn,
    COUNT(*) OVER (PARTITION BY user_id, type) AS duplicate_count
FROM default_lists;

CREATE TEMP TABLE default_list_merge_map AS
SELECT
    d.user_id,
    d.type,
    d.id AS duplicate_list_id,
    c.id AS canonical_list_id
FROM default_list_rank d
JOIN default_list_rank c
  ON c.user_id = d.user_id
 AND c.type = d.type
 AND c.rn = 1
WHERE d.rn > 1;

CREATE TEMP TABLE default_list_item_rank AS
SELECT
    li.id AS item_id,
    li.list_id,
    li.user_id,
    m.type,
    m.canonical_list_id,
    li.media_id,
    li.media_type,
    ROW_NUMBER() OVER (
        PARTITION BY li.user_id, m.type, li.media_id, li.media_type
        ORDER BY
            CASE WHEN li.list_id = m.canonical_list_id THEN 0 ELSE 1 END,
            li.added_at DESC NULLS LAST,
            li.updated_at DESC NULLS LAST,
            li.id
    ) AS item_rank
FROM list_items li
JOIN (
    SELECT user_id, type, canonical_list_id, canonical_list_id AS list_id
    FROM default_list_merge_map
    UNION ALL
    SELECT user_id, type, canonical_list_id, duplicate_list_id AS list_id
    FROM default_list_merge_map
) m
  ON m.list_id = li.list_id
WHERE li.deleted_at IS NULL;

-- Soft-delete duplicate media rows before moving rows into the canonical list.
UPDATE list_items li
SET deleted_at = NOW(),
    updated_at = NOW()
FROM default_list_item_rank r
WHERE li.id = r.item_id
  AND r.item_rank > 1
  AND li.deleted_at IS NULL;

-- Move the remaining unique rows from duplicate lists into the canonical list.
UPDATE list_items li
SET list_id = r.canonical_list_id,
    updated_at = NOW()
FROM default_list_item_rank r
WHERE li.id = r.item_id
  AND r.item_rank = 1
  AND li.list_id <> r.canonical_list_id
  AND li.deleted_at IS NULL;

-- Soft-delete the duplicate default list rows.
UPDATE lists l
SET deleted_at = NOW(),
    updated_at = NOW()
FROM default_list_merge_map m
WHERE l.id = m.duplicate_list_id
  AND l.deleted_at IS NULL;

-- Prevent the same corruption from reappearing server-side.
CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_one_active_default_per_user_type
ON lists (user_id, type)
WHERE deleted_at IS NULL
  AND type IN ('watchlist', 'seen', 'liked', 'disliked');

COMMIT;

-- ---------------------------------------------------------------------------
-- 3. Post-check: should return zero rows.
-- ---------------------------------------------------------------------------
SELECT user_id, type, COUNT(*) AS active_default_list_count
FROM lists
WHERE deleted_at IS NULL
  AND type IN ('watchlist', 'seen', 'liked', 'disliked')
GROUP BY user_id, type
HAVING COUNT(*) > 1
ORDER BY active_default_list_count DESC, user_id, type;
