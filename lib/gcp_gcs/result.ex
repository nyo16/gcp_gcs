defmodule GcpGcs.Result do
  @moduledoc false
  # Shared helpers for shaping `GcpGcs.Client` results. Keeps response handling
  # consistent across `GcpGcs.Bucket` and `GcpGcs.Object`.

  alias GcpGcs.Error

  @type t :: {:ok, term()} | {:error, Error.t()}

  @doc "Discards a successful body, returning `:ok`. Passes errors through."
  @spec as_ok(t()) :: :ok | {:error, Error.t()}
  def as_ok({:ok, _}), do: :ok
  def as_ok({:error, %Error{}} = error), do: error

  @doc """
  Shapes a paginated list response into `%{items: [...], next_page_token: token}`.

  `items_key` is the JSON field holding the list (e.g. `"items"`); missing keys
  default to `[]` / `nil`.
  """
  @spec list(t(), String.t()) ::
          {:ok, %{items: list(), next_page_token: String.t() | nil}} | {:error, Error.t()}
  def list({:ok, body}, items_key) when is_map(body) do
    {:ok,
     %{
       items: Map.get(body, items_key, []),
       prefixes: Map.get(body, "prefixes", []),
       next_page_token: Map.get(body, "nextPageToken")
     }}
  end

  def list({:ok, _body}, _items_key) do
    {:ok, %{items: [], prefixes: [], next_page_token: nil}}
  end

  def list({:error, %Error{}} = error, _items_key), do: error

  @doc """
  A lazy stream of list items, fetching a page with `fetch.(page_token)` only
  when needed, starting from `first_token` (`nil` for the first page). Raises
  the `GcpGcs.Error` of a failed page.
  """
  @spec stream_pages(String.t() | nil, (String.t() | nil -> {:ok, map()} | {:error, Error.t()})) ::
          Enumerable.t()
  def stream_pages(first_token, fetch) do
    Stream.resource(
      fn -> {:next, first_token} end,
      fn
        :done ->
          {:halt, :done}

        {:next, token} ->
          case fetch.(token) do
            {:ok, %{items: items, next_page_token: nil}} -> {items, :done}
            {:ok, %{items: items, next_page_token: next}} -> {items, {:next, next}}
            {:error, %Error{} = error} -> raise error
          end
      end,
      fn _ -> :ok end
    )
  end
end
