# Upgrading from 0.4 to 0.5

0.5.0 follows `dowser_client` 0.4, and brings two changes with it:

- **Repos replace contexts.** A cluster is a module of your own —
  `use Dowser.Elasticsearch.Repo` — configured under your application and started
  in your supervision tree, like an `Ecto.Repo`. The `:context` option is now
  `:repo`.
- **The casting moved to `dowser_client`**, shared with `dowser_opensearch`.
  `Dowser.Elasticsearch.Codec` and `Dowser.Elasticsearch.MappingCacher` stay; the
  field codecs became `dowser_client`'s field types, and date casting is now
  limited to nine formats.

Start with the table, then read
[Watch out for silence](#watch-out-for-silence): the date changes return
different values without raising anything. `dowser_client`'s own
[`UPGRADE_GUIDE_0_4`](https://hexdocs.pm/dowser_client/UPGRADE_GUIDE_0_4.html)
has the transport-level details, for code that calls `Dowser.Client` directly.

## At a glance

| 0.4 | 0.5 |
| --- | --- |
| `config :dowser_client, contexts: [default: [...]]` | `use Dowser.Elasticsearch.Repo, otp_app: :my_app` + `config :my_app, MyApp.Search, ...` |
| the `:default` context | `config :dowser_elasticsearch, default_repo: MyApp.Search` |
| `context: :logs` / `context: [endpoint: ...]` | `repo: MyApp.Logs` / `repo: [endpoint: ...]` |
| `Dowser.Elasticsearch.Codec.Date` (and `Binary`, `DateRange`, `GeoPoint`, `IP`, `Range`) | `Dowser.Type.Date` (and so on) |
| `@behaviour Dowser.Elasticsearch.Codec` | `@behaviour Dowser.Type` |
| `Dowser.Elasticsearch.Codec.load/2`, `dump/2` | `Dowser.Type.load/2`, `dump/2` |
| `Dowser.Elasticsearch.MappingError` | `Dowser.MappingError` |
| `MappingCacher.put(index, mapping, context: ...)` | `MappingCacher.put(index, mapping, repo: ...)` — required |

What stays: the `:codec` option and its three tiers, `config :dowser_elasticsearch,
codec: / mappings: / mapping_failure: / mapping_cacher_opts:`, the
`[:dowser_elasticsearch, :mapping, :failure]` telemetry event,
`Dowser.Elasticsearch.Repository`, and every API function's signature.

## 1. Bump the dependency

```elixir
{:dowser_elasticsearch, "~> 0.5.0"}
```

```sh
mix deps.update dowser_elasticsearch dowser_client
```

## 2. Define a repo

Each context becomes a module:

```elixir
defmodule MyApp.Search do
  use Dowser.Elasticsearch.Repo, otp_app: :my_app
end
```

Its configuration moves to your application, under the module's name — the
keys are the same — and the repo the default context stood for becomes
`:default_repo`:

```diff
- config :dowser_client,
-   contexts: [
-     default: [
-       endpoint: "http://localhost:9200",
-       decoder: Dowser.Elasticsearch.Codec,
-       encoder: Dowser.Elasticsearch.Codec
-     ]
-   ]
+ config :my_app, MyApp.Search,
+   endpoint: "http://localhost:9200",
+   decoder: Dowser.Elasticsearch.Codec,
+   encoder: Dowser.Elasticsearch.Codec
+
+ config :dowser_elasticsearch, default_repo: MyApp.Search
```

Start it with the rest of your application:

```elixir
children = [MyApp.Repo, MyApp.Search, MyAppWeb.Endpoint]
```

A repo that isn't started still works — it resolves its configuration on every
request instead of once — so scripts and Mix tasks need nothing special.

Two things a repo adds:

- `init/2`, for configuration that can't live in a config file — see
  `Dowser.Repo`;
- `verify: true`, which makes the repo check at startup that its endpoint
  really is Elasticsearch (`GET /` carries no OpenSearch `distribution`, and
  either the `x-elastic-product: Elasticsearch` header or Elasticsearch's
  tagline), and fail to start otherwise. `MyApp.Search.engine()` then returns the version it
  found. It is off by default: a cluster that is down would stop your
  application from booting.

## 3. `:context` is `:repo`

```diff
- Dowser.Elasticsearch.Search.search(query, index: "logs-*", context: :logs)
+ Dowser.Elasticsearch.Search.search(query, index: "logs-*", repo: MyApp.Logs)
```

A call without `:repo` goes to `:default_repo`, as it went to the `:default`
context. A call that still passes `:context` fails with an error naming
`:repo`; a call with neither, and no `:default_repo` configured, fails with
`:no_repo`. The test suite finds them all.

The same goes for `Dowser.Elasticsearch.Repository` modules: their functions take
`repo:` where they took `context:`.

A repo also exposes the HTTP verbs, for an endpoint this package doesn't cover:

```elixir
MyApp.Search.post("/_ml/trained_models/_search", %{query: %{match_all: %{}}})
```

## 4. Field codecs are field types

The per-type modules moved to `dowser_client`, and the behaviour with them:

```diff
  defmodule MyApp.Type do
-   @behaviour Dowser.Elasticsearch.Codec
+   @behaviour Dowser.Type

    @impl true
    def load(value, %{"type" => "scaled_float", "scaling_factor" => factor}), do: value / factor
-   def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)
+   def load(value, field), do: Dowser.Type.load(value, field)

    @impl true
    def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor}), do: round(value * factor)
-   def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
+   def dump(value, field), do: Dowser.Type.dump(value, field)
  end
```

`Dowser.Elasticsearch.Codec` is still the module a repo names as `:decoder` and
`:encoder`, and `:codec` still points it at your type module — per request,
per repo, or globally. It no longer has `load/2`, `dump/2` or a behaviour of
its own.

## 5. `MappingError` moved

```diff
- rescue error in Dowser.Elasticsearch.MappingError -> ...
+ rescue error in Dowser.MappingError -> ...

- {:error, %Dowser.Elasticsearch.MappingError{index: index}} -> ...
+ {:error, %Dowser.MappingError{index: index}} -> ...
```

## 6. Tests

`MappingCacher.put/3` needs the repo the entry belongs to, and raises without
one. In 0.4 an entry put without a context was keyed under the `:default`
context, and when there was none, nothing was stored at all:

```diff
- Dowser.Elasticsearch.MappingCacher.put("posts", mapping)
+ Dowser.Elasticsearch.MappingCacher.put("posts", mapping, repo: MyApp.Search)
```

`config :dowser_elasticsearch, mappings: %{...}` is unchanged, and needs no
running cacher.

## Watch out for silence

Nothing below raises: the same document simply comes back with different
values. Grep your mappings, then your code.

### Dates are cast for nine formats only

A date field is cast only when its mapping names one of these formats, each
read by the Elixir function that parses it:

| format | Elixir |
| --- | --- |
| `epoch_millis`, `epoch_second` | `DateTime` |
| `strict_date` | `Date` |
| `strict_date_hour_minute_second`, `…_millis` | `NaiveDateTime` |
| `strict_date_time_no_millis`, `strict_date_time` | `DateTime` |
| `strict_hour_minute_second`, `…_millis` | `Time` |

Any other format is returned as stored — and so is **a date field with no
format at all**, which Elasticsearch reads as
`strict_date_optional_time||epoch_millis`. In 0.4 that default was cast, so a
field like `"published_at": {"type": "date"}` used to come back as a
`DateTime` and now comes back as a string.

For a new index, give each date field one of the nine formats. An existing
index can't change a field's format in place, so until it is reindexed, a type
module can tell the casting which formats to read the field with:

```elixir
defmodule MyApp.Type do
  @behaviour Dowser.Type

  # Fields mapped without a format: read them as date-times, dates or epoch
  # millis — written back as date-times.
  @default %{"format" => "strict_date_time||strict_date||epoch_millis"}

  @impl true
  def load(value, %{"type" => "date"} = field) when not is_map_key(field, "format"),
    do: Dowser.Type.load(value, Map.merge(field, @default))

  def load(value, field), do: Dowser.Type.load(value, field)

  @impl true
  def dump(value, %{"type" => "date"} = field) when not is_map_key(field, "format"),
    do: Dowser.Type.dump(value, Map.merge(field, @default))

  def dump(value, field), do: Dowser.Type.dump(value, field)
end
```

```elixir
config :dowser_elasticsearch, codec: MyApp.Type
```

### Dates are written exactly, and in UTC

- A date is written at exactly its format's precision: truncated to the second
  or the millisecond, and padded to three digits for a `_millis` format —
  `~U[2026-08-11 00:00:00Z]` is written `"2026-08-11T00:00:00.000Z"` to
  `strict_date_time`, where 0.4 wrote `"2026-08-11T00:00:00Z"`.
- A `DateTime` in another time zone is written as its UTC instant (`Z`). A
  stored offset (`-04:00`) is still applied and dropped on the way in, and
  `-00:00` is now read as UTC rather than left as a string.

### Ranges are cast only when the struct holds them exactly

A `date_range` becomes a `Date.Range` only when it is mapped `strict_date`; with
any other format, or none, it comes back as stored. 0.4 cast a format-less
range whose bounds were plain dates, and raised on one whose bounds had a
time. An
`integer_range` (and now a `long_range`) becomes a `Range` only with integer
`gte` and `lte` bounds. An open-ended range, or `gt`/`lt` bounds, come back as
stored.

### The mapping decides what a value is

- A `geo_point` stored as `{"lat": …, "lon": …}` now loads to `{lat, lon}`.
  0.4 never handed that shape to its type, so it stayed a map.
- A map its type leaves uncast — a `geo_shape`, an `integer_range` with float
  bounds — has its keys go through `:keys` like the rest of the document.
- A field the mapping doesn't know keeps its value as is. 0.4 walked it
  against its parent's fields.
