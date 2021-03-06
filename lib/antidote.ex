defmodule Antidote do
  @moduledoc """
  A blazing fast JSON parser and generator.
  """

  @type escape :: :json | :unicode | :html | :javascript
  @type maps :: :naive | :strict

  @type encode_opt :: {:escape, escape} | {:maps, maps}

  @type keys :: :atoms | :atoms! | :strings | :copy | (String.t() -> term)

  @type decode_opt :: {:keys, keys}

  @doc """
  Parses a JSON value from `input` iodata.

  ## Options

    * `:keys` - controls how keys in objects are decoded. Possible values are:

      * `:strings` (default) - decodes keys as binary strings,
      * `:atoms` - keys are converted to atoms using `String.to_atom/1`,
      * `:atoms!` - keys are converted to atoms using `String.to_existing_atom/1`,
      * `:copy` - decodes keys as binary strings and makes sure they don't reference
        the original binary using `:binary.copy/1`
      * custom decoder - additionally a function accepting a string and returning a key
        is accepted.

  ## Decoding keys to atoms

  The `:atoms` option uses the `String.to_atom/1` call that can create atoms at runtime.
  Since the atoms are not garbage collected, this can pose a DoS attack vector when used
  on user-controlled data.
  """
  @spec decode(iodata, [decode_opt]) :: {:ok, term} | {:error, Antidote.ParseError.t()}
  def decode(input, opts \\ []) do
    input = IO.iodata_to_binary(input)
    Antidote.Parser.parse(input, format_decode_opts(opts))
  end

  @doc """
  Parses a JSON value from `input` iodata.

  Similar to `decode/2` except it will unwrap the error tuple and raise
  in case of errors.
  """
  @spec decode!(iodata, [decode_opt]) :: term | no_return
  def decode!(input, opts \\ []) do
    case Antidote.Parser.parse(input, format_decode_opts(opts)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates JSON corresponding to `input`.

  The generation is controlled by the `Antidote.Encoder` protocol,
  please refer to the module to read more on how to define the protocol
  for custom data types.

  ## Options

    * `:escape` - controls how strings are encoded. Possible values are:

      * `:json` (default) - the regular JSON escaping as defined by RFC 7159.
      * `:javascript` - additionally escapes the LINE SEPARATOR (U+2028) and
        PARAGRAPH SEPARATOR (U+2029) characters to make the produced JSON
        valid JavaSciprt.
      * `:html_safe` - similar to `:javascript`, but also escapes the `/`
        caracter to prevent XSS.
      * `:unicode` - escapes all non-ascii characters.

    * `:maps` - controls how maps are encoded. Possible values are:

      * `:strict` - checks the encoded map for duplicate keys and raises
        if they appear. For example `%{:foo => 1, "foo" => 2}` would be
        rejected, since both keys would be encoded to the string `"foo"`.
      * `:naive` (default) - does not perform the check.
  """
  @spec encode(term, [encode_opt]) :: {:ok, String.t()} | {:error, Antidote.EncodeError.t()}
  def encode(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> {:ok, IO.iodata_to_binary(result)}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Generates JSON corresponding to `input`.

  Similar to `encode/1` except it will unwrap the error tuple and raise
  in case of errors.
  """
  @spec encode!(term, [encode_opt]) :: String.t() | no_return
  def encode!(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> IO.iodata_to_binary(result)
      {:error, error} -> raise error
    end
  end

  @doc """
  Generates JSON corresponding to `input` and returns iodata.

  This function should be preferred to `encode/2`, if the generated
  JSON will be handed over to one of the IO functions or sent
  over the socket. The Erlang runtime is able to leverage vectorised
  writes and avoid allocating a continuous buffer for the whole
  resulting string, lowering memory use and increasing performance.
  """
  @spec encode_to_iodata(term, [encode_opt]) :: {:ok, iodata} | {:error, Antidote.EncodeError.t()}
  def encode_to_iodata(input, opts \\ []) do
    Antidote.Encode.encode(input, format_encode_opts(opts))
  end

  @doc """
  Generates JSON corresponding to `input` and returns iodata.

  Similar to `encode_to_iodata/1` except it will unwrap the error tuple
  and raise in case of errors.
  """
  @spec encode_to_iodata!(term, [encode_opt]) :: iodata | no_return
  def encode_to_iodata!(input, opts \\ []) do
    case Antidote.Encode.encode(input, format_encode_opts(opts)) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp format_encode_opts(opts) do
    Enum.into(opts, %{escape: :json, maps: :naive})
  end

  defp format_decode_opts(opts) do
    Enum.into(opts, %{keys: :strings})
  end
end
