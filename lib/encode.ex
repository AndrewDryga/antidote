defmodule Antidote.EncodeError do
  defexception [:message]

  def exception(message) when is_binary(message) do
    %__MODULE__{message: message}
  end
  def exception({:duplicate_key, key}) do
    %__MODULE__{message: "duplicate key: #{key}"}
  end
  def exception({:invalid_byte, byte, original}) do
    %__MODULE__{message: "invalid byte #{inspect byte, base: :hex} in #{inspect original}"}
  end
end

defmodule Antidote.Encode do
  @moduledoc false

  import Bitwise

  alias Antidote.{Codegen, EncodeError}

  # @compile :native

  def encode(value, opts) do
    escape = escape_function(opts)
    encode_map = encode_map_function(opts)
    try do
      {:ok, encode_dispatch(value, escape, encode_map, opts)}
    rescue
      e in EncoderError ->
        {:error, e}
    end
  end

  def encode_map_function(%{maps: maps}) do
    case maps do
      :naive -> &encode_map_naive/4
      :strict -> &encode_map_strict/4
    end
  end

  def escape_function(%{escape: escape}) do
    case escape do
      :json -> &escape_json/4
      :unicode -> &escape_unicode/4
      :html_safe -> &escape_html/4
      :javascript -> &escape_javascript/4
      _ -> fn _,_,_,_ -> raise "not supported" end
    end
  end

  def encode_dispatch(value, escape, _encode_map, _opts) when is_atom(value) do
    do_encode_atom(value, escape)
  end

  def encode_dispatch(value, escape, _encode_map, _opts) when is_binary(value) do
    do_encode_string(value, escape)
  end

  def encode_dispatch(value, _escape, _encode_map, _opts) when is_integer(value) do
    encode_integer(value)
  end

  def encode_dispatch(value, _escape, _encode_map, _opts) when is_float(value) do
    encode_float(value)
  end

  def encode_dispatch(value, escape, encode_map, opts) when is_list(value) do
    encode_list(value, escape, encode_map, opts)
  end

  def encode_dispatch(%{__struct__: module} = value, _escape, _encode_map, opts) do
    encode_struct(value, opts, module)
  end

  def encode_dispatch(value, escape, encode_map, opts) when is_map(value) do
    encode_map.(value, escape, encode_map, opts)
  end

  def encode_dispatch(value, _escape, _encode_map, opts) do
    case Antidote.Encoder.encode(value, opts) do
      %Antidote.Fragment{iodata: iodata} -> iodata
      iodata when is_list(iodata) or is_binary(iodata) -> iodata
    end
  end

  # @compile {:inline,
  #           do_encode_atom: 2, do_encode_string: 2, encode_integer: 1,
  #           encode_float: 1, encode_list: 4, encode_struct: 3}
  @compile {:inline, encode_integer: 1, encode_float: 1}

  def encode_atom(atom, opts) do
    escape = escape_function(opts)
    do_encode_atom(atom, escape)
  end

  defp do_encode_atom(nil, _escape), do: "null"
  defp do_encode_atom(true, _escape), do: "true"
  defp do_encode_atom(false, _escape), do: "false"
  defp do_encode_atom(atom, escape),
    do: do_encode_string(Atom.to_string(atom), escape)

  def encode_integer(integer) do
    Integer.to_string(integer)
  end

  def encode_float(float) do
    :io_lib_format.fwrite_g(float)
  end

  def encode_list(list, opts) do
    escape = escape_function(opts)
    encode_map = encode_map_function(opts)
    encode_list(list, escape, encode_map, opts)
  end

  defp encode_list([], _escape, _encode_map, _opts) do
    "[]"
  end

  defp encode_list([head | tail], escape, encode_map, opts) do
    [?[, encode_dispatch(head, escape, encode_map, opts)
     | encode_list_loop(tail, escape, encode_map, opts)]
  end

  defp encode_list_loop([], _escape, _encode_map, _opts) do
    ']'
  end

  defp encode_list_loop([head | tail], escape, encode_map, opts) do
    [?,, encode_dispatch(head, escape, encode_map, opts)
     | encode_list_loop(tail, escape, encode_map, opts)]
  end

  def encode_map(value, opts) do
    escape = escape_function(opts)
    encode_map = encode_map_function(opts)
    encode_map.(value, escape, encode_map, opts)
  end

  defp encode_map_naive(value, escape, encode_map, opts) do
    case Map.to_list(value) do
      [] -> "{}"
      [{key, value} | tail] ->
        ["{\"", encode_key(key, escape), "\":",
         encode_dispatch(value, escape, encode_map, opts)
         | encode_map_naive_loop(tail, escape, encode_map, opts)]
    end
  end

  defp encode_map_naive_loop([], _escape, _encode_map, _opts) do
    '}'
  end

  defp encode_map_naive_loop([{key, value} | tail], escape, encode_map, opts) do
    [",\"", encode_key(key, escape), "\":",
     encode_dispatch(value, escape, encode_map, opts)
     | encode_map_naive_loop(tail, escape, encode_map, opts)]
  end

  defp encode_map_strict(value, escape, encode_map, opts) do
    case Map.to_list(value) do
      [] -> "{}"
      [{key, value} | tail] ->
        key = IO.iodata_to_binary(encode_key(key, escape))
        visited = %{key => []}
        ["{\"", key, "\":",
         encode_dispatch(value, escape, encode_map, opts)
         | encode_map_strict_loop(tail, escape, encode_map, opts, visited)]
    end
  end

  defp encode_map_strict_loop([], _encode_map, _escape, _opts, _visited) do
    '}'
  end

  defp encode_map_strict_loop([{key, value} | tail], escape, encode_map, opts, visited) do
    key = IO.iodata_to_binary(encode_key(key, escape))
    case visited do
      %{^key => _} ->
        encode_error({:duplicate_key, key})
      _ ->
        visited = Map.put(visited, key, [])
        [",\"", key, "\":",
         encode_dispatch(value, escape, encode_map, opts)
         | encode_map_strict_loop(tail, escape, encode_map, opts, visited)]
    end
  end

  for module <- [Date, Time, NaiveDateTime, DateTime] do
    defp encode_struct(value, _opts, unquote(module)) do
      [?\", unquote(module).to_iso8601(value), ?\"]
    end
  end

  defp encode_struct(value, _opts, Decimal) do
    # silence the xref warning
    decimal = Decimal
    [?\", decimal.to_string(value, :normal), ?\"]
  end

  defp encode_struct(value, _opts, Antidote.Fragment) do
    Map.fetch!(value, :iodata)
  end

  defp encode_struct(value, opts, _module) do
    case Antidote.Encoder.encode(value, opts) do
      %Antidote.Fragment{iodata: iodata} -> iodata
      iodata when is_list(iodata) or is_binary(iodata) -> iodata
    end
  end

  def encode_key(atom, escape) when is_atom(atom) do
    string = Atom.to_string(atom)
    escape.(string, string, 0, [])
  end
  def encode_key(string, escape) when is_binary(string) do
    escape.(string, string, 0, [])
  end
  def encode_key(other, escape) do
    string = String.Chars.to_string(other)
    escape.(string, string, 0, [])
  end

  def encode_string(string, opts) do
    escape = escape_function(opts)
    do_encode_string(string, escape)
  end

  defp do_encode_string(string, escape) do
    [?\" | escape.(string, string, 0, '"')]
  end

  slash_escapes = Enum.zip('\b\t\n\f\r\"\\', 'btnfr"\\')
  surogate_escapes = Enum.zip([0x2028, 0x2029], ["\\u2028", "\\u2029"])
  ranges = [{0x00..0x1F, :unicode} | slash_escapes]
  html_ranges = [{0x00..0x1F, :unicode}, {?/, ?/} | slash_escapes]
  escape_jt = Codegen.jump_table(html_ranges, :error)

  Enum.each(escape_jt, fn
    {byte, :unicode} ->
      sequence = List.to_string(:io_lib.format("\\u~4.16.0B", [byte]))
      defp escape(unquote(byte)), do: unquote(sequence)
    {byte, char} when is_integer(char) ->
      defp escape(unquote(byte)), do: unquote(<<?\\, char>>)
    {byte, :error} ->
      defp escape(unquote(byte)), do: throw(:error)
  end)

  ## regular JSON escape

  json_jt = Codegen.jump_table(ranges, :chunk, 0x7F + 1)

  defp escape_json(data, original, skip, tail) do
    escape_json(data, [], original, skip, tail)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_json(<<byte, rest::bits>>, acc, original, skip, tail)
           when byte === unquote(byte) do
        escape_json_chunk(rest, acc, original, skip, tail, 1)
      end
    {byte, _escape} ->
      defp escape_json(<<byte, rest::bits>>, acc, original, skip, tail)
           when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_json(rest, acc, original, skip + 1, tail)
      end
  end)
  defp escape_json(<<char::utf8, rest::bits>>, acc, original, skip, tail)
       when char <= 0x7FF do
    escape_json_chunk(rest, acc, original, skip, tail, 2)
  end
  defp escape_json(<<char::utf8, rest::bits>>, acc, original, skip, tail)
       when char <= 0xFFFF do
    escape_json_chunk(rest, acc, original, skip, tail, 3)
  end
  defp escape_json(<<_char::utf8, rest::bits>>, acc, original, skip, tail) do
    escape_json_chunk(rest, acc, original, skip, tail, 4)
  end
  defp escape_json(<<>>, acc, _original, _skip, tail) do
    [acc | tail]
  end
  defp escape_json(<<byte, _rest::bits>>, _acc, original, _skip, _close) do
    encode_error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_json_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
           when byte === unquote(byte) do
        escape_json_chunk(rest, acc, original, skip, tail, len + 1)
      end
    {byte, _escape} ->
      defp escape_json_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
           when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_json(rest, acc, original, skip + len + 1, tail)
      end
  end)
  defp escape_json_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
       when char <= 0x7FF do
    escape_json_chunk(rest, acc, original, skip, tail, len + 2)
  end
  defp escape_json_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
       when char <= 0xFFFF do
    escape_json_chunk(rest, acc, original, skip, tail, len + 3)
  end
  defp escape_json_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, tail, len) do
    escape_json_chunk(rest, acc, original, skip, tail, len + 4)
  end
  defp escape_json_chunk(<<>>, acc, original, skip, tail, len) do
    part = binary_part(original, skip, len)
    [acc, part | tail]
  end
  defp escape_json_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _close, _len) do
    encode_error({:invalid_byte, byte, original})
  end

  ## javascript safe JSON escape

  defp escape_javascript(data, original, skip, tail) do
    escape_javascript(data, [], original, skip, tail)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_javascript(<<byte, rest::bits>>, acc, original, skip, tail)
            when byte === unquote(byte) do
        escape_javascript_chunk(rest, acc, original, skip, tail, 1)
      end
    {byte, _escape} ->
      defp escape_javascript(<<byte, rest::bits>>, acc, original, skip, tail)
            when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_javascript(rest, acc, original, skip + 1, tail)
      end
  end)
  defp escape_javascript(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0x7FF do
    escape_javascript_chunk(rest, acc, original, skip, tail, 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_javascript(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, tail) do
      acc = [acc | unquote(escape)]
      escape_javascript(rest, acc, original, skip + 3, tail)
    end
  end)
  defp escape_javascript(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0xFFFF do
    escape_javascript_chunk(rest, acc, original, skip, tail, 3)
  end
  defp escape_javascript(<<_char::utf8, rest::bits>>, acc, original, skip, tail) do
    escape_javascript_chunk(rest, acc, original, skip, tail, 4)
  end
  defp escape_javascript(<<>>, acc, _original, _skip, tail) do
    [acc | tail]
  end
  defp escape_javascript(<<byte, _rest::bits>>, _acc, original, _skip, _close) do
    encode_error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_javascript_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        escape_javascript_chunk(rest, acc, original, skip, tail, len + 1)
      end
    {byte, _escape} ->
      defp escape_javascript_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_javascript(rest, acc, original, skip + len + 1, tail)
      end
  end)
  defp escape_javascript_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0x7FF do
    escape_javascript_chunk(rest, acc, original, skip, tail, len + 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_javascript(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, tail) do
      acc = [acc | unquote(escape)]
      escape_javascript(rest, acc, original, skip + 3, tail)
    end
  end)
  defp escape_javascript_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0xFFFF do
    escape_javascript_chunk(rest, acc, original, skip, tail, len + 3)
  end
  defp escape_javascript_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, tail, len) do
    escape_javascript_chunk(rest, acc, original, skip, tail, len + 4)
  end
  defp escape_javascript_chunk(<<>>, acc, original, skip, tail, len) do
    part = binary_part(original, skip, len)
    [acc, part | tail]
  end
  defp escape_javascript_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _close, _len) do
    encode_error({:invalid_byte, byte, original})
  end

  ## HTML safe JSON escape

  html_jt = Codegen.jump_table(html_ranges, :chunk, 0x7F + 1)

  defp escape_html(data, original, skip, tail) do
    escape_html(data, [], original, skip, tail)
  end

  Enum.map(html_jt, fn
    {byte, :chunk} ->
      defp escape_html(<<byte, rest::bits>>, acc, original, skip, tail)
            when byte === unquote(byte) do
        escape_html_chunk(rest, acc, original, skip, tail, 1)
      end
    {byte, _escape} ->
      defp escape_html(<<byte, rest::bits>>, acc, original, skip, tail)
            when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_html(rest, acc, original, skip + 1, tail)
      end
  end)
  defp escape_html(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0x7FF do
    escape_html_chunk(rest, acc, original, skip, tail, 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_html(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, tail) do
      acc = [acc | unquote(escape)]
      escape_html(rest, acc, original, skip + 3, tail)
    end
  end)
  defp escape_html(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0xFFFF do
    escape_html_chunk(rest, acc, original, skip, tail, 3)
  end
  defp escape_html(<<_char::utf8, rest::bits>>, acc, original, skip, tail) do
    escape_html_chunk(rest, acc, original, skip, tail, 4)
  end
  defp escape_html(<<>>, acc, _original, _skip, tail) do
    [acc | tail]
  end
  defp escape_html(<<byte, _rest::bits>>, _acc, original, _skip, _close) do
    encode_error({:invalid_byte, byte, original})
  end

  Enum.map(html_jt, fn
    {byte, :chunk} ->
      defp escape_html_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        escape_html_chunk(rest, acc, original, skip, tail, len + 1)
      end
    {byte, _escape} ->
      defp escape_html_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_html(rest, acc, original, skip + len + 1, tail)
      end
  end)
  defp escape_html_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0x7FF do
    escape_html_chunk(rest, acc, original, skip, tail, len + 2)
  end
  Enum.map(surogate_escapes, fn {byte, escape} ->
    defp escape_html(<<unquote(byte)::utf8, rest::bits>>, acc, original, skip, tail) do
      acc = [acc | unquote(escape)]
      escape_html(rest, acc, original, skip + 3, tail)
    end
  end)
  defp escape_html_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0xFFFF do
    escape_html_chunk(rest, acc, original, skip, tail, len + 3)
  end
  defp escape_html_chunk(<<_char::utf8, rest::bits>>, acc, original, skip, tail, len) do
    escape_html_chunk(rest, acc, original, skip, tail, len + 4)
  end
  defp escape_html_chunk(<<>>, acc, original, skip, tail, len) do
    part = binary_part(original, skip, len)
    [acc, part | tail]
  end
  defp escape_html_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _close, _len) do
    encode_error({:invalid_byte, byte, original})
  end

  ## unicode escape

  defp escape_unicode(data, original, skip, tail) do
    escape_unicode(data, [], original, skip, tail)
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_unicode(<<byte, rest::bits>>, acc, original, skip, tail)
           when byte === unquote(byte) do
        escape_unicode_chunk(rest, acc, original, skip, tail, 1)
      end
    {byte, _escape} ->
      defp escape_unicode(<<byte, rest::bits>>, acc, original, skip, tail)
           when byte === unquote(byte) do
        acc = [acc | escape(byte)]
        escape_unicode(rest, acc, original, skip + 1, tail)
      end
  end)
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip, tail)
       when char <= 0xFF do
    acc = [acc, "\\u00" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 2, tail)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0x7FF do
    acc = [acc, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 2, tail)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip, tail)
        when char <= 0xFFFF do
    acc = [acc, "\\u" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + 3, tail)
  end
  defp escape_unicode(<<char::utf8, rest::bits>>, acc, original, skip, tail) do
    char = char - 0x10000
    acc =
      [
        acc,
        "\\uD", Integer.to_string(0x800 ||| (char >>> 10), 16),
        "\\uD" | Integer.to_string(0xC00 ||| (char &&& 0x3FF), 16)
      ]
    escape_unicode(rest, acc, original, skip + 4, tail)
  end
  defp escape_unicode(<<>>, acc, _original, _skip, tail) do
    [acc | tail]
  end
  defp escape_unicode(<<byte, _rest::bits>>, _acc, original, _skip, _close) do
    encode_error({:invalid_byte, byte, original})
  end

  Enum.map(json_jt, fn
    {byte, :chunk} ->
      defp escape_unicode_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        escape_unicode_chunk(rest, acc, original, skip, tail, len + 1)
      end
    {byte, _escape} ->
      defp escape_unicode_chunk(<<byte, rest::bits>>, acc, original, skip, tail, len)
            when byte === unquote(byte) do
        part = binary_part(original, skip, len)
        acc = [acc, part | escape(byte)]
        escape_unicode(rest, acc, original, skip + len + 1, tail)
      end
  end)
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
       when char <= 0xFF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u00" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 2, tail)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0x7FF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u0" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 2, tail)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len)
        when char <= 0xFFFF do
    part = binary_part(original, skip, len)
    acc = [acc, part, "\\u" | Integer.to_string(char, 16)]
    escape_unicode(rest, acc, original, skip + len + 3, tail)
  end
  defp escape_unicode_chunk(<<char::utf8, rest::bits>>, acc, original, skip, tail, len) do
    part = binary_part(original, skip, len)
    acc =
      [
        acc, part,
        "\\uD", Integer.to_string(0x800 ||| (char >>> 10), 16),
        "\\uD" | Integer.to_string(0xC00 ||| (char &&& 0x3FF), 16)
      ]
    escape_unicode(rest, acc, original, skip + len + 4, tail)
  end
  defp escape_unicode_chunk(<<>>, acc, original, skip, tail, len) do
    part = binary_part(original, skip, len)
    [acc, part | tail]
  end
  defp escape_unicode_chunk(<<byte, _rest::bits>>, _acc, original, _skip, _close, _len) do
    encode_error({:invalid_byte, byte, original})
  end

  @compile {:inline, encode_error: 1}
  defp encode_error(error) do
    raise EncodeError, error
  end
end
