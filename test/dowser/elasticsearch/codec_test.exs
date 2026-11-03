defmodule Dowser.Elasticsearch.CodecTest do
  use ExUnit.Case, async: false

  alias Dowser.Elasticsearch.Codec
  alias Dowser.Elasticsearch.HTTPStub
  alias Dowser.MappingError

  @mapping %{
    "properties" => %{
      "published_at" => %{"type" => "date", "format" => "strict_date_time_no_millis"},
      "ip" => %{"type" => "ip"}
    }
  }

  @context Dowser.Client.Context.new(endpoint: "http://x:9200")

  defp context_opts(extra \\ []), do: Keyword.merge([context: @context], extra)

  defp decode_opts(extra \\ []),
    do: context_opts(Keyword.put_new(extra, :key_fn, &Function.identity/1))

  describe "decode/2 — document found at any depth" do
    test "a bare document (Document.get/3 shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{"_source" => %{"published_at" => ~U[2026-08-11 00:00:00.000Z]}} =
               Codec.decode(body, decode_opts())
    end

    test "a document nested under hits.hits[] (search shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "took" => 1,
        "hits" => %{
          "hits" => [
            %{
              "_index" => "posts",
              "_id" => "1",
              "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
            }
          ]
        }
      }

      assert %{"hits" => %{"hits" => [%{"_source" => source}]}} =
               Codec.decode(body, decode_opts())

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
    end

    test "a document nested under responses[].hits.hits[] (msearch shape) is cast" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "responses" => [
          %{
            "hits" => %{
              "hits" => [
                %{
                  "_index" => "posts",
                  "_id" => "1",
                  "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
                }
              ]
            }
          }
        ]
      }

      assert %{"responses" => [%{"hits" => %{"hits" => [%{"_source" => source}]}}]} =
               Codec.decode(body, decode_opts())

      assert source["published_at"] == ~U[2026-08-11 00:00:00.000Z]
    end

    test "different documents are cast against their own index's mapping" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      fetch = fn _context, index ->
        case index do
          "posts" -> {:ok, @mapping}
          "comments" -> {:ok, other_mapping}
        end
      end

      start_supervised!({Dowser.Elasticsearch.MappingCacher, fetch: fetch})

      body = [
        %{
          "_index" => "posts",
          "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
        },
        %{"_index" => "comments", "_source" => %{"ip" => "127.0.0.1"}}
      ]

      assert [%{"_source" => %{"published_at" => date}}, %{"_source" => %{"ip" => ip}}] =
               Codec.decode(body, decode_opts())

      assert date == ~U[2026-08-11 00:00:00.000Z]
      assert ip == {127, 0, 0, 1}
    end

    test "with no mapping cacher running, values pass through but keys are still processed" do
      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{"_id" => "1", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}} =
               Codec.decode(body, decode_opts())
    end

    test "key_fn is applied throughout, including inside _source" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
      }

      assert %{_id: "1", _source: %{published_at: ~U[2026-08-11 00:00:00.000Z]}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — the rest of a hit's envelope" do
    test "inner_hits keys follow the same :keys as the rest of the response" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_id" => "1",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"},
        "inner_hits" => %{
          "alerts" => %{
            "hits" => %{
              "total" => %{"value" => 1, "relation" => "eq"},
              "hits" => [%{"_id" => "a1", "_source" => %{"record_id" => "r1"}}]
            }
          }
        }
      }

      assert %{inner_hits: inner_hits} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      # Renaming only the outer key would leave a string-keyed map inside an
      # otherwise atom-keyed response.
      assert %{alerts: %{hits: %{total: %{value: 1}, hits: [hit]}}} = inner_hits
      assert hit == %{_id: "a1", _source: %{record_id: "r1"}}
    end

    @nested_mapping %{
      "properties" => %{
        "published_at" => %{"type" => "date", "format" => "strict_date_time_no_millis"},
        "alerts" => %{
          "type" => "nested",
          "properties" => %{
            "record_id" => %{"type" => "keyword"},
            "dates" => %{"type" => "date_range", "format" => "strict_date"},
            "votes" => %{
              "type" => "nested",
              "properties" => %{"cast_at" => %{"type" => "date", "format" => "strict_date"}}
            }
          }
        }
      }
    }

    test "an inner hit's source is cast against the mapping of its nested path" do
      HTTPStub.start_mapping_cacher!(@nested_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"},
        "inner_hits" => %{
          "alerts" => %{
            "hits" => %{
              "total" => %{"value" => 1, "relation" => "eq"},
              "max_score" => 6.1,
              "hits" => [
                %{
                  "_index" => "posts",
                  "_id" => "a1",
                  "_nested" => %{"field" => "alerts", "offset" => 0},
                  "_source" => %{
                    "record_id" => "r1",
                    "dates" => [%{"gte" => "2026-08-24", "lte" => "2026-08-24"}]
                  }
                }
              ]
            }
          }
        }
      }

      assert %{inner_hits: %{alerts: %{hits: %{max_score: 6.1, hits: [hit]}}}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert hit._source.dates == [Date.range(~D[2026-08-24], ~D[2026-08-24])]
      assert hit._nested == %{field: "alerts", offset: 0}
    end

    test "a doubly nested inner hit follows the whole _nested chain" do
      HTTPStub.start_mapping_cacher!(@nested_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{},
        "inner_hits" => %{
          "alerts.votes" => %{
            "hits" => %{
              "hits" => [
                %{
                  "_nested" => %{
                    "field" => "alerts",
                    "offset" => 0,
                    "_nested" => %{"field" => "votes", "offset" => 1}
                  },
                  "_source" => %{"cast_at" => "2026-08-24"}
                }
              ]
            }
          }
        }
      }

      assert %{inner_hits: %{"alerts.votes": %{hits: %{hits: [hit]}}}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert hit._source.cast_at == ~D[2026-08-24]
    end

    test "an inner hit on a path the mapping doesn't know passes through uncast" do
      HTTPStub.start_mapping_cacher!(@nested_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{},
        "inner_hits" => %{
          "gone" => %{
            "hits" => %{
              "hits" => [
                %{
                  "_nested" => %{"field" => "gone", "offset" => 0},
                  "_source" => %{"dates" => [%{"gte" => "2026-08-24", "lte" => "2026-08-24"}]}
                }
              ]
            }
          }
        }
      }

      assert %{inner_hits: %{gone: %{hits: %{hits: [hit]}}}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert hit._source.dates == [%{gte: "2026-08-24", lte: "2026-08-24"}]
    end

    test "a hit's other envelope fields are keyed the same way" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"},
        "sort" => ["a", 1],
        "fields" => %{"title.keyword" => ["hi"]}
      }

      assert %{sort: ["a", 1], fields: %{"title.keyword": ["hi"]}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — ranges inside an array" do
    @range_mapping %{
      "properties" => %{
        "run" => %{"type" => "date_range", "format" => "strict_date"},
        "runs" => %{"type" => "date_range", "format" => "strict_date"},
        "counts" => %{"type" => "integer_range"}
      }
    }

    test "a date_range held in an array is cast, like one held directly" do
      HTTPStub.start_mapping_cacher!(@range_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{
          "run" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
          "runs" => [
            %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
            %{"gte" => "2026-09-01", "lte" => "9999-12-31"}
          ]
        }
      }

      assert %{_source: %{run: run, runs: runs}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert run == Date.range(~D[2026-08-01], ~D[2026-08-11])

      assert runs == [
               Date.range(~D[2026-08-01], ~D[2026-08-11]),
               Date.range(~D[2026-09-01], ~D[9999-12-31])
             ]
    end

    test "an integer_range held in an array is cast too" do
      HTTPStub.start_mapping_cacher!(@range_mapping)

      body = %{"_index" => "posts", "_source" => %{"counts" => [%{"gte" => 1, "lte" => 10}]}}

      assert %{_source: %{counts: [1..10]}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — an object shaped like a range" do
    # `period` and `window` hold the same `%{"gte" => _, "lte" => _}` shape as
    # `run`, but are mapped as two `date` fields rather than as a `date_range`
    # — which is what a document written before the field was mapped as a range
    # leaves behind. `window` spells the object out with `"type" => "object"`,
    # `period` leaves it implicit, as Elasticsearch does for a dynamic mapping.
    @object_range_mapping %{
      "properties" => %{
        "run" => %{"type" => "date_range", "format" => "strict_date"},
        "period" => %{
          "dynamic" => "strict",
          "properties" => %{
            "gte" => %{"type" => "date", "format" => "strict_date"},
            "lte" => %{"type" => "date", "format" => "strict_date"}
          }
        },
        "window" => %{
          "type" => "object",
          "properties" => %{
            "gte" => %{"type" => "date", "format" => "strict_date"},
            "lte" => %{"type" => "date", "format" => "strict_date"}
          }
        }
      }
    }

    test "its keys go through key_fn and its bounds are cast, rather than passing through" do
      HTTPStub.start_mapping_cacher!(@object_range_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{
          "period" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
          "window" => %{"gte" => "2026-09-01", "lte" => "9999-12-31"}
        }
      }

      assert %{_source: %{period: period, window: window}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert period == %{gte: ~D[2026-08-01], lte: ~D[2026-08-11]}
      assert window == %{gte: ~D[2026-09-01], lte: ~D[9999-12-31]}
    end

    test "a real date_range alongside it is still cast to a Date.Range" do
      HTTPStub.start_mapping_cacher!(@object_range_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{
          "run" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"},
          "period" => %{"gte" => "2026-08-01", "lte" => "2026-08-11"}
        }
      }

      assert %{_source: %{run: run, period: period}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert run == Date.range(~D[2026-08-01], ~D[2026-08-11])
      assert period == %{gte: ~D[2026-08-01], lte: ~D[2026-08-11]}
    end
  end

  describe "decode/2 — a subtree the mapping declares opaque" do
    @opaque_mapping %{
      "properties" => %{
        "title" => %{"type" => "keyword"},
        "roster" => %{"type" => "flattened"},
        "stash" => %{"type" => "object", "enabled" => false}
      }
    }

    test "a flattened field's keys are never run through key_fn" do
      HTTPStub.start_mapping_cacher!(@opaque_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{
          "title" => "hi",
          "roster" => %{"Managed Care Biller" => "Sam", "Division" => "WEST"}
        }
      }

      assert %{_source: %{title: "hi", roster: roster}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      # The mapping enumerates `title`, so that key is safe to cast; it says
      # nothing about what is inside `roster`, so those stay strings.
      assert Map.keys(roster) |> Enum.sort() == ["Division", "Managed Care Biller"]
    end

    test "an object with enabled: false is left alone too" do
      HTTPStub.start_mapping_cacher!(@opaque_mapping)

      body = %{"_index" => "posts", "_source" => %{"stash" => %{"whatever" => "x"}}}

      assert %{_source: %{stash: %{"whatever" => "x"}}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end

    test "creates no atoms, however many keys the document carries" do
      HTTPStub.start_mapping_cacher!(@opaque_mapping)

      body = %{
        "_index" => "posts",
        "_source" => %{"roster" => Map.new(1..200, &{"key_from_the_document_#{&1}", "v"})}
      }

      before = :erlang.system_info(:atom_count)
      Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))

      assert :erlang.system_info(:atom_count) == before
    end

    test "values inside are not cast either — the mapping describes none of them" do
      HTTPStub.start_mapping_cacher!(@opaque_mapping)

      body = %{"_index" => "posts", "_source" => %{"roster" => %{"joined" => "2026-08-11"}}}

      assert %{"_source" => %{"roster" => %{"joined" => "2026-08-11"}}} =
               Codec.decode(body, decode_opts())
    end

    test "a list of flattened objects is left alone" do
      HTTPStub.start_mapping_cacher!(@opaque_mapping)

      body = %{"_index" => "posts", "_source" => %{"roster" => [%{"A B" => 1}, %{"C D" => 2}]}}

      assert %{_source: %{roster: [%{"A B" => 1}, %{"C D" => 2}]}} =
               Codec.decode(body, decode_opts(key_fn: &String.to_atom/1))
    end
  end

  describe "decode/2 — opts[:source] (Document.get_source/3 shape)" do
    test "a bare source with no embedded _index uses opts[:index]" do
      HTTPStub.start_mapping_cacher!(@mapping)

      body = %{"published_at" => "2026-08-11T00:00:00.000Z"}

      assert %{"published_at" => ~U[2026-08-11 00:00:00.000Z]} =
               Codec.decode(body, decode_opts(source: true, index: "posts"))
    end
  end

  describe "a mapping that could not be fetched" do
    defp failing_cacher! do
      ExUnit.Callbacks.start_supervised!(
        {Dowser.Elasticsearch.MappingCacher, fetch: fn _context, _index -> {:error, :timeout} end}
      )
    end

    test "raises a MappingError by default rather than casting nothing" do
      failing_cacher!()
      body = %{"_index" => "posts", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}}

      assert_raise MappingError, ~r/could not fetch the mapping for index "posts"/, fn ->
        Codec.decode(body, decode_opts())
      end

      assert_raise MappingError, fn ->
        Codec.encode(%{"published_at" => ~U[2026-08-11 00:00:00Z]}, context_opts(index: "posts"))
      end
    end

    test "casts to identity under mapping_failure: :ignore" do
      failing_cacher!()
      body = %{"_index" => "posts", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}}

      assert %{"_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}} =
               Codec.decode(body, decode_opts(mapping_failure: :ignore))
    end

    test "logs and casts to identity under mapping_failure: :warn" do
      failing_cacher!()
      body = %{"_index" => "posts", "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert %{"_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}} =
                   Codec.decode(body, decode_opts(mapping_failure: :warn))
        end)

      assert log =~ "could not fetch the mapping for index \"posts\""
    end

    test "emits telemetry whatever the policy" do
      failing_cacher!()
      event = [:dowser_elasticsearch, :mapping, :failure]

      :telemetry.attach(
        inspect(self()),
        event,
        fn _e, m, meta, _ -> send(self(), {m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(inspect(self())) end)

      Codec.decode(
        %{"_index" => "posts", "_source" => %{}},
        decode_opts(mapping_failure: :ignore)
      )

      assert_received {%{count: 1}, %{index: "posts", reason: :timeout, policy: :ignore}}
    end

    test "opts[:mapping] skips the lookup entirely" do
      failing_cacher!()

      assert %{"published_at" => ~U[2026-08-11 00:00:00.000Z]} =
               Codec.decode(
                 %{"published_at" => "2026-08-11T00:00:00.000Z"},
                 decode_opts(source: true, index: "posts", mapping: @mapping)
               )
    end

    test "no mapping to be had is not a failure" do
      # No cacher running at all: nothing to cast against, and nothing failed.
      assert %{"_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}} =
               Codec.decode(
                 %{
                   "_index" => "posts",
                   "_source" => %{"published_at" => "2026-08-11T00:00:00.000Z"}
                 },
                 decode_opts()
               )
    end
  end

  describe "decode/2 — opts[:codec]" do
    defmodule UpcaseCodec do
      @behaviour Dowser.Type

      @impl true
      def load(value, %{"type" => "text"}) when is_binary(value), do: String.upcase(value)
      def load(value, field), do: Dowser.Type.load(value, field)

      @impl true
      def dump(value, field), do: Dowser.Type.dump(value, field)
    end

    test "values are cast through the given codec instead of the default" do
      HTTPStub.start_mapping_cacher!(%{
        "properties" => %{"title" => %{"type" => "text"}}
      })

      body = %{"_index" => "posts", "_source" => %{"title" => "hello"}}

      assert %{"_source" => %{"title" => "HELLO"}} =
               Codec.decode(body, decode_opts(codec: UpcaseCodec))

      assert %{"_source" => %{"title" => "hello"}} = Codec.decode(body, decode_opts())
    end
  end

  describe "encode/2" do
    test "casts the source against opts[:index]'s mapping" do
      HTTPStub.start_mapping_cacher!(@mapping)

      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts(index: "posts")) ==
               %{"published_at" => "2026-08-11T00:00:00Z"}
    end

    test "no opts[:index] means no mapping — values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts()) == document
    end

    test "with no mapping cacher running, values pass through" do
      document = %{"published_at" => ~U[2026-08-11 00:00:00Z]}

      assert Codec.encode(document, context_opts(index: "posts")) == document
    end

    defmodule DowncaseCodec do
      @behaviour Dowser.Type

      @impl true
      def load(value, field), do: Dowser.Type.load(value, field)

      @impl true
      def dump(value, %{"type" => "text"}) when is_binary(value), do: String.downcase(value)
      def dump(value, field), do: Dowser.Type.dump(value, field)
    end

    test "opts[:codec] replaces the default codec" do
      HTTPStub.start_mapping_cacher!(%{"properties" => %{"title" => %{"type" => "text"}}})

      document = %{"title" => "HELLO"}

      assert Codec.encode(document, context_opts(index: "posts", codec: DowncaseCodec)) ==
               %{"title" => "hello"}

      assert Codec.encode(document, context_opts(index: "posts")) == document
    end
  end

  describe "encode/2 — a subtree the mapping declares opaque" do
    test "a flattened source passes through untouched" do
      HTTPStub.start_mapping_cacher!(%{
        "properties" => %{
          "published_at" => %{"type" => "date", "format" => "strict_date_time_no_millis"},
          "roster" => %{"type" => "flattened"}
        }
      })

      source = %{
        "published_at" => ~U[2026-08-11 00:00:00Z],
        "roster" => %{"Managed Care Biller" => "Sam"}
      }

      assert Codec.encode(source, context_opts(index: "posts")) == %{
               "published_at" => "2026-08-11T00:00:00Z",
               "roster" => %{"Managed Care Biller" => "Sam"}
             }
    end
  end

  describe "encode_bulk/3" do
    test "index/create/update actions are dumped, delete has no payload to dump" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{index: %{_id: "1"}},
        %{published_at: ~U[2026-08-11 00:00:00Z]},
        %{delete: %{_id: "2"}},
        %{update: %{_id: "3"}},
        %{doc: %{published_at: ~U[2026-08-11 00:00:00Z]}}
      ]

      assert [
               %{index: %{_id: "1"}},
               %{published_at: "2026-08-11T00:00:00Z"},
               %{delete: %{_id: "2"}},
               %{update: %{_id: "3"}},
               %{doc: %{published_at: "2026-08-11T00:00:00Z"}}
             ] = encode_bulk(operations, index: "posts")
    end

    test "an update action's upsert source is dumped too" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{"update" => %{"_id" => "1"}},
        %{
          "doc" => %{"published_at" => ~U[2026-08-11 00:00:00Z]},
          "upsert" => %{"published_at" => ~U[2026-08-12 00:00:00Z]}
        }
      ]

      assert [
               _header,
               %{
                 "doc" => %{"published_at" => "2026-08-11T00:00:00Z"},
                 "upsert" => %{"published_at" => "2026-08-12T00:00:00Z"}
               }
             ] = encode_bulk(operations, index: "posts")
    end

    test "a scripted update payload has nothing to dump" do
      HTTPStub.start_mapping_cacher!(@mapping)

      operations = [
        %{"update" => %{"_id" => "1"}},
        %{"script" => %{"source" => "ctx._source.views++"}}
      ]

      assert encode_bulk(operations, index: "posts") == operations
    end

    test "a per-action _index overrides the bulk-level default" do
      other_mapping = %{"properties" => %{"ip" => %{"type" => "ip"}}}

      start_supervised!(
        {Dowser.Elasticsearch.MappingCacher,
         fetch: fn _context, index ->
           case index do
             "posts" -> {:ok, @mapping}
             "comments" -> {:ok, other_mapping}
           end
         end}
      )

      operations = [
        %{"index" => %{"_id" => "1", "_index" => "comments"}},
        %{"ip" => {127, 0, 0, 1}}
      ]

      assert [_header, %{"ip" => "127.0.0.1"}] = encode_bulk(operations, index: "posts")
    end
  end

  defp encode_bulk(operations, extra) do
    Codec.encode_bulk(operations, &Codec.encode/2, context_opts(extra))
  end
end
