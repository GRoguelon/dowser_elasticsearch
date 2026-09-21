# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-19

Tracks [`dowser_client` 0.2.0](https://hexdocs.pm/dowser_client/UPGRADE_GUIDE_0_2.html),
which drops every optional dependency and every pluggable adapter. **See
[UPGRADE_0_2.md](UPGRADE_0_2.md) for the migration path** — this entry says
what changed, the guide says what to do about it.

### Added

- `Dowser.Elasticsearch.Streamer` — walks a whole search as a lazy `Stream` of
  hits, over a point in time and `search_after`, with `_shard_doc` appended to
  the sort as the tiebreaker that makes the paging deterministic. The point in
  time is opened when enumeration starts and closed when it ends, however it
  ends.

  ```elixir
  %{query: %{match_all: %{}}, size: 1_000}
  |> Dowser.Elasticsearch.Streamer.stream(index: "posts")
  |> Enum.each(&process/1)
  ```

  `stream_slices/4` runs a function over every slice of one shared point in
  time at once — a function rather than a stream, because a lazy stream handed
  back out of a task would run every page in the caller. A `slice` in the query
  body walks a single slice instead, for fanning out across nodes.

  ```elixir
  %{query: %{match_all: %{}}, size: 1_000}
  |> Dowser.Elasticsearch.Streamer.stream_slices(4, &Enum.count/1, index: "posts")
  |> Enum.sum()
  ```

  Neither has a bang variant: a stream has nothing to unwrap, and raises on
  enumeration anyway.
- A `:codec` option on every API function, choosing the field codec
  `Dowser.Elasticsearch.Codec` dispatches `load/2`/`dump/2` through for one
  request. It resolves most-specific-first: request, then context (alongside
  the pass it belongs to), then `config :dowser_elasticsearch, codec: ...`,
  then `Dowser.Elasticsearch.Codec` itself.
- `Dowser.Elasticsearch.MappingCacher.fetch/2`, a `get/2` returning the mapping
  or `nil` rather than a result tuple, and `key/2`, an entry's cache key.
- `Dowser.Elasticsearch.Codec.encode_bulk/3`, which casts a bulk operation list
  against the index named on each action line.

### Changed

- **`:codec_adapter` becomes a `:decoder` and an `:encoder`**, mirroring
  `dowser_client`'s split of one whole-body adapter into two passes.
  `Dowser.Elasticsearch.Codec` fills both slots, and `decode/2`, `encode/2`,
  `load/2` and `dump/2` keep the meanings they had in 0.1.1:

  ```diff
    config :dowser_client,
  -   configs: [
  +   contexts: [
        default: [
          endpoint: "http://localhost:9200",
  -       codec_adapter: Dowser.Elasticsearch.Codec
  +       decoder: Dowser.Elasticsearch.Codec,
  +       encoder: Dowser.Elasticsearch.Codec
        ]
      ]
  ```

  Casting stays opt-in: with neither configured, bodies are left exactly as
  JSON produced them and no mapping is ever fetched.
- **A query is never cast.** `dowser_client` only ever hands an encoder a
  document source, because a query value has no mapping entry to anchor it.
  Casting an old codec did on query values has to move into how the query is
  built.
- **`Dowser.Elasticsearch.Fields.*` are now `Dowser.Elasticsearch.Codec.*`**,
  under the module that dispatches to them. Their `load/2` and `dump/2` are
  unchanged:

  ```diff
  - Dowser.Elasticsearch.Fields.Date.load(value, field)
  + Dowser.Elasticsearch.Codec.Date.load(value, field)
  ```

- **`@behaviour Dowser.Elasticsearch.Codec` replaces
  `@behaviour Dowser.Client.Field`**, which `dowser_client` no longer ships,
  and the `use`/`cast` macro pair that assembled a dispatcher is gone with
  `Dowser.Client.Codec.Builder`. Covering one more mapping type is a `load/2`
  and a `dump/2` clause plus a delegation back to
  `Dowser.Elasticsearch.Codec`; delegating last inherits the built-in casts,
  the `nil` short-circuit and the fall-through to identity, and a clause
  matching a built-in type replaces that cast.
- **A custom field codec no longer means rewriting the envelope walker.** In
  0.1.1 a `Codec.Builder` module only got `load/2`/`dump/2`, so it could not be
  used on its own. Now the walking stays in `Dowser.Elasticsearch.Codec` and
  `:codec` points it at yours.
- Every API function's `:config` option is now `:context` — `dowser_client`
  rejects a request still carrying `:config` rather than silently sending it to
  the default cluster.
- `Dowser.Elasticsearch.Document.update/4` now casts an `upsert` source as well
  as a `doc` one, in either key style. A `%{script: ...}` body is still left
  alone.
- `Dowser.Elasticsearch.MappingCacher`'s `:fetch` and `:eager` options take a
  `Dowser.Client.Context` (or anything `Dowser.Client.Context.resolve/1`
  accepts) in place of a config.

### Fixed

- **A `date` was only cast when its value matched the declared format shape
  exactly.** Each format was matched byte by byte, so a field mapped
  `strict_date_time` holding `2026-09-20T20:46:03Z` — no fractional second —
  matched no clause and came back as the string it arrived as. An index holds
  values written before its mapping, so the format describes how Elasticsearch
  *writes* a field, not everything it contains. Reading now parses any ISO 8601
  date-time for any date-time format, including an offset (normalized to UTC)
  and a time with none at all (read as UTC, as Elasticsearch reads it).
  Date-only formats still read only a date, `dump/2` still writes the precision
  the format declares, and an unparseable value still passes through untouched.
- **`strict_date_optional_time` made the fraction mandatory.** It is
  Elasticsearch's default `date` format, and everything after the date in it
  is optional — the time, its fractional second, the offset. It was listed
  among the date-only and the millisecond formats but not the second-
  precision ones, so a document written `2026-09-20T17:39:09Z` was matched by
  no clause and came back as the string it arrived as. The two optional-time
  formats are now parsed rather than shape-matched, which also picks up
  offsets (`+01:00`, normalized to UTC), a time with no offset at all (read
  as UTC, as Elasticsearch reads it) and fractions of any length. An
  unparseable value still passes through untouched.
- **A hit's `inner_hits` came back string-keyed inside an otherwise atom-keyed
  response.** Only `_source` was walked; every other envelope field —
  `inner_hits`, `fields`, `highlight` — had its own key renamed and its value
  returned exactly as it arrived, so `hit.inner_hits` under `keys: :atoms` was
  a map of string keys. There is no mapping entry to cast these against (an
  inner hit is a nested document and carries no `_index`), but their keys are
  part of the same response and now follow the same `:keys`.
- A **range held in an array was never cast**. `date_range` and
  `integer_range` were handled only where the range is a direct child of an
  object; Elasticsearch lets any field hold an array, and a range reached
  through one arrived at the generic map walker instead, which cast its keys
  and never called the codec. The result was a `%{gte: _, lte: _}` map where
  a `Date.Range` was expected.
- Under `keys: :atoms`, the keys inside a `flattened` field — and inside an
  object mapped `"enabled": false` — were run through `String.to_atom/1`. The
  mapping enumerates none of those keys: they are whatever the document put
  there, so a writer could mint unbounded atoms in a table that is never
  collected and is capped a little over a million, crashing the node. Both are
  now returned as they arrived, keys left as strings and values uncast. Note
  this is narrower than the whole risk — `keys: :atoms` still casts keys the
  mapping doesn't mention, and `keys: :atoms!` is the option that cannot grow
  the table at all.
- `Dowser.Elasticsearch.MappingCacher` keyed entries by endpoint alone, so two
  contexts pointing at the same cluster with **different credentials** shared
  one cached mapping — whichever fetched first won, and the other was cast
  against a mapping it may not have been allowed to see (field-level security
  hides fields; an alias can resolve to a different concrete index). Entries
  are now keyed by `{endpoint, scope, index}`, where the scope is a truncated
  SHA-256 of the context's `:auth` and `:http_opts`. The credentials are hashed
  rather than stored: a cache key sits in an ETS table any process can read,
  and `Dowser.Client.Context` redacts `:auth` even from its own `Inspect`. A
  context with neither scopes to `nil`, so the unauthenticated key stays
  readable.

### Removed

- The `req`, `hackney`, `jason` and `poison` optional dependencies, and the
  `:http_adapter`/`:json_adapter` configuration that selected between them.
  HTTP is OTP's `:httpc` and JSON is Elixir's `JSON`. A struct sent in a
  request body needs `@derive JSON.Encoder` where it used to need
  `@derive Jason.Encoder`.
- The `cast/2` macro, along with `use Dowser.Client.Codec.Builder` and
  `@behaviour Dowser.Client.Field`. A codec is now plain function clauses, so
  the `cast: 2` formatter entry goes too — drop `import_deps: [:dowser_client]`
  from `.formatter.exs` if it was only there for that.
- `:codec_opts`. Whatever a pass needs travels with it, as
  `{Dowser.Elasticsearch.Codec, index: "articles"}`.

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
