defmodule Dowser.Elasticsearch.Codec do
  @moduledoc """
  Casts a single value against its Elasticsearch mapping entry — the per-field
  codec `Dowser.Elasticsearch.Decoder` and `Dowser.Elasticsearch.Encoder` use
  by default.

  `decode/2` goes from Elasticsearch's representation to a native Elixir term,
  `encode/2` back. The mapping entry's `"type"` selects the codec module that
  handles it; only the types JSON can't natively represent are cast, and any
  other entry — like a `nil` value — falls back to identity.

  | mapping type           | codec                                    | Elixir term    |
  | ---------------------- | ---------------------------------------- | -------------- |
  | `date`, `date_nanos`   | `Dowser.Elasticsearch.Codec.Date`        | `DateTime`     |
  | `date_range`           | `Dowser.Elasticsearch.Codec.DateRange`   | `Date.Range`   |
  | `integer_range`        | `Dowser.Elasticsearch.Codec.Range`       | `Range`        |
  | `ip`                   | `Dowser.Elasticsearch.Codec.IP`          | `:inet` tuple  |
  | `binary`               | `Dowser.Elasticsearch.Codec.Binary`      | raw binary     |
  | `geo_point`            | `Dowser.Elasticsearch.Codec.GeoPoint`    | `{lat, lon}`   |

      iex> Dowser.Elasticsearch.Codec.decode("127.0.0.1", %{"type" => "ip"})
      {127, 0, 0, 1}

      iex> Dowser.Elasticsearch.Codec.encode({127, 0, 0, 1}, %{"type" => "ip"})
      "127.0.0.1"

  ## The behaviour

  This module is also the behaviour each codec in the table implements: two
  functions over one value and the mapping entry describing it (`field`), which
  return the cast term directly. A value a codec doesn't recognize should pass
  through unchanged rather than raise, so a bad cast degrades to identity
  instead of failing the whole document.

      defmodule MyApp.Codec.ScaledFloat do
        @behaviour Dowser.Elasticsearch.Codec

        @impl true
        def decode(value, %{"scaling_factor" => factor}) when is_integer(value) do
          value / factor
        end

        def decode(value, _field), do: value

        @impl true
        def encode(value, %{"scaling_factor" => factor}) when is_float(value) do
          round(value * factor)
        end

        def encode(value, _field), do: value
      end

  ## Adding mapping types

  A codec is a plain module, so covering one more type is a clause per
  direction and a delegation back here for everything else:

      defmodule MyApp.Codec do
        @behaviour Dowser.Elasticsearch.Codec

        @impl true
        def decode(value, %{"type" => "my_type"} = field) do
          # ...
        end

        def decode(value, field), do: Dowser.Elasticsearch.Codec.decode(value, field)

        @impl true
        def encode(value, %{"type" => "my_type"} = field) do
          # ...
        end

        def encode(value, field), do: Dowser.Elasticsearch.Codec.encode(value, field)
      end

  Delegating last is what inherits the built-in casts — including the `nil`
  short-circuit and the fall-through to identity, so neither needs restating.
  Matching a type this module already handles *replaces* that cast (e.g. to
  handle a custom date `format`), since your clause comes first.

  ## Choosing the codec

  `Dowser.Elasticsearch.Decoder` and `Dowser.Elasticsearch.Encoder` take a
  `:codec` option — the envelope walking stays the same, only the per-field
  dispatch changes. It resolves most-specific-first, like every other option
  in this package:

    1. **Per request** — `:codec` alongside any other option:

           Dowser.Elasticsearch.Document.get("posts", "1", codec: MyApp.Codec)

    2. **Per context** — named alongside the decoder/encoder it belongs to:

           config :dowser_client,
             contexts: [
               default: [
                 endpoint: "http://localhost:9200",
                 decoder: {Dowser.Elasticsearch.Decoder, codec: MyApp.Codec},
                 encoder: {Dowser.Elasticsearch.Encoder, codec: MyApp.Codec}
               ]
             ]

    3. **Globally** — the usual place for an application with one codec, and
       the only tier that needs no tuple:

           config :dowser_elasticsearch, codec: MyApp.Codec

    4. This module, when none of the above is set.
  """

  ## Behaviour callbacks

  @doc "Casts `value` from its Elasticsearch representation into a richer term."
  @callback decode(value :: term(), field :: term()) :: term()

  @doc "Casts `value` back into its Elasticsearch representation."
  @callback encode(value :: term(), field :: term()) :: term()

  # This module dispatches to the codecs in the table below, and is itself one:
  # `decode/2`/`encode/2` over a value and its mapping entry, falling back to
  # identity.
  @behaviour __MODULE__

  ## Module attributes

  @codecs %{
    "binary" => Dowser.Elasticsearch.Codec.Binary,
    "date" => Dowser.Elasticsearch.Codec.Date,
    "date_nanos" => Dowser.Elasticsearch.Codec.Date,
    "date_range" => Dowser.Elasticsearch.Codec.DateRange,
    "geo_point" => Dowser.Elasticsearch.Codec.GeoPoint,
    "integer_range" => Dowser.Elasticsearch.Codec.Range,
    "ip" => Dowser.Elasticsearch.Codec.IP
  }

  ## Public functions

  @doc """
  Casts `value` from Elasticsearch's representation, dispatching on `field`'s
  `"type"`.

  A `nil` value, a mapping entry with no known `"type"`, or no mapping entry at
  all, all return `value` untouched — so a missing mapping degrades a cast to
  identity rather than failing.
  """
  @impl true
  def decode(value, field)

  def decode(nil, _field), do: nil

  def decode(value, %{"type" => type} = field) do
    case Map.fetch(@codecs, type) do
      {:ok, codec} ->
        codec.decode(value, field)

      :error ->
        value
    end
  end

  def decode(value, _field), do: value

  @doc """
  Casts `value` back into Elasticsearch's representation, dispatching on
  `field`'s `"type"`.

  The mirror image of `decode/2`, with the same fallbacks.
  """
  @impl true
  def encode(value, field)

  def encode(nil, _field), do: nil

  def encode(value, %{"type" => type} = field) do
    case Map.fetch(@codecs, type) do
      {:ok, codec} ->
        codec.encode(value, field)

      :error ->
        value
    end
  end

  def encode(value, _field), do: value
end
