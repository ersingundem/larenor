"""Core-owned bounded storage for secret-free F30 weekly summaries."""


DDL = '''CREATE TABLE IF NOT EXISTS media_archive_weekly_trends (
    installation_id TEXT NOT NULL,
    installation_revision INTEGER NOT NULL,
    week_start INTEGER NOT NULL,
    captured_at INTEGER NOT NULL,
    snapshot_revision INTEGER NOT NULL,
    total_bytes INTEGER NOT NULL,
    free_bytes INTEGER NOT NULL,
    reclaimable_bytes INTEGER NOT NULL,
    duplicate_candidates INTEGER NOT NULL,
    low_quality_candidates INTEGER NOT NULL,
    digest TEXT NOT NULL,
    PRIMARY KEY (installation_id, week_start)
)'''


def migrate_media_archive_weekly_trends(connection):
    connection.execute(DDL)
