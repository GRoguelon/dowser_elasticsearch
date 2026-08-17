# Dowser.Elasticsearch

`dowser_elasticsearch` is an Elixir client library for the Elasticsearch
API, built on top of [`dowser_client`](https://hex.pm/packages/dowser_client).
It gives you one function per Elasticsearch endpoint — named and shaped after
the endpoint itself — instead of a hand-rolled query builder.

- **Predictable functions.** Every endpoint maps to one function, named after
  Elasticsearch's own operation names (`create_index`, `get_alias`,
  `search`, …). Required attributes are positional arguments; everything
  optional lives in an `opts` keyword list.
- **Every function has a bang variant.** `search/2` returns
  `{:ok, body}`/`{:error, error}`; `search!/2` returns the body directly or
  raises. `HEAD` existence checks follow the same idea with a `?` variant
  instead of `!`.
- **A repository pattern for free.** `Dowser.Elasticsearch.Repository` binds
  the index-related functions of `Search`, `Document`, and `Index` to a
  fixed or computed index, so your code stops repeating `index: "posts"` on
  every call.
- **Optional automatic type casting.** `Dowser.Elasticsearch.Codec` casts
  dates, IPs, and other Elasticsearch types to and from native Elixir terms,
  per index mapping, with no per-call option needed.
- **Bring your own HTTP/JSON stack.** Transport is handled by
  `dowser_client`, which defaults to Erlang's built-in `:httpc` and Elixir's
  built-in `JSON` module, or can be pointed at `Req`/`:hackney` and
  `Jason`/`Poison`.

## Installation

Add `dowser_elasticsearch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dowser_elasticsearch, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/dowser_elasticsearch>.

## Configuration

Point the client at your cluster via `dowser_client`'s `:configs` config —
see [its README](https://hexdocs.pm/dowser_client) for the full set of
options (auth, headers, HTTP/JSON adapters):

```elixir
config :dowser_client,
  configs: [
    default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}]
  ]
```

Every API function accepts a `:config` option to target a specific entry
(or an ad-hoc inline config) instead of `:default`.

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

{:ok, %{"_id" => id}} = MyApp.Posts.index(%{title: "hello"})
# POST /posts/_doc

MyApp.Posts.search!(%{query: %{match_all: %{}}})
# GET /posts/_search

MyApp.Posts.exists?(id)
# HEAD /posts/_doc/:id — true/false
```

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

MyApp.TenantLogs.index(%{message: "boom"}, "acme")
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
other Elasticsearch types stay strings. Setting
`Dowser.Elasticsearch.Codec` as `:codec_adapter` casts them automatically,
per index mapping, on every call to `Search` and `Document`:

```elixir
config :dowser_client,
  configs: [
    default: [
      endpoint: "http://localhost:9200",
      codec_adapter: Dowser.Elasticsearch.Codec
    ]
  ]
```

```elixir
Document.get!("posts", "1")
# %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00Z]}, ...}
```

Mappings are fetched once and cached by `Dowser.Elasticsearch.MappingCacher`,
which the application supervises automatically. `date`, `date_range`, `ip`,
`binary`, `geo_point` and `integer_range` fields are cast out of the box; see
`Dowser.Elasticsearch.Codec` for how to add your own field types.

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
