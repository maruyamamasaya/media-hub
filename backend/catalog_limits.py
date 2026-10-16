"""Catalog storage and authenticated response bounds (bytes)."""
MAX_CATALOG_BYTES = 16 * 1024 * 1024
CATALOG_CHUNK_BYTES = 1024 * 1024
# Public projection can add folder flags; keep a separate bounded assembly budget.
MAX_CATALOG_RESPONSE_BYTES = 20 * 1024 * 1024
MAX_ENCRYPTED_CATALOG_BYTES = MAX_CATALOG_BYTES + 60 + ((MAX_CATALOG_BYTES + 1024 * 1024 - 1) // (1024 * 1024)) * 16
