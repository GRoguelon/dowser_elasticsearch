# Upgrading from 0.1.1 to 0.2.1

0.2.1 follows `dowser_client` 0.2, which drops every optional dependency and
every pluggable adapter. Read
[its guide](https://hexdocs.pm/dowser_client/UPGRADE_GUIDE_0_2.html) for the
transport-level changes — dependencies, `configs:` → `contexts:`, `:http_opts`,
TLS verification — and this one for what `dowser_elasticsearch` renamed on top
of them.

Most of it is a rename, so start with the table. Then read
[Watch out for silence](#watch-out-for-silence), which is the part the compiler
cannot help you with.

## At a glance

| 0.1.1 | 0.2.1 |
| --- | --- |
| `codec_adapter: Dowser.Elasticsearch.Codec` | `decoder:` **and** `encoder:`, both `Dowser.Elasticsearch.Codec` |
| `Dowser.Elasticsearch.Fields.Date` | `Dowser.Elasticsearch.Codec.Date` |
| `@behaviour Dowser.Client.Field` | `@behaviour Dowser.Elasticsearch.Codec` |
| `use Dowser.Client.Codec.Builder` + `cast/2` | plain `load/2` and `dump/2` clauses |
| `codec_opts: [...]` | `{Codec, ...}`, or the `:codec` option |
| `config: ...` | `context: ...` |
| `configs: [...]` | `contexts: [...]` |
| `import_deps: [:dowser_client]` (for `cast: 2`) | nothing — there is no macro left |

Note what is *not* in that table: `decode/2`, `encode/2`, `load/2` and `dump/2`
all keep the meanings they had in 0.1.1 — a whole body for the first pair, one
value and its mapping entry for the second. Only where they live changed.

## 1. Dependencies

Remove `req`, `hackney`, `jason` and `poison` if they were there only for
`dowser_client`; nothing replaces them. HTTP is OTP's `:httpc` and JSON is
Elixir's `JSON`.

```diff
  def deps do
    [
-     {:dowser_elasticsearch, "~> 0.1.0"},
-     {:req, "~> 0.7"},
-     {:jason, "~> 1.4"}
+     {:dowser_elasticsearch, "~> 0.2.1"}
    ]
  end
```

A struct you send in a request body now needs `@derive JSON.Encoder` where it
needed `@derive Jason.Encoder`.

## 2. Configs are contexts

```diff
  config :dowser_client,
-   configs: [
+   contexts: [
      default: [endpoint: "http://localhost:9200", auth: {:basic, "user", "changeme"}]
    ]

- Dowser.Elasticsearch.Search.search(query, config: :logs)
+ Dowser.Elasticsearch.Search.search(query, context: :logs)
```

A request still carrying `:config` is rejected with a `Dowser.Client.Error`
rather than quietly going to the default cluster, so the compiler won't find
these but the first test run will.

## 3. One adapter, two options

`dowser_client` splits `:codec_adapter` — which cast a whole body in both
directions — into a `:decoder` and an `:encoder`, because reading and writing
need different information. `Dowser.Elasticsearch.Codec` fills both slots:

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

That is the whole of it. `decode/2` and `encode/2` still take a whole body,
`load/2` and `dump/2` still take one value, and the four keep the meanings they
had in 0.1.1.

Casting is still opt-in and still needs no per-call option: a response carries
each document's own `_index`, so reads need telling nothing, and the writing
functions name the index each source is going to and where in the body it sits.
With neither configured, bodies stay exactly as JSON produced them and no
mapping is ever fetched.

Two behaviours changed with the split, both because `dowser_client` now only
ever hands an encoder a **document source**:

- **A query is never cast.** In 0.1.1 a search body went through
  `encode/2` like any other. It no longer does — a query value has no mapping
  entry to anchor it. If you relied on that (a `DateTime` in a range clause,
  say), move the casting into how you build the query.
- **`update/4` casts `upsert` as well as `doc`**, in either key style. A
  `%{script: ...}` body is still left alone.

## 4. `Dowser.Elasticsearch.Fields.*` are `Dowser.Elasticsearch.Codec.*`

The six built-in field codecs moved under `Codec`, where the module that
dispatches to them lives. `load/2` and `dump/2` are unchanged:

```diff
- Dowser.Elasticsearch.Fields.Date.load(value, field)
+ Dowser.Elasticsearch.Codec.Date.load(value, field)
```

`Binary`, `Date`, `DateRange`, `GeoPoint`, `IP` and `Range` all moved the same
way, and what each one casts is unchanged. The compiler finds every reference.

## 5. The `cast/2` macro is gone

`Dowser.Client.Field` and `Dowser.Client.Codec.Builder` no longer exist
upstream. Their job — the behaviour, and assembling a dispatcher — is now
`Dowser.Elasticsearch.Codec` itself: `@behaviour Dowser.Elasticsearch.Codec`
means `load/2` and `dump/2`, and a codec of your own is a clause per direction
plus a delegation for everything else:

```diff
- defmodule MyApp.Codec do
-   use Dowser.Client.Codec.Builder, inherit: Dowser.Elasticsearch.Codec
-
-   cast %{"type" => "scaled_float"}, MyApp.Fields.ScaledFloat
- end
+ defmodule MyApp.Codec do
+   @behaviour Dowser.Elasticsearch.Codec
+
+   @impl true
+   def load(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
+     value / factor
+   end
+
+   def load(value, field), do: Dowser.Elasticsearch.Codec.load(value, field)
+
+   @impl true
+   def dump(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
+     round(value * factor)
+   end
+
+   def dump(value, field), do: Dowser.Elasticsearch.Codec.dump(value, field)
+ end
```

Delegating last is what `inherit:` used to do: it picks up the built-in casts,
the `nil` short-circuit and the fall-through to identity, so none of them need
restating. A clause matching a type the built-in codec already handles
*replaces* that cast, which is how you override a date `format` — no need to
redeclare the whole table any more.

A module written with `use Dowser.Client.Codec.Builder` won't compile, so the
compiler finds every one of these. Its formatter entry goes too:

```diff
  # .formatter.exs
- import_deps: [:dowser_client],
- locals_without_parens: [cast: 2]
```

### Pointing the casting at it

`:codec` resolves most-specific-first, so the tier you use is up to you:

```elixir
# per request, on any API function
Dowser.Elasticsearch.Document.get("posts", "1", codec: MyApp.Codec)

# per context, alongside the pass it belongs to
decoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Codec},
encoder: {Dowser.Elasticsearch.Codec, codec: MyApp.Codec}

# globally — the usual place for an application with one codec
config :dowser_elasticsearch, codec: MyApp.Codec
```

In 0.1.1 a custom dispatcher could not be used on its own: it only got
`load/2`/`dump/2`, so you had to write a whole-body module around it. That is
no longer true — the envelope walking stays in `Dowser.Elasticsearch.Codec`,
and only the per-field dispatch changes.

`:codec_opts` is gone. Whatever a pass needs now travels with it, as
`{Dowser.Elasticsearch.Codec, index: "articles"}`.

## 6. `MappingCacher`

`:fetch` and `:eager` speak of contexts rather than configs. The shape is
unchanged, so this is a rename in your own code:

```diff
- {Dowser.Elasticsearch.MappingCacher, fetch: fn config, index -> ... end}
+ {Dowser.Elasticsearch.MappingCacher, fetch: fn context, index -> ... end}
```

The argument is a resolved `Dowser.Client.Context`, so `config.endpoint` is
`context.endpoint` and credentials are at `context.auth`.

Two additions: `fetch/2` returns the mapping or `nil` instead of a result
tuple, and `key/2` returns an entry's cache key.

**Entries are keyed differently.** 0.1.1 keyed on the endpoint alone, so two
contexts pointing at the same cluster with different credentials shared one
cached mapping — whichever fetched first won. Since credentials can change what
`_mapping` returns (field-level security hides fields; an alias can resolve
elsewhere), the key is now `{endpoint, scope, index}`, where the scope is a
truncated SHA-256 of `:auth` and `:http_opts`. Nothing to change on your side
unless you were reading the ETS table directly.

## Watch out for silence

`Dowser.Client.Context` ignores keys that aren't fields, so an adapter option
left on a **context** is dropped without a word — and the result is not an
error but *no casting at all*:

```elixir
# silently does nothing in 0.2
contexts: [default: [endpoint: "...", codec_adapter: Dowser.Elasticsearch.Codec]]
```

Grep your config for these before upgrading:

```
codec_adapter   codec_opts   json_adapter   json_opts   http_adapter   configs:
```

On a *request* the same options are noisier — `dowser_client` logs a warning
for `:codec_adapter`/`:codec_opts`/`:json_adapter`/`:json_opts` and errors on
`:config`/`:http_adapter` — but a context is checked by nobody.

The same goes for a plain typo: `codecs: MyApp.Codec` on a request is accepted
and ignored, like any unknown option. If casting silently stops happening, that
is the first thing to check.

## Checklist

- [ ] Remove `req`, `hackney`, `jason`, `poison` from `deps` if they were there
      only for `dowser_client`; add `@derive JSON.Encoder` to structs you send.
- [ ] `configs:` → `contexts:`, `config:` → `context:`.
- [ ] Replace `codec_adapter: Dowser.Elasticsearch.Codec` with
      `decoder:` **and** `encoder:`, both `Dowser.Elasticsearch.Codec`.
- [ ] `Dowser.Elasticsearch.Fields.X` → `Dowser.Elasticsearch.Codec.X`
      (`load/2` and `dump/2` are unchanged).
- [ ] Rewrite any `use Dowser.Client.Codec.Builder` module as `load/2` and
      `dump/2` clauses delegating to `Dowser.Elasticsearch.Codec`, and point
      the casting at it with `:codec`.
- [ ] Drop `cast: 2` and `import_deps: [:dowser_client]` from
      `.formatter.exs`.
- [ ] Rename the `:fetch`/`:eager` arguments of `MappingCacher` from config to
      context.
- [ ] Move any casting your old codec did on *query* values into how you build
      the query.
- [ ] Run the suite, then grep for the names under
      [Watch out for silence](#watch-out-for-silence).
