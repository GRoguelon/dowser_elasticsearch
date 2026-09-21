# Dowser.Elasticsearch

`dowser_elasticsearch` is an Elixir client library for the Elasticsearch
API, built on top of [`dowser_client`](https://hex.pm/packages/dowser_client).
It gives you one function per Elasticsearch endpoint — named and shaped after
the endpoint itself — instead of a hand-rolled query builder.

- **Predictable functions.** Every endpoint maps to one function, named after
  Elasticsearch's own operation names (`create_index`, `get_alias`,
  `search`, …). Required attributes are positional arguments; everything
  optional lives in an `opts` keyword list.
- **Every endpoint has a bang variant.** `search/2` returns
  `{:ok, body}`/`{:error, error}`; `search!/2` returns the body directly or
  raises. `HEAD` existence checks follow the same idea with a `?` variant
  instead of `!`.
- **Streaming for large result sets.** `Dowser.Elasticsearch.Streamer` walks a
  whole search as an Elixir `Stream`, and `stream_slices/4` walks several
  slices of it at once.
- **A repository pattern for free.** `Dowser.Elasticsearch.Repository` binds
  the index-related functions of `Search`, `Document`, and `Index` to a
  fixed or computed index, so your code stops repeating `index: "posts"` on
  every call.
- **Optional automatic type casting.** `Dowser.Elasticsearch.Codec` casts
  dates, IPs, and other Elasticsearch types to and from native Elixir terms,
  per index mapping, with no per-call option needed.
- **No dependencies to pick.** Transport is handled by `dowser_client`, over
  OTP's `:httpc` and Elixir's built-in `JSON` module — nothing to add, nothing
  to configure.

## Installation

Add `dowser_elasticsearch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dowser_elasticsearch, "~> 0.2.2"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/dowser_elasticsearch>.

**Upgrading from 0.1.x?** 0.2.2 rewires how the casting is configured and
follows `dowser_client` 0.2 in dropping its optional dependencies. The
casting functions themselves are unchanged — see
[UPGRADE_0_2.md](UPGRADE_0_2.md) for the migration path, and
[CHANGELOG.md](CHANGELOG.md) for everything that changed.

## Configuration

Point the client at your cluster via `dowser_client`'s `:contexts` config —
see [its README](https://hexdocs.pm/dowser_client) for the full set of
options (auth, headers, TLS, `:httpc` profiles):

```elixir
config :dowser_client,
  contexts: [
    default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}]
  ]
```

Every API function accepts a `:context` option to target a specific entry
(or an ad-hoc inline context) instead of `:default`.

## Usage

Each module maps to one Elasticsearch API tag. Request bodies come first so
calls pipe naturally; the index (when required) follows; everything
optional goes in `opts`.

### Search

```elixir
alias Dowser.Elasticsearch.Search

%{query: %{match: %{title: "hello"}}}
|> Search.search(index: "posts")
# {:ok, %{"hits" => %{...}}}

Search.count!(%{query: %{term: %{status: "published"}}}, index: "posts")
# %{"count" => 42, "_shards" => %{...}}
```

### Document

```elixir
alias Dowser.Elasticsearch.Document

{:ok, %{"_id" => id}} = Document.index(%{title: "hello"}, "posts")

Document.get!("posts", id)
# %{"_source" => %{"title" => "hello"}, ...}

Document.exists?("posts", id)
# true

Document.delete("posts", id)
```

### Index

```elixir
alias Dowser.Elasticsearch.Index

Index.create_index!(%{mappings: %{properties: %{title: %{type: "text"}}}}, "posts")
Index.index_exists?("posts")
# true
Index.refresh(index: "posts")
Index.delete_index("posts")
```

## Streaming

A search returns one page. `Dowser.Elasticsearch.Streamer` walks all of them,
as a lazy `Stream` of hits:

```elixir
alias Dowser.Elasticsearch.Streamer

%{query: %{match_all: %{}}, size: 1_000}
|> Streamer.stream(index: "posts")
|> Stream.map(& &1["_source"])
|> Enum.each(&process/1)
```

Each element is a hit, cast exactly as `Search.search/2` would cast it. Under
the hood a [point in time](https://www.elastic.co/guide/en/elasticsearch/reference/current/point-in-time-api.html)
pins the index against concurrent writes and `search_after` pages through it,
with `_shard_doc` appended to your sort as the tiebreaker that makes the
paging deterministic. The point in time is opened when enumeration starts and
closed when it ends — whether that is the last page, an `Enum.take/2`, or an
exception.

A query with no `size` gets 1000 rather than Elasticsearch's default of 10: at
ten hits per round trip, a million documents is a hundred thousand requests.

### In parallel

`search_after` is sequential by construction — a page's cursor is the last hit
of the page before it — so one stream cannot fetch pages in parallel.
Slicing is what does: `stream_slices/4` splits one point in time into
disjoint subsets and walks them at once.

```elixir
%{query: %{match_all: %{}}, size: 1_000}
|> Streamer.stream_slices(4, &Enum.count/1, index: "posts")
|> Enum.sum()
```

Note that it takes a *function*, not a stream. Each slice is consumed inside
the task that reads it; a lazy stream handed back out of a task would be built
there and then run every page in the caller — concurrent in name only. So keep
what the function returns small: a count, a sum, `:ok`.

Elasticsearch divides first across shards, then within each shard, so the
useful number of slices is your shard count. To spread a walk across *nodes*
instead of processes, open a point in time yourself and give each node one
slice — `slice` is an ordinary search body field:

```elixir
Streamer.stream(%{query: ..., slice: %{id: 2, max: 8}}, pit: pit_id)
```

There is no `stream!/2`: a stream has nothing to unwrap, and raises on
enumeration anyway.

## Repository pattern

Calling `Search`, `Document`, and `Index` directly means repeating
`index: "posts"` (or recomputing it) on every call. `use
Dowser.Elasticsearch.Repository` generates index-bound versions of those
functions instead:

```elixir
defmodule MyApp.Posts do
  use Dowser.Elasticsearch.Repository,
    index: "posts",
    only: [
      search: [:search, :count],
      document: [:index, :get, :delete, :exists],
      index: [:create_index, :refresh]
    ]
end

MyApp.Posts.create_index!(%{mappings: %{properties: %{title: %{type: "text"}}}})
# PUT /posts

{:ok, %{"_id" => id}} = MyApp.Posts.index_doc(%{title: "hello"})
# POST /posts/_doc

MyApp.Posts.search!(%{query: %{match_all: %{}}})
# GET /posts/_search

MyApp.Posts.doc_exists?(id)
# HEAD /posts/_doc/:id — true/false
```

A handful of `Document` functions are generated under a different name to
keep them distinct from other modules' functions (`index` → `index_doc`,
`exists`/`exists?` → `doc_exists`/`doc_exists?`, `create` → `create_doc`,
`delete` → `delete_doc`, `get` → `get_doc`, `update` → `update_doc`) — see
`Dowser.Elasticsearch.Repository` for the full rename table.

`:index` also accepts a 1-arity function for a *dynamic* (e.g. per-tenant or
time-based) index. The generated functions then take a *term* — positionally
or via the `:index` option — and resolve it through that function:

```elixir
defmodule MyApp.TenantLogs do
  use Dowser.Elasticsearch.Repository,
    index: &__MODULE__.index_name/1,
    only: [search: [:search], document: [:index]]

  def index_name(tenant), do: "logs_#{tenant}"
end

MyApp.TenantLogs.index_doc(%{message: "boom"}, "acme")
# POST /logs_acme/_doc

MyApp.TenantLogs.search(%{query: %{match_all: %{}}}, index: "acme")
# GET /logs_acme/_search
```

Without `:only`/`:except`, every index-related function of `Search`,
`Document`, and `Index` is generated. Functions that don't target an index
(templates, `reindex`, `scroll`, …) are never generated — call their module
directly.

## Type casting

By default, response bodies come back as plain decoded JSON — dates, IPs and
other Elasticsearch types stay strings. Wiring `Dowser.Elasticsearch.Codec`
into the context — as both passes — casts them automatically, per index
mapping, on every call to `Search` and `Document`:

```elixir
config :dowser_client,
  contexts: [
    default: [
      endpoint: "http://localhost:9200",
      decoder: Dowser.Elasticsearch.Codec,
      encoder: Dowser.Elasticsearch.Codec
    ]
  ]
```

```elixir
Document.get!("posts", "1")
# %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00Z]}, ...}

Document.index!(%{published_at: ~U[2026-08-11 00:00:00Z]}, "posts")
# POST /posts/_doc {"published_at":"2026-08-11T00:00:00Z"}
```

`decode/2` finds documents anywhere in a response envelope and casts each one
against the mapping of its own `_index`. `encode/2` is the mirror image, but
only ever runs on a *document source* — the functions in `Document` name the
index each source is going to and where in the request body it sits. A query
is never cast, since a query value has no mapping entry to anchor it: build
queries in the shape Elasticsearch expects.

Mappings are fetched once and cached by `Dowser.Elasticsearch.MappingCacher`,
which the application supervises automatically. `date`, `date_range`, `ip`,
`binary`, `geo_point` and `integer_range` fields are cast out of the box.

Individual values go through the same module's `load/2` and `dump/2`. Covering
one more mapping type is a clause per direction and a delegation back to it for
the rest:

```elixir
defmodule MyApp.Codec do
  @behaviour Dowser.Elasticsearch.Codec

  @impl true
  def load(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
    value / factor
  end

  def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)

  @impl true
  def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
    round(value * factor)
  end

  def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
end
```

Delegating last inherits the built-in casts, the `nil` short-circuit and the
fall-through to identity; a clause matching a type the built-in codec already
handles replaces that cast.

Point the casting at it globally, per context, or per request — most specific
wins:

```elixir
# globally
config :dowser_elasticsearch, codec: MyApp.Codec

# per context, alongside the pass it belongs to
decoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Codec}

# per request, on any API function
Document.get("posts", "1", codec: MyApp.Codec)
```

## Compatibility

### Elasticsearch version

Tested against Elasticsearch 9.x. Earlier versions haven't been tested but
should work, since the wrapped endpoints are stable across releases.

### Endpoint coverage

Elasticsearch groups its API into tags; only `Search`, `Document`, and
`Index` are currently implemented.

| Endpoint tag                              | Supported |
| ------------------------------------------ | :-------: |
| Behavioral analytics                       | ❌        |
| Compact and aligned text (CAT)             | ❌        |
| Cluster                                    | ❌        |
| Cluster - Health                           | ❌        |
| Connector                                  | ❌        |
| Cross-cluster replication                  | ❌        |
| Data stream                                | ❌        |
| Document                                   | ✅        |
| Enrich                                     | ❌        |
| EQL                                        | ❌        |
| ES\|QL                                     | ❌        |
| Features                                   | ❌        |
| Fleet                                      | ❌        |
| Graph explore                              | ❌        |
| Index                                      | ✅        |
| Index lifecycle management                 | ❌        |
| Inference                                  | ❌        |
| Info                                       | ❌        |
| Ingest                                     | ❌        |
| Licensing                                  | ❌        |
| Logstash                                   | ❌        |
| Machine learning                           | ❌        |
| Machine learning anomaly detection         | ❌        |
| Machine learning data frame analytics      | ❌        |
| Machine learning trained model             | ❌        |
| Migration                                  | ❌        |
| Query rules                                | ❌        |
| Reindex                                    | ❌        |
| Rollup                                     | ❌        |
| Script                                     | ❌        |
| Search                                     | ✅        |
| Search application                         | ❌        |
| Searchable snapshots                       | ❌        |
| Security                                   | ❌        |
| Snapshot and restore                       | ❌        |
| Snapshot lifecycle management              | ❌        |
| SQL                                        | ❌        |
| Streams                                    | ❌        |
| Synonyms                                   | ❌        |
| Task management                            | ❌        |
| Text structure                             | ❌        |
| Transform                                  | ❌        |
| Usage                                      | ❌        |
| Watcher                                    | ❌        |

## Trademark Notice

This project is an independent, community-maintained library and is not
affiliated with, endorsed by, or sponsored by Elasticsearch B.V.

**Elasticsearch** is a trademark of Elasticsearch B.V., registered in the
U.S. and in other countries.
