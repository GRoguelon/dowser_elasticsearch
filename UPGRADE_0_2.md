# Upgrading from 0.1.1 to 0.2.0

0.2.0 follows `dowser_client` 0.2.0, which drops every optional dependency and
every pluggable adapter. Read
[its guide](https://hexdocs.pm/dowser_client/UPGRADE_GUIDE_0_2.html) for the
transport-level changes — dependencies, `configs:` → `contexts:`, `:http_opts`,
TLS verification — and this one for what `dowser_elasticsearch` renamed on top
of them.

Most of it is a rename, so start with the table. Then read
[One name that moved](#one-name-that-moved), which is the part a search-and-
replace gets wrong, and [Watch out for silence](#watch-out-for-silence), which
is the part the compiler cannot help you with.

## At a glance

| 0.1.1 | 0.2.0 |
| --- | --- |
| `codec_adapter: Dowser.Elasticsearch.Codec` | `decoder: Dowser.Elasticsearch.Decoder` **and** `encoder: Dowser.Elasticsearch.Encoder` |
| `Codec.decode/2` (a whole response body) | `Dowser.Elasticsearch.Decoder.decode/2` |
| `Codec.encode/2` (a whole request body) | `Dowser.Elasticsearch.Encoder.encode/2` |
| `Codec.load/2` (one value) | `Dowser.Elasticsearch.Codec.decode/2` |
| `Codec.dump/2` (one value) | `Dowser.Elasticsearch.Codec.encode/2` |
| `Dowser.Elasticsearch.Fields.Date` | `Dowser.Elasticsearch.Codec.Date` |
| `@behaviour Dowser.Client.Field` | `@behaviour Dowser.Elasticsearch.Codec` |
| `use Dowser.Client.Codec.Builder` + `cast/2` | plain `decode/2`/`encode/2` clauses |
| `codec_opts: [...]` | `{Decoder, ...}`, or the `:codec` option |
| `config: ...` | `context: ...` |
| `configs: [...]` | `contexts: [...]` |
| `import_deps: [:dowser_client]` (for `cast: 2`) | nothing — there is no macro left |

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
+     {:dowser_elasticsearch, "~> 0.2.0"}
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

## 3. One codec becomes two passes and a codec

In 0.1.1, `Dowser.Elasticsearch.Codec` did two unrelated jobs: it walked whole
bodies as `dowser_client`'s `:codec_adapter`, and it cast individual values
through a `cast/2` table. 0.2.0 splits the first job in two — because reading
and writing need different information — and leaves the second where it was:

| | reads | writes |
| --- | --- | --- |
| a whole body | `Dowser.Elasticsearch.Decoder` | `Dowser.Elasticsearch.Encoder` |
| one value | `Dowser.Elasticsearch.Codec.decode/2` | `Dowser.Elasticsearch.Codec.encode/2` |

Wire the two passes onto the context in place of `:codec_adapter`:

```diff
  config :dowser_client,
-   configs: [
+   contexts: [
      default: [
        endpoint: "http://localhost:9200",
-       codec_adapter: Dowser.Elasticsearch.Codec
+       decoder: Dowser.Elasticsearch.Decoder,
+       encoder: Dowser.Elasticsearch.Encoder
      ]
    ]
```

Casting is still opt-in and still needs no per-call option: every function in
`Document` and `Search` names the index its documents belong to, and the
writing ones also say where in the request body a document source sits. With
neither configured, bodies stay exactly as JSON produced them and no mapping is
ever fetched.

Two behaviours changed with the split, both because `dowser_client` now only
ever hands an encoder a **document source**:

- **A query is never cast.** In 0.1.1 a search body went through
  `Codec.encode/2` like any other. It no longer does — a query value has no
  mapping entry to anchor it. If you relied on that (a `DateTime` in a range
  clause, say), move the casting into how you build the query.
- **`update/4` casts `upsert` as well as `doc`**, in either key style. A
  `%{script: ...}` body is still left alone.

## 4. `Dowser.Elasticsearch.Fields.*` are `Dowser.Elasticsearch.Codec.*`

The six built-in field modules moved and their two functions were renamed to
match the direction they were always going:

```diff
- Dowser.Elasticsearch.Fields.Date.load(value, field)
+ Dowser.Elasticsearch.Codec.Date.decode(value, field)

- Dowser.Elasticsearch.Fields.IP.dump(value, field)
+ Dowser.Elasticsearch.Codec.IP.encode(value, field)
```

`Binary`, `Date`, `DateRange`, `GeoPoint`, `IP` and `Range` all moved the same
way. What each one casts is unchanged.

## 5. The `cast/2` macro is gone

`Dowser.Client.Field` and `Dowser.Client.Codec.Builder` no longer exist
upstream. Their job — the behaviour, and assembling a dispatcher — is now
`Dowser.Elasticsearch.Codec` itself, and a codec of your own is a clause per
direction plus a delegation for everything else:

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
+   def decode(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
+     value / factor
+   end
+
+   def decode(value, field), do: Dowser.Elasticsearch.Codec.decode(value, field)
+
+   @impl true
+   def encode(value, %{"type" => "scaled_float", "scaling_factor" => factor}) do
+     round(value * factor)
+   end
+
+   def encode(value, field), do: Dowser.Elasticsearch.Codec.encode(value, field)
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

# per context, alongside the decoder/encoder it belongs to
decoder: {Dowser.Elasticsearch.Decoder, codec: MyApp.Codec},
encoder: {Dowser.Elasticsearch.Encoder, codec: MyApp.Codec}

# globally — the usual place for an application with one codec
config :dowser_elasticsearch, codec: MyApp.Codec
```

In 0.1.1 a custom dispatcher could not be used on its own: it only got
`load/2`/`dump/2`, so you had to write a whole-body module around it. That is
no longer true — the envelope walking stays in `Decoder`/`Encoder`, and only
the per-field dispatch changes.

`:codec_opts` is gone. Whatever a decoder or encoder needs now travels with it,
as `{Dowser.Elasticsearch.Decoder, index: "articles"}`.

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

## One name that moved

`Dowser.Elasticsearch.Codec.decode/2` exists in both versions and means
something different in each:

```elixir
# 0.1.1 — one value, against its mapping entry
Dowser.Elasticsearch.Codec.load(value, %{"type" => "ip"})

# 0.1.1 — a whole response body
Dowser.Elasticsearch.Codec.decode(body, key_fn: &Function.identity/1)

# 0.2.0 — one value
Dowser.Elasticsearch.Codec.decode(value, %{"type" => "ip"})

# 0.2.0 — a whole response body
Dowser.Elasticsearch.Decoder.decode(body, key_fn: &Function.identity/1)
```

So a call to `Codec.decode/2` written against 0.1.1 still compiles against
0.2.0 and does something else entirely: it takes the body as a *value* and the
option list as a *mapping entry*, matches no known `"type"`, and hands the body
straight back.

How loudly that fails depends on how you wrote it. The 0.1.1 pass returned
`{:ok, term}` and the 0.2.0 codec returns the term, so a call whose result you
matched raises a `MatchError`:

```elixir
{:ok, body} = Dowser.Elasticsearch.Codec.decode(body, opts)
```

A call whose result you piped or bound plainly does not raise at all — it just
silently stops casting.

There are only two shapes to look for, and both are rare outside tests — the
pass is normally driven by the context, not called directly:

```
Dowser.Elasticsearch.Codec.decode(   # whole body?  -> Decoder.decode/2
Dowser.Elasticsearch.Codec.encode(   # whole body?  -> Encoder.encode/2
```

`load/2` and `dump/2` have no such problem: they no longer exist, so the
compiler flags them.

## Watch out for silence

`Dowser.Client.Context` ignores keys that aren't fields, so an adapter option
left on a **context** is dropped without a word — and the result is not an
error but *no casting at all*:

```elixir
# silently does nothing in 0.2.0
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
      `decoder: Dowser.Elasticsearch.Decoder` **and**
      `encoder: Dowser.Elasticsearch.Encoder`.
- [ ] `Dowser.Elasticsearch.Fields.X` → `Dowser.Elasticsearch.Codec.X`, and
      their `load/2`/`dump/2` → `decode/2`/`encode/2`.
- [ ] Rewrite any `use Dowser.Client.Codec.Builder` module as `decode/2` and
      `encode/2` clauses delegating to `Dowser.Elasticsearch.Codec`, and point
      the casting at it with `:codec`.
- [ ] Drop `cast: 2` and `import_deps: [:dowser_client]` from
      `.formatter.exs`.
- [ ] Rename the `:fetch`/`:eager` arguments of `MappingCacher` from config to
      context.
- [ ] Move any casting your old codec did on *query* values into how you build
      the query.
- [ ] Run the suite, then grep for the names under
      [Watch out for silence](#watch-out-for-silence) and for
      `Codec.decode(`/`Codec.encode(` under
      [One name that moved](#one-name-that-moved).
