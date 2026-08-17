defmodule Dowser.Elasticsearch.Codec do
  @moduledoc """
  The built-in field codec: dispatches a value to the `Dowser.Client.Field` module
  matching its mapping entry, built with `Dowser.Client.CodecBuilder`.

  `load/2` and `dump/2` receive a single field value and its mapping entry
  (`%{"type" => ..., "format" => ...}`) and return the cast value directly.
  Only the field types JSON can't natively represent are cast; any other
  mapping entry — and `nil` values — fall back to identity.

  | mapping type           | field                                    | Elixir term    |
  | ----------------------- | ----------------------------------------- | -------------- |
  | `date`, `date_nanos`   | `Dowser.Elasticsearch.Fields.Date`       | `DateTime`     |
  | `date_range`           | `Dowser.Elasticsearch.Fields.DateRange`  | `Date.Range`   |
  | `integer_range`        | `Dowser.Elasticsearch.Fields.Range`      | `Range`        |
  | `ip`                   | `Dowser.Elasticsearch.Fields.IP`         | `:inet` tuple  |
  | `binary`               | `Dowser.Elasticsearch.Fields.Binary`     | raw binary     |
  | `geo_point`            | `Dowser.Elasticsearch.Fields.GeoPoint`   | `{lat, lon}`   |

  Whole documents are cast against an index mapping by
  `Dowser.Elasticsearch.TypeCodec`, which walks a document via the
  `Dowser.Elasticsearch.Mappable` protocol and dispatches each field's value
  to this module's `load/2`/`dump/2`.

  ## Custom codecs

  Build your own codec to add field types, inheriting the built-in casts:

      defmodule MyApp.Codec do
        use Dowser.Client.CodecBuilder, inherit: Dowser.Elasticsearch.Codec

        cast %{"type" => "scaled_float"}, MyApp.Fields.ScaledFloat
      end

  Inherited casts are matched first, so to *replace* a built-in cast (e.g.
  handle a custom date `format`), declare every cast yourself instead of
  inheriting.
  """

  use Dowser.Client.CodecBuilder

  alias Dowser.Elasticsearch.Fields

  ## Type castings

  cast(%{"type" => "date"}, Fields.Date)
  cast(%{"type" => "date_nanos"}, Fields.Date)
  cast(%{"type" => "date_range"}, Fields.DateRange)
  cast(%{"type" => "integer_range"}, Fields.Range)
  cast(%{"type" => "ip"}, Fields.IP)
  cast(%{"type" => "binary"}, Fields.Binary)
  cast(%{"type" => "geo_point"}, Fields.GeoPoint)
end
