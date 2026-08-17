# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-08-17

### Added

- `Dowser.Elasticsearch.Repository` now raises an `ArgumentError` at compile
  time if two selected functions would generate the same name, naming the
  clash instead of silently producing broken duplicate definitions.

### Changed

- `Dowser.Elasticsearch.Repository` renames the generated `Document`
  functions that would otherwise share a base name with a same-named
  function from another selected module: `create` → `create_doc`, `delete` →
  `delete_doc`, `exists`/`exists?` → `doc_exists`/`doc_exists?`, `get` →
  `get_doc`, `index` → `index_doc`, `update` → `update_doc`. Repositories
  built with `use Dowser.Elasticsearch.Repository` must switch to the new
  names; `Dowser.Elasticsearch.Document`'s own functions are unaffected.
- `Dowser.Elasticsearch.TypeCodec` (the `:codec_adapter` implementation) and
  `Dowser.Elasticsearch.Codec` (the field-level dispatcher it delegated to)
  are merged into a single `Dowser.Elasticsearch.Codec`, which now
  implements both. Set `codec_adapter: Dowser.Elasticsearch.Codec` instead
  of `Dowser.Elasticsearch.TypeCodec`; custom field casts still inherit from
  `Dowser.Elasticsearch.Codec` the same way.
- `Dowser.Elasticsearch` (the empty top-level module), `Dowser.Elasticsearch.Helpers`,
  and `Dowser.Elasticsearch.Mappable` no longer generate documentation pages
  (`@moduledoc false`) — none of them are meant to be used directly.
- Bumped the `dowser_client` requirement to `~> 0.1.1` and switched to its
  `Dowser.Client.Codec.Builder` (the `Dowser.Client.CodecBuilder` name is
  deprecated upstream, though still functional).

## [0.1.0] - 2026-08-17

Initial release.

### Added

- `Dowser.Elasticsearch.Search` — search-tagged endpoints: `search`,
  `msearch`, `count`, `explain`, `field_caps`, `search_shards`,
  `terms_enum`, `search_mvt`, `search_template`, `msearch_template`,
  `render_search_template`, `rank_eval`, async search
  (`submit_async_search`, `get_async_search`, `get_async_search_status`,
  `delete_async_search`), `scroll`/`clear_scroll`, and point-in-time
  (`open_point_in_time`/`close_point_in_time`).
- `Dowser.Elasticsearch.Document` — document-tagged endpoints: `index`,
  `create`, `get`, `delete`, `exists?`, `get_source`, `source_exists?`,
  `update`, `bulk`, `mget`, `delete_by_query`/`delete_by_query_rethrottle`,
  `update_by_query`/`update_by_query_rethrottle`, `termvectors`,
  `mtermvectors`, `reindex`/`reindex_rethrottle`.
- `Dowser.Elasticsearch.Index` — indices-tagged endpoints: index lifecycle
  (`create_index`, `delete_index`, `get_index`, `index_exists?`, `open`,
  `close`, `add_block`/`remove_block`), mappings (`put_mapping`,
  `get_mapping`, `get_field_mapping`), settings (`put_settings`,
  `get_settings`), aliases (`put_alias`, `delete_alias`, `get_alias`,
  `alias_exists?`, `update_aliases`), `clone`/`shrink`/`split`,
  `refresh`/`flush`/`forcemerge`/`clear_cache`, monitoring (`stats`,
  `segments`, `recovery`, `shard_stores`, `disk_usage`,
  `field_usage_stats`), `analyze`, `validate_query`,
  `reload_search_analyzers`, `resolve_index`, `resolve_cluster`, `rollover`,
  index/component templates (`put_index_template`, `get_index_template`,
  `delete_index_template`, `index_template_exists?`,
  `simulate_index_template`, `put_component_template`,
  `get_component_template`, `delete_component_template`,
  `component_template_exists?`), legacy templates — deprecated in favor of
  their index-template equivalents (`put_template`, `get_template`,
  `delete_template`, `template_exists?`, `simulate_template`), data
  lifecycle (`delete_data_lifecycle`), and dangling indices
  (`list_dangling_indices`, `import_dangling_index`,
  `delete_dangling_index`).
- `Dowser.Elasticsearch.Repository` — `use`-able repository pattern that
  binds the index-related functions of `Search`, `Document`, and `Index` to
  a fixed or computed index, with `:only`/`:except` filtering.
- `Dowser.Elasticsearch.TypeCodec` — optional whole-body type casting, set as
  `dowser_client`'s `:codec_adapter`: casts dates, IPs, geo points, and
  ranges to and from native Elixir terms against each document's own index
  mapping, at any nesting depth in a response (a bare document, `msearch`
  results, bulk items, …). Built on `Dowser.Elasticsearch.Codec` (the
  per-field cast dispatcher, extensible via `Dowser.Client.Codec.Builder`) and
  `Dowser.Elasticsearch.MappingCacher` (a cached, single-flight index-mapping
  fetcher, supervised by the application).
- `Dowser.Elasticsearch.Error` — the exception every non-2xx response is
  wrapped in, extracting `:type`/`:reason` from a standard Elasticsearch
  error body when present.

[Unreleased]: https://github.com/GRoguelon/dowser_elasticsearch/commits/main
