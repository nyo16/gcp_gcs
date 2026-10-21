defmodule GcpGcs.ValidationTest do
  use ExUnit.Case, async: true

  alias GcpGcs.{Error, Validation}

  describe "validate_project_id/1" do
    test "accepts a non-empty string" do
      assert {:ok, "my-project"} = Validation.validate_project_id("my-project")
    end

    test "rejects empty and non-string values" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id("")
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(nil)
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(123)
    end
  end

  describe "validate_bucket/1" do
    test "accepts valid names" do
      assert {:ok, "my-bucket"} = Validation.validate_bucket("my-bucket")
      assert {:ok, "a1b"} = Validation.validate_bucket("a1b")
      assert {:ok, "my.dotted.bucket"} = Validation.validate_bucket("my.dotted.bucket")
    end

    test "rejects uppercase" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_bucket("MyBucket")
    end

    test "rejects too-short and too-long names" do
      assert {:error, %Error{}} = Validation.validate_bucket("ab")
      assert {:error, %Error{}} = Validation.validate_bucket(String.duplicate("a", 64))
    end

    test "rejects leading/trailing punctuation" do
      assert {:error, %Error{}} = Validation.validate_bucket("-bucket")
      assert {:error, %Error{}} = Validation.validate_bucket("bucket-")
      assert {:error, %Error{}} = Validation.validate_bucket(".bucket")
    end

    test "rejects a trailing newline" do
      assert {:error, %Error{}} = Validation.validate_bucket("bucket\n")
    end

    test "rejects IP addresses" do
      assert {:error, %Error{}} = Validation.validate_bucket("192.168.0.1")
    end

    test "rejects reserved 'goog' prefix and 'google' substring" do
      assert {:error, %Error{}} = Validation.validate_bucket("googfoo")
      assert {:error, %Error{}} = Validation.validate_bucket("my-google-bucket")
    end

    test "rejects non-strings" do
      assert {:error, %Error{}} = Validation.validate_bucket(nil)
    end
  end

  describe "validate_object/1" do
    test "accepts ordinary names including slashes" do
      assert {:ok, "path/to/file.txt"} = Validation.validate_object("path/to/file.txt")
      assert {:ok, "a"} = Validation.validate_object("a")
    end

    test "rejects empty names" do
      assert {:error, %Error{}} = Validation.validate_object("")
    end

    test "rejects '.' and '..'" do
      assert {:error, %Error{}} = Validation.validate_object(".")
      assert {:error, %Error{}} = Validation.validate_object("..")
    end

    test "rejects names with CR or LF" do
      assert {:error, %Error{}} = Validation.validate_object("bad\nname")
      assert {:error, %Error{}} = Validation.validate_object("bad\rname")
    end

    test "rejects names longer than 1024 bytes" do
      assert {:error, %Error{}} = Validation.validate_object(String.duplicate("a", 1025))
      assert {:ok, _} = Validation.validate_object(String.duplicate("a", 1024))
    end

    test "rejects non-strings" do
      assert {:error, %Error{}} = Validation.validate_object(123)
    end
  end

  describe "validate_source_objects/1" do
    test "accepts a non-empty list of strings or maps" do
      assert {:ok, _} = Validation.validate_source_objects(["a", "b"])
      assert {:ok, _} = Validation.validate_source_objects([%{name: "a"}, %{"name" => "b"}])
    end

    test "rejects empty lists and bad entries" do
      assert {:error, %Error{}} = Validation.validate_source_objects([])
      assert {:error, %Error{}} = Validation.validate_source_objects([%{bad: "x"}])
      assert {:error, %Error{}} = Validation.validate_source_objects("nope")
    end
  end

  describe "validate_binary/2" do
    test "accepts binaries" do
      assert {:ok, "data"} = Validation.validate_binary("data", "data")
      assert {:ok, ""} = Validation.validate_binary("", "data")
    end

    test "rejects non-binaries" do
      assert {:error, %Error{}} = Validation.validate_binary(123, "data")
    end
  end

  # The matchers are hand-written binary matching; these compare them with
  # the grammar they implement, written as anchored regexes, over every
  # string up to a few characters from alphabets of the boundary characters.
  describe "agrees with the reference grammar" do
    @bucket_grammar ~r/\A[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]\z/
    @ip_grammar ~r/\A\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\z/

    test "bucket names, including IP-shaped ones" do
      candidates =
        strings(~c"a0._-A\n", 0..5) ++
          strings(~c"19.", 7..9) ++
          [
            String.duplicate("a", 63),
            String.duplicate("a", 64),
            "a" <> String.duplicate("_", 61) <> "a"
          ]

      for name <- candidates do
        expected =
          cond do
            not Regex.match?(@bucket_grammar, name) -> :bad_name
            Regex.match?(@ip_grammar, name) -> :ip
            true -> :other
          end

        actual =
          case Validation.validate_bucket(name) do
            {:error, %Error{message: "bucket must be 3-63" <> _}} -> :bad_name
            {:error, %Error{message: "bucket must not be an IP address"}} -> :ip
            _ -> :other
          end

        assert actual == expected, "bucket #{inspect(name)}: #{actual}, expected #{expected}"
      end
    end

    test "control characters in object names" do
      for name <- strings([?a, 0x00, 0x1F, 0x20, 0x7F], 1..4), name not in [".", ".."] do
        control? = Regex.match?(~r/[\x00-\x1F]/, name)

        assert match?(
                 {:error, %Error{message: "object name must not contain control" <> _}},
                 Validation.validate_object(name)
               ) ==
                 control?,
               "object #{inspect(name)}"
      end
    end

    test "header values" do
      for value <- strings([?a, ?\s, 0x1F, 0x7E, 0x7F, ?\n], 0..4) do
        assert match?({:ok, _}, Validation.validate_header_value(value, ":origin")) ==
                 Regex.match?(~r/\A[\x20-\x7E]+\z/, value),
               "header value #{inspect(value)}"
      end
    end

    test "the persisted range of a 308" do
      for prefix <- ["bytes=0-", "0-", " bytes=0-", "bytes=1-", "BYTES=0-"],
          suffix <- strings(~c"09+- x\n", 0..3) do
        value = prefix <> suffix

        expected =
          case Regex.run(~r/\A(?:bytes=)?0-(\d+)\z/, String.trim(value)) do
            [_, last] -> {:ok, String.to_integer(last) + 1}
            nil -> :error
          end

        assert GcpGcs.Upload.next_offset([{"range", value}]) == expected,
               "range #{inspect(value)}"
      end
    end
  end

  # Every string over `alphabet` whose length is in `lengths`.
  defp strings(alphabet, lengths) do
    Enum.flat_map(lengths, fn n -> Enum.reduce(1..n//1, [""], &extend(&2, alphabet, &1)) end)
  end

  defp extend(prefixes, alphabet, _step), do: for(s <- prefixes, c <- alphabet, do: s <> <<c>>)
end
