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
- **Repos, like Ecto's.** A cluster is a module of your own
  (`use Dowser.Elasticsearch.Repo`), configured under your application and
  started in your supervision tree — one per cluster, or one per tenant with
  dynamic repos.
- **A repository pattern for free.** `Dowser.Elasticsearch.Repository` binds
  the index-related functions of `Search`, `Document`, and `Index` to a
  fixed or computed index, so your code stops repeating `index: "posts"` on
  every call.
- **Migrations, like Ecto's.** `mix dowser.migrate` changes your indices
  from versioned migration files — each index behind an alias, copied into a
  new one when Elasticsearch can't change it in place.
- **Optional type casting.** `Dowser.Elasticsearch.Codec` casts dates, ranges,
  IP addresses and other Elasticsearch types to and from Elixir terms, per
  index mapping — into maps, or into structs of your own (`struct:`).
- **No dependencies to pick.** Transport is handled by `dowser_client`, over
  OTP's `:httpc` and Elixir's built-in `JSON` module — nothing to add.

## Installation

Add `dowser_elasticsearch` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:dowser_elasticsearch, "~> 0.6.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/dowser_elasticsearch>.

**Upgrading from 0.4?** 0.5 replaces contexts with repos, moves the casting to
`dowser_client` and casts only nine date formats — see
[UPGRADE_0_5.md](UPGRADE_0_5.md) for the migration path, and
[CHANGELOG.md](CHANGELOG.md) for everything that changed. Coming from 0.1.x,
start with [UPGRADE_0_2.md](UPGRADE_0_2.md).

## Configuration

Define a repo — one module per cluster, configured under your own application
and started in your supervision tree, like an `Ecto.Repo`:

```elixir
defmodule MyApp.Search do
  use Dowser.Elasticsearch.Repo, otp_app: :my_app
end
```

```elixir
# config/runtime.exs
config :my_app, MyApp.Search, endpoint: System.get_env("ELASTICSEARCH_URL", "http://localhost:9200")

# the repo used when a call names none
config :dowser_elasticsearch, default_repo: MyApp.Search
```

```elixir
# application.ex
children = [MyApp.Search]
```

Every API function takes the cluster as its `:repo` option — a repo module, or
`[endpoint: ...]` for a script — and falls back to `:default_repo` without one.
See `Dowser.Elasticsearch.Repo` and `Dowser.Repo` for the configuration (auth,
headers, TLS, `:httpc` profiles, an `init/2` callback for secrets), checking at
startup that the endpoint really is Elasticsearch (`verify: true`), and the HTTP
verbs a repo exposes for endpoints this package doesn't cover.

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

### Cluster

```elixir
alias Dowser.Elasticsearch.Cluster

Cluster.ping?()
# true
Cluster.health!(params: [wait_for_status: "yellow"])
# %{"status" => "yellow", "number_of_nodes" => 1, ...}
Cluster.nodes_stats!(metric: "indices", index_metric: "docs")
```

### Cat

```elixir
alias Dowser.Elasticsearch.Cat

Cat.indices!(index: "posts*", params: [s: "docs.count:desc"])
# [%{"index" => "posts", "health" => "green", "docs.count" => "42", ...}]
```

The cat APIs answer in JSON here, one map per row, rather than the aligned
text a terminal shows — pass `params: [format: "text", v: true],
resp_format: :raw` for that.

### Health report, info and usage

```elixir
alias Dowser.Elasticsearch.HealthReport
alias Dowser.Elasticsearch.Info
alias Dowser.Elasticsearch.XPack

Info.info!()["version"]["number"]
# "9.0.0"
HealthReport.health_report!(feature: "disk")["indicators"]
XPack.usage!()["watcher"]["count"]
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

## Migrations

An application changes its indices with migrations, as it changes its
database tables with Ecto's: `mix dowser.gen.migration`, `mix dowser.migrate`,
`mix dowser.rollback`, from `dowser_client`. Every `use
Dowser.Elasticsearch.Repo` runs them against Elasticsearch through
`Dowser.Elasticsearch.Migration.Adapter`, so there is nothing to configure but
the repos to migrate:

```elixir
# config/config.exs
config :my_app, dowser_repos: [MyApp.Search]

# .formatter.exs — the migration DSL without parentheses
[import_deps: [:dowser_elasticsearch], ...]
```

```elixir
# priv/dowser/migrations/20261104120000_create_events.exs
defmodule MyApp.Search.Migrations.CreateEvents do
  use Dowser.Migration

  def change do
    create_index "events", %{
      settings: %{number_of_shards: 1},
      mappings: %{dynamic: :strict, properties: %{title: %{type: :text}}}
    }
  end
end
```

```sh
mix dowser.migrate --dry-run --reindex   # the requests it would send
mix dowser.migrate --reindex             # copies the indices it must
mix dowser.rollback
```

`"events"` is an alias of `events_20261104120000` — `events-20261104120000`
with `create_index "events", body, separator: "-"`. The migrations run are
recorded in the `dowser_schema_migrations` index, which also holds the lock
keeping two runs apart. See `Dowser.Migration` and `Dowser.Migrator`.

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
into the repo — as both passes — casts them automatically, per index
mapping, on every call to `Search` and `Document`:

```elixir
config :my_app, MyApp.Search,
  endpoint: "http://localhost:9200",
  decoder: Dowser.Elasticsearch.Codec,
  encoder: Dowser.Elasticsearch.Codec
```

```elixir
# with "published_at" mapped {"type": "date", "format": "strict_date_time_no_millis"}
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

Mappings are fetched once and cached by `Dowser.Elasticsearch.MappingCacher`. This
package doesn't start it: add it to your supervision tree, next to the repo —

```elixir
children = [MyApp.Search, Dowser.Elasticsearch.MappingCacher]
```

— or give the mappings yourself, and skip the cluster entirely:
`config :dowser_elasticsearch, mapping: MyApp.Mappings` (a `Dowser.Mapping` module),
or `struct:` on a call (a document module's own mapping). Casting against the
cluster's mappings with no cacher started fails with a `Dowser.MappingError`
naming it, rather than leaving every value uncast.

A `flattened` field, and an object mapped `"enabled": false`, are returned
exactly as stored.

### What is cast

The casting is `dowser_client`'s (`Dowser.Type`), the same on Elasticsearch and
OpenSearch. Only the types JSON can't represent are cast; every other value
passes through as decoded JSON:

| mapping type                  | stored                                     | Elixir                                      |
| ----------------------------- | ------------------------------------------ | ------------------------------------------- |
| `date`, `date_nanos`          | depends on the format — see below          | `Date`, `Time`, `DateTime`, `NaiveDateTime` |
| `date_range` (`strict_date`)  | `{"gte": "2019-03-01", "lte": "2019-03-31"}` | `Date.Range`                                |
| `integer_range`, `long_range` | `{"gte": 1, "lte": 10}`                    | `Range`                                     |
| `ip`                          | `"127.0.0.1"`                              | `{127, 0, 0, 1}`                            |
| `binary`                      | Base64                                     | raw binary                                  |
| `geo_point`                   | `{"lat": 1.2, "lon": 3.4}`                 | `{1.2, 3.4}`                                |

#### Dates

A date field's `format` decides what it is cast to. Nine formats are, each
read by the Elixir function that parses it:

| format                                  | stored                            | Elixir                                    |
| --------------------------------------- | --------------------------------- | ----------------------------------------- |
| `epoch_millis`                          | `1553391286000`                   | `DateTime.from_unix(value, :millisecond)` |
| `epoch_second`                          | `1553391286`                      | `DateTime.from_unix(value, :second)`      |
| `strict_date`                           | `"2019-03-23"`                    | `Date.from_iso8601/1`                     |
| `strict_date_hour_minute_second`        | `"2019-03-23T21:34:46"`           | `NaiveDateTime.from_iso8601/1`            |
| `strict_date_hour_minute_second_millis` | `"2019-03-23T21:34:46.123"`       | `NaiveDateTime.from_iso8601/1`            |
| `strict_date_time_no_millis`            | `"2019-03-23T21:34:46-04:00"`     | `DateTime.from_iso8601/1`                 |
| `strict_date_time`                      | `"2019-03-23T21:34:46.123-04:00"` | `DateTime.from_iso8601/1`                 |
| `strict_hour_minute_second`             | `"21:34:46"`                      | `Time.from_iso8601/1`                     |
| `strict_hour_minute_second_millis`      | `"21:34:46.123"`                  | `Time.from_iso8601/1`                     |

- **Any other format is not cast** — nor is a field with no format at all,
  which Elasticsearch reads as `strict_date_optional_time||epoch_millis`. Its
  values come back as stored, and are written as given. Map a date field with
  one of the nine to have it cast. A value its format can't read (a leap
  second, a malformed string) comes back as stored too.
- **Several formats** (`"strict_date||epoch_millis"`): a value is read with
  the first that recognizes it, and written with the first.
- **Precision:** a value is read at whatever precision it carries, and written
  at exactly the format's — truncated to the second or the millisecond, and
  padded to three digits for a `_millis` format
  (`~U[2019-03-24 01:34:46Z]` is written `"2019-03-24T01:34:46.000Z"` to
  `strict_date_time`).
- **Always UTC:** an offset in a stored value is applied and dropped, giving
  one UTC `DateTime`; a value with no offset, or `-00:00`, is read as UTC, as
  Elasticsearch reads it. A `DateTime` in any zone is written as its UTC instant
  (`Z`). No time-zone database is needed, and `tzdata` changes nothing. The
  instant is exact, but the original offset isn't kept: store the zone in a
  field of its own where the local time matters.

#### Ranges

A range is cast only when the Elixir struct holds it exactly: a `date_range`
mapped `strict_date` with `gte`/`lte` dates, an `integer_range` or
`long_range` with integer `gte`/`lte` bounds, `gte` no greater than `lte`.
Anything else — an open-ended range, `gt`/`lt` bounds, another date format —
comes back as stored. Only a range stepping by 1 is written back as a range.

### Casting a type of your own

Individual values go through a `Dowser.Type` module — `Dowser.Type` itself by
default. Covering one more mapping type is a clause per direction and a
delegation back to it for the rest:

```elixir
defmodule MyApp.Type do
  @behaviour Dowser.Type

  @impl true
  def load(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
    value / factor
  end

  def load(value, field), do: Dowser.Type.load(value, field)

  @impl true
  def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
    round(value * factor)
  end

  def dump(value, field), do: Dowser.Type.dump(value, field)
end
```

Delegating last inherits the built-in casts, the `nil` short-circuit and the
fall-through to identity; a clause matching a type `Dowser.Type` already
handles replaces that cast.

Point the casting at it with `:types` — globally, per repo, or per request,
most specific first:

```elixir
# globally
config :dowser_elasticsearch, types: MyApp.Type

# per repo, alongside the pass it belongs to
decoder: {Dowser.Elasticsearch.Codec, types: MyApp.Type}

# per request, on any API function
Document.get("posts", "1", types: MyApp.Type)
```

### The casting options

`:types` is one of five options deciding how documents are cast, all set the
same three ways:

| Option | Decides | Default |
| --- | --- | --- |
| `:mapping` | where the mapping comes from: a map, a `Dowser.Mapping` module, or a document module | `config :dowser_elasticsearch, mapping:`, else the cluster's via `Dowser.Elasticsearch.MappingCacher`, which you start |
| `:struct` | load each document into a document module's struct (`Dowser.Schema`), and dump it back — per call only | maps |
| `:types` | the `Dowser.Type` module leaf values go through | `Dowser.Type` |
| `:unknown_fields` | `:keep`, or `:raise` a `Dowser.UnknownFieldError` for a field the mapping doesn't declare | `:keep` |
| `:mapping_failure` | `:error`, `:warn` or `:ignore` when the mapping can't be fetched | `:error` |

```elixir
Document.get("posts", "1", struct: MyApp.Post)          # {:ok, %{"_source" => %MyApp.Post{}}}
Document.get("posts", "1", mapping: MyApp.Post)         # cast with its mapping, still a map
Search.search(query, index: "posts", unknown_fields: :raise)
```

`:mapping` and `:struct` turn casting on for that call even on a repo with no
`:decoder`/`:encoder` configured.

## Testing

A repo is where a test takes over: every request goes through it, and nothing
else needs replacing.

### Stub the HTTP layer, keep the pipeline

`Dowser.Client.HTTP.Stub` answers every request the test process makes, while
everything else — the repo, URL building, JSON, casting — runs as in
production. Point the calls at an ad-hoc repo (or your own, configured in
`config/test.exs`); stubs are per process, so tests stay `async: true`:

```elixir
test "loads a post" do
  Dowser.Client.HTTP.Stub.stub(fn :get, "http://localhost:9200/posts/_doc/1", _headers, _body, _opts ->
    Dowser.Client.HTTP.Stub.json(200, %{
      "_index" => "posts",
      "_id" => "1",
      "_source" => %{"title" => "hi", "published_at" => "2026-08-11T00:00:00.000Z"}
    })
  end)

  assert {:ok, %{"_source" => %MyApp.Post{title: "hi"}}} =
           Dowser.Elasticsearch.Document.get("posts", "1",
             repo: [endpoint: "http://localhost:9200"],
             struct: MyApp.Post
           )
end
```

Casting against the cluster's mappings needs mappings in tests too: give them
with `config :dowser_elasticsearch, mappings: %{"posts" => %{...}}` (no cacher
needed), `mapping:` / `struct:`, or start `Dowser.Elasticsearch.MappingCacher` with
`start_supervised!/1` and `put/3` the mappings into it.

### Mock the repo

For a unit test that only needs a canned answer, mock the repo itself: a repo
is the `Dowser.Repo` behaviour, so [Mox](https://hexdocs.pm/mox) can stand in
for one.

```elixir
# test/test_helper.exs
Mox.defmock(MyApp.SearchMock, for: Dowser.Repo)

# in your test
Mox.expect(MyApp.SearchMock, :request, fn :post, "/posts/_search", _query, _opts ->
  {:ok, %Dowser.Client.Response{status: 200, headers: %{}, body: %{"hits" => %{"hits" => []}}}}
end)

assert {:ok, %{"hits" => %{"hits" => []}}} =
         Dowser.Elasticsearch.Search.search(%{query: %{match_all: %{}}}, index: "posts", repo: MyApp.SearchMock)
```

The mock stands in for the whole transport — encoding, decoding and casting
included — so its body is exactly what the caller gets. Set
`config :dowser_elasticsearch, default_repo: MyApp.SearchMock` in `config/test.exs`
to have every call that names no repo go to it.

### Mock the repo with Mimic

[Mimic](https://hexdocs.pm/mimic) stubs the functions of an existing module,
per test process. A test-only repo module becomes the default repo in the test
environment, so the code under test — which names no repo — talks to it, and
each test says what `request/4` answers. `request/4` is the one function every
API call goes through.

```elixir
# mix.exs
defp deps do
  [
    # ...
    {:mimic, "~> 1.10", only: :test}
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_env), do: ["lib"]
```

```elixir
# test/support/search_mock.ex — a repo like any other, compiled for tests only
defmodule MyApp.SearchMock do
  use Dowser.Elasticsearch.Repo, otp_app: :my_app
end
```

```elixir
# config/test.exs — the default repo is the mock in tests
config :my_app, MyApp.SearchMock, endpoint: "http://search.test"
config :dowser_elasticsearch, default_repo: MyApp.SearchMock
```

```elixir
# test/test_helper.exs
Mimic.copy(MyApp.SearchMock)
ExUnit.start()
```

```elixir
defmodule MyApp.PostsTest do
  use ExUnit.Case, async: true
  use Mimic

  test "searches the posts" do
    expect(MyApp.SearchMock, :request, fn :post, "/posts/_search", _query, _opts ->
      {:ok, %Dowser.Client.Response{status: 200, headers: %{}, body: %{"hits" => %{"hits" => []}}}}
    end)

    # MyApp.Posts.search/1 calls Dowser.Elasticsearch.Search.search(query, index: "posts"),
    # with no :repo — so it goes to the default repo, the mock.
    assert {:ok, %{"hits" => %{"hits" => []}}} = MyApp.Posts.search("hello")
  end
end
```

A few things to know:

- The stub stands in for the whole transport, so the body it returns is what
  the caller gets — nothing is decoded or cast. Let the request through with
  `call_original/3` where the casting matters, or stub the HTTP layer instead.
- Mimic stubs are per process, which keeps `async: true` tests apart. A request
  made from another process — a `Task`, a GenServer — needs
  `Mimic.allow(MyApp.SearchMock, self(), pid)`, or `set_mimic_global` in a test
  that isn't async.
- Mimic replaces calls *into* the module. The repo's own verbs
  (`MyApp.SearchMock.get/2`, …) reach `request/4` from inside it, so a test
  calling them directly stubs the verb it calls.
- Calls that name a repo (`repo: MyApp.Search`) bypass the default: point
  `repo:` at the same mock in tests, or have the code read its repo from
  configuration.

### Against a real cluster

Point a repo at a local cluster in `config/test.exs`, and start the mapping
cacher if the tests cast against the cluster's mappings. Tests that share an
index can't run concurrently: run them `async: false`, or give each test
indices of its own (`"posts_#{System.unique_integer([:positive])}"`), created
in `setup` and deleted in `on_exit`.

## Compatibility

### Elasticsearch version

Tested against Elasticsearch 9.x. Earlier versions haven't been tested but
should work, since the wrapped endpoints are stable across releases.

### Endpoint coverage

Elasticsearch groups its API into tags, and each supported tag maps to one
`Dowser.Elasticsearch.*` module. Every endpoint of a supported tag is
implemented, each as a pair of functions (`search/2` and `search!/2`).

| Endpoint tag                          | Supported | Module         |
| ------------------------------------- | :-------: | -------------- |
| Behavioral analytics                  | ❌         |                |
| Compact and aligned text (CAT)        | ✅         | `Cat`          |
| Cluster                               | ✅         | `Cluster`      |
| Cluster - Health                      | ✅         | `HealthReport` |
| Connector                             | ❌         |                |
| Cross-cluster replication             | ❌         |                |
| Data stream                           | ❌         |                |
| Document                              | ✅         | `Document`     |
| Enrich                                | ❌         |                |
| EQL                                   | ❌         |                |
| ES\|QL                                | ❌         |                |
| Features                              | ❌         |                |
| Fleet                                 | ❌         |                |
| Graph explore                         | ❌         |                |
| Index                                 | ✅         | `Index`        |
| Index lifecycle management            | ❌         |                |
| Inference                             | ❌         |                |
| Info                                  | ✅         | `Info`         |
| Ingest                                | ❌         |                |
| Licensing                             | ❌         |                |
| Logstash                              | ❌         |                |
| Machine learning                      | ❌         |                |
| Machine learning anomaly detection    | ❌         |                |
| Machine learning data frame analytics | ❌         |                |
| Machine learning trained model        | ❌         |                |
| Migration                             | ❌         |                |
| Query rules                           | ❌         |                |
| Reindex                               | ✅         | `Reindex`      |
| Rollup                                | ❌         |                |
| Script                                | ❌         |                |
| Search                                | ✅         | `Search`       |
| Search application                    | ❌         |                |
| Searchable snapshots                  | ❌         |                |
| Security                              | ❌         |                |
| Snapshot and restore                  | ❌         |                |
| Snapshot lifecycle management         | ❌         |                |
| SQL                                   | ❌         |                |
| Streams                               | ❌         |                |
| Synonyms                              | ❌         |                |
| Task management                       | ❌         |                |
| Text structure                        | ❌         |                |
| Transform                             | ❌         |                |
| Usage                                 | ✅         | `XPack`        |
| Watcher                               | ❌         |                |

## Development

```sh
mix deps.get
mix test
mix lint    # format --check-formatted, credo --strict, dialyzer
```

This package is developed alongside `dowser_client`. To build against a
working copy of it rather than the published release — needed whenever this
package relies on a `dowser_client` change not on Hex yet — set
`DOWSER_CLIENT_PATH`:

```sh
DOWSER_CLIENT_PATH=../dowser_client mix deps.get
DOWSER_CLIENT_PATH=../dowser_client mix test
```

`mix lint` runs the three checks this project keeps green. Dialyzer's PLTs are
built into `priv/plts/` on the first run, which takes a couple of minutes; the
runs after that are seconds.

## Trademark Notice

This project is an independent, community-maintained library and is not
affiliated with, endorsed by, or sponsored by Elasticsearch B.V.

**Elasticsearch** is a trademark of Elasticsearch B.V., registered in the
U.S. and in other countries.
