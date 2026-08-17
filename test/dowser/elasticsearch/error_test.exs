defmodule Dowser.Elasticsearch.ErrorTest do
  use ExUnit.Case, async: true

  alias Dowser.Elasticsearch.Error

  describe "new/2" do
    test "extracts :type and :reason from a standard error body" do
      body = %{"error" => %{"type" => "index_not_found_exception", "reason" => "no such index"}}

      assert %Error{
               status: 404,
               body: ^body,
               type: "index_not_found_exception",
               reason: "no such index"
             } =
               Error.new(404, body)
    end

    test "treats a plain string error as the reason, with no type" do
      body = %{"error" => "boom"}
      assert %Error{status: 500, type: nil, reason: "boom"} = Error.new(500, body)
    end

    test "leaves :type and :reason nil when the body has no :error key" do
      body = %{"message" => "boom"}
      assert %Error{status: 500, type: nil, reason: nil} = Error.new(500, body)
    end
  end

  describe "message/1" do
    test "includes both type and reason when present" do
      error = Error.new(404, %{"error" => %{"type" => "not_found", "reason" => "missing"}})

      assert Exception.message(error) ==
               "Elasticsearch responded with HTTP 404: [not_found] missing"
    end

    test "includes only the reason when there is no type" do
      error = Error.new(500, %{"error" => "boom"})
      assert Exception.message(error) == "Elasticsearch responded with HTTP 500: boom"
    end

    test "includes only the type when there is no reason" do
      error = Error.new(400, %{"error" => %{"type" => "bad_request"}})
      assert Exception.message(error) == "Elasticsearch responded with HTTP 400: [bad_request]"
    end

    test "falls back to just the status when neither is present" do
      error = Error.new(503, %{})
      assert Exception.message(error) == "Elasticsearch responded with HTTP 503"
    end
  end
end
