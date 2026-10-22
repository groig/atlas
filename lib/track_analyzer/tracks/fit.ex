defmodule TrackAnalyzer.Tracks.FIT do
  @moduledoc """
  Pure-Elixir reader for FIT activity files (bike computers, watches, phone apps).

  Only the messages the analyzer needs are decoded: `file_id`, `sport`, `session`
  and `record`. Everything else is skipped by size. The result has the same shape
  as `TrackAnalyzer.Tracks.GPX.parse_file/1`, so the rest of the pipeline does not
  care where a track came from.

  Damaged files are read as far as possible: a bad CRC or a truncated tail
  becomes a warning, not a failure, because crashed recordings are common.
  """

  import Bitwise

  alias TrackAnalyzer.Tracks.{HeartRate, Sensors}

  @max_bytes 64 * 1024 * 1024
  @max_points 500_000
  # Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z).
  @fit_epoch 631_065_600
  @semicircles_to_degrees 180 / 2_147_483_648

  @file_id 0
  @session 18
  @record 20
  @sport 12
  @wanted [@file_id, @session, @record, @sport]

  @crc_table {0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, 0xA001, 0x6C00,
              0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400}

  @doc "True when the binary starts with a FIT file header."
  def fit?(<<size, _protocol, _profile::16, _data_size::32, ".FIT", _rest::binary>>)
      when size in [12, 14],
      do: true

  def fit?(_binary), do: false

  def parse_file(path) do
    with {:ok, binary} <- read_file(path),
         {:ok, decoded} <- decode(binary) do
      normalize(decoded)
    end
  end

  defp read_file(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         true <- size <= @max_bytes || {:error, :fit_file_too_large},
         {:ok, binary} <- File.read(path) do
      {:ok, binary}
    else
      {:error, :fit_file_too_large} = error -> error
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  @doc """
  Decodes the wanted messages from a FIT binary.

  Returns `{:ok, %{messages: [{global_number, fields}], warnings: [String.t()]}}`
  with messages in file order and `fields` keyed by field number.
  """
  def decode(binary) when is_binary(binary) do
    if fit?(binary) do
      decode_files(binary, [], [], 0)
    else
      {:error, :not_a_fit_file}
    end
  end

  # A FIT file may contain several FIT files chained back to back.
  defp decode_files(binary, messages, warnings, file_index) do
    <<header_size, _protocol, _profile::little-16, data_size::little-32, ".FIT", _rest::binary>> =
      binary

    <<header::binary-size(header_size), body::binary>> = binary
    warnings = check_header_crc(header, warnings)

    {data, tail, warnings} =
      if byte_size(body) >= data_size do
        <<data::binary-size(data_size), tail::binary>> = body
        {data, tail, warnings}
      else
        {body, <<>>, ["The FIT file is truncated; the readable part was imported." | warnings]}
      end

    warnings = check_file_crc(header, data, tail, warnings)
    state = %{definitions: %{}, timestamp: nil, messages: messages, records: 0}

    case read_messages(data, state) do
      {:ok, state} ->
        continue_chain(tail, state.messages, warnings, file_index)

      {:partial, state, reason} ->
        warnings = ["Stopped reading a damaged FIT section (#{reason})." | warnings]

        if state.messages == [] do
          {:error, {:invalid_fit, reason}}
        else
          {:ok, %{messages: Enum.reverse(state.messages), warnings: Enum.reverse(warnings)}}
        end
    end
  end

  defp continue_chain(<<_crc::binary-size(2), rest::binary>>, messages, warnings, index) do
    if fit?(rest),
      do: decode_files(rest, messages, warnings, index + 1),
      else: {:ok, %{messages: Enum.reverse(messages), warnings: Enum.reverse(warnings)}}
  end

  defp continue_chain(_tail, messages, warnings, _index),
    do: {:ok, %{messages: Enum.reverse(messages), warnings: Enum.reverse(warnings)}}

  defp check_header_crc(<<prefix::binary-size(12), crc::little-16>>, warnings)
       when crc != 0 do
    if crc(prefix) == crc,
      do: warnings,
      else: ["The FIT header checksum does not match." | warnings]
  end

  defp check_header_crc(_header, warnings), do: warnings

  defp check_file_crc(header, data, <<crc::little-16, _rest::binary>>, warnings) do
    if crc(header <> data) == crc,
      do: warnings,
      else: ["The FIT file checksum does not match; values may be damaged." | warnings]
  end

  defp check_file_crc(_header, _data, _tail, warnings), do: warnings

  defp read_messages(<<>>, state), do: {:ok, state}

  # Definition message.
  defp read_messages(<<0::1, 1::1, developer::1, _reserved::1, local::4, rest::binary>>, state) do
    case read_definition(rest, developer == 1) do
      {:ok, definition, rest} ->
        read_messages(rest, put_in(state.definitions[local], definition))

      :error ->
        {:partial, state, "incomplete definition"}
    end
  end

  # Normal data message.
  defp read_messages(<<0::1, 0::1, _reserved::2, local::4, rest::binary>>, state),
    do: read_data(local, nil, rest, state)

  # Compressed-timestamp data message.
  defp read_messages(<<1::1, local::2, offset::5, rest::binary>>, state),
    do: read_data(local, offset, rest, state)

  defp read_definition(
         <<_reserved, architecture, rest::binary>>,
         developer?
       ) do
    endian = if architecture == 1, do: :big, else: :little

    with {:ok, global, <<count, rest::binary>>} <- read_global(rest, endian),
         field_bytes = count * 3,
         <<fields::binary-size(field_bytes), rest::binary>> <- rest,
         {:ok, developer_size, rest} <- read_developer_fields(rest, developer?) do
      fields = for <<number, size, base <- fields>>, do: {number, size, base}

      {:ok,
       %{
         global: global,
         endian: endian,
         fields: fields,
         size: Enum.reduce(fields, developer_size, fn {_n, size, _b}, sum -> sum + size end)
       }, rest}
    else
      _incomplete -> :error
    end
  end

  defp read_definition(_binary, _developer?), do: :error

  defp read_global(<<global::little-16, rest::binary>>, :little), do: {:ok, global, rest}
  defp read_global(<<global::big-16, rest::binary>>, :big), do: {:ok, global, rest}
  defp read_global(_binary, _endian), do: :error

  defp read_developer_fields(rest, false), do: {:ok, 0, rest}

  defp read_developer_fields(<<count, rest::binary>>, true) do
    bytes = count * 3

    case rest do
      <<fields::binary-size(bytes), rest::binary>> ->
        {:ok, Enum.sum(for(<<_number, size, _index <- fields>>, do: size)), rest}

      _incomplete ->
        :error
    end
  end

  defp read_developer_fields(_binary, true), do: :error

  defp read_data(local, offset, rest, state) do
    case Map.fetch(state.definitions, local) do
      :error ->
        {:partial, state, "data before its definition"}

      {:ok, %{size: size} = definition} when byte_size(rest) >= size ->
        <<message::binary-size(size), rest::binary>> = rest
        state = handle_message(definition, message, offset, state)

        if state.records > @max_points,
          do: {:partial, state, "more than #{@max_points} records"},
          else: read_messages(rest, state)

      {:ok, _definition} ->
        {:partial, state, "incomplete message"}
    end
  end

  defp handle_message(definition, message, offset, state) do
    keep? = definition.global in @wanted
    timestamp_field? = Enum.any?(definition.fields, &(elem(&1, 0) == 253))

    # Timestamps must be tracked on every message so compressed headers resolve.
    if keep? or timestamp_field? do
      fields = decode_fields(definition, message, keep?)

      timestamp =
        cond do
          is_integer(fields[253]) -> fields[253]
          offset != nil and is_integer(state.timestamp) -> rollover(state.timestamp, offset)
          true -> nil
        end

      state = if timestamp, do: %{state | timestamp: timestamp}, else: state

      if keep? do
        fields = if timestamp, do: Map.put(fields, 253, timestamp), else: fields

        %{
          state
          | messages: [{definition.global, fields} | state.messages],
            records: state.records + if(definition.global == @record, do: 1, else: 0)
        }
      else
        state
      end
    else
      if offset != nil and is_integer(state.timestamp),
        do: %{state | timestamp: rollover(state.timestamp, offset)},
        else: state
    end
  end

  defp rollover(previous, offset) do
    candidate = (previous &&& bnot(0x1F)) + offset
    if offset >= (previous &&& 0x1F), do: candidate, else: candidate + 0x20
  end

  defp decode_fields(definition, message, all?) do
    {fields, _rest} =
      Enum.reduce(definition.fields, {%{}, message}, fn {number, size, base}, {acc, binary} ->
        <<raw::binary-size(size), rest::binary>> = binary

        acc =
          if all? or number == 253,
            do: Map.put(acc, number, value(raw, base &&& 0x1F, definition.endian)),
            else: acc

        {acc, rest}
      end)

    fields
  end

  # Base types: invalid sentinels decode to nil, arrays are ignored.
  defp value(<<v>>, type, _endian) when type in [0, 2, 13], do: unless(v == 0xFF, do: v)
  defp value(<<v::signed>>, 1, _endian), do: unless(v == 0x7F, do: v)
  defp value(<<v>>, 10, _endian), do: unless(v == 0, do: v)
  defp value(<<_::16>> = raw, 3, endian), do: int(raw, endian, true, 0x7FFF)
  defp value(<<_::16>> = raw, 4, endian), do: int(raw, endian, false, 0xFFFF)
  defp value(<<_::16>> = raw, 11, endian), do: int(raw, endian, false, 0)
  defp value(<<_::32>> = raw, 5, endian), do: int(raw, endian, true, 0x7FFFFFFF)
  defp value(<<_::32>> = raw, 6, endian), do: int(raw, endian, false, 0xFFFFFFFF)
  defp value(<<_::32>> = raw, 12, endian), do: int(raw, endian, false, 0)
  defp value(<<_::64>> = raw, 14, endian), do: int(raw, endian, true, 0x7FFFFFFFFFFFFFFF)
  defp value(<<_::64>> = raw, 15, endian), do: int(raw, endian, false, 0xFFFFFFFFFFFFFFFF)
  defp value(<<_::64>> = raw, 16, endian), do: int(raw, endian, false, 0)
  defp value(<<_::32>> = raw, 8, endian), do: float(raw, endian)
  defp value(<<_::64>> = raw, 9, endian), do: float(raw, endian)

  defp value(raw, 7, _endian) do
    case raw |> :binary.split(<<0>>) |> hd() do
      "" -> nil
      text -> if String.valid?(text), do: text
    end
  end

  defp value(_raw, _type, _endian), do: nil

  defp int(raw, endian, signed?, invalid) do
    value = decode_int(raw, endian, signed?)
    unless value == invalid, do: value
  end

  defp decode_int(raw, :little, true) do
    bits = bit_size(raw)
    <<v::little-signed-size(bits)>> = raw
    v
  end

  defp decode_int(raw, :little, false) do
    bits = bit_size(raw)
    <<v::little-unsigned-size(bits)>> = raw
    v
  end

  defp decode_int(raw, :big, true) do
    bits = bit_size(raw)
    <<v::big-signed-size(bits)>> = raw
    v
  end

  defp decode_int(raw, :big, false) do
    bits = bit_size(raw)
    <<v::big-unsigned-size(bits)>> = raw
    v
  end

  defp float(raw, endian) do
    bits = bit_size(raw)

    case {endian, raw} do
      {:little, <<v::little-float-size(bits)>>} -> v
      {:big, <<v::big-float-size(bits)>>} -> v
      # NaN, infinity and the all-ones invalid sentinel do not match.
      _invalid -> nil
    end
  end

  defp crc(binary) do
    for <<byte <- binary>>, reduce: 0 do
      crc ->
        crc = crc_nibble(crc, byte &&& 0x0F)
        crc_nibble(crc, byte >>> 4)
    end
  end

  defp crc_nibble(crc, nibble) do
    tmp = elem(@crc_table, crc &&& 0x0F)
    crc = crc >>> 4 &&& 0x0FFF
    bxor(bxor(crc, tmp), elem(@crc_table, nibble))
  end

  # -- Normalization ---------------------------------------------------------

  defp normalize(%{messages: messages, warnings: warnings}) do
    by_type = Enum.group_by(messages, &elem(&1, 0), &elem(&1, 1))
    file_id = by_type |> Map.get(@file_id, []) |> List.first(%{})

    case file_id[0] do
      type when type in [nil, 4] ->
        records = Map.get(by_type, @record, [])
        {points, without_position, invalid} = build_points(records)
        sport = sport(by_type)

        {:ok,
         %{
           name: sport[:name],
           creator: creator(file_id),
           activity_type: activity_type(sport),
           segments: [%{track_position: 0, position: 0}],
           points: points,
           warnings: warnings,
           invalid_point_count: invalid,
           records_without_position: without_position
         }}

      type ->
        {:error, {:unsupported_fit_file_type, type}}
    end
  end

  defp build_points(records) do
    {points, without_position, invalid} =
      Enum.reduce(records, {[], 0, 0}, fn fields, {points, without, invalid} ->
        timestamp = fields[253]
        latitude = semicircles(fields[0])
        longitude = semicircles(fields[1])

        cond do
          not is_integer(timestamp) ->
            {points, without, invalid + 1}

          is_nil(latitude) or is_nil(longitude) ->
            {points, without + 1, invalid}

          latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180 ->
            {points, without, invalid + 1}

          true ->
            {[point(fields, timestamp, latitude, longitude) | points], without, invalid}
        end
      end)

    {Enum.reverse(points), without_position, invalid}
  end

  defp point(fields, timestamp, latitude, longitude) do
    cadence =
      case {fields[4], fields[53]} do
        {nil, _fraction} -> nil
        {whole, nil} -> whole
        {whole, fraction} -> whole + fraction / 128
      end

    extras =
      %{}
      |> put_present("hr", fields[3])
      |> put_present("cadence", cadence)
      |> put_present("power_w", fields[7])
      |> put_present("temperature_c", fields[13])

    %{
      track_position: 0,
      segment_position: 0,
      latitude: latitude,
      longitude: longitude,
      elevation_m: altitude(fields[78] || fields[2]),
      recorded_at: DateTime.from_unix!((timestamp + @fit_epoch) * 1_000_000, :microsecond),
      hdop: nil,
      recorded_speed_mps: nil,
      heart_rate_bpm: HeartRate.normalize(fields[3]),
      cadence_rpm: Sensors.normalize_cadence(cadence),
      sensor_speed_mps: Sensors.normalize_speed(scaled(fields[73] || fields[6], 1_000)),
      sensor_distance_m: Sensors.normalize_distance(scaled(fields[5], 100)),
      extras: extras
    }
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp semicircles(value) when is_integer(value), do: value * @semicircles_to_degrees
  defp semicircles(_value), do: nil

  defp altitude(value) when is_integer(value), do: value / 5 - 500
  defp altitude(_value), do: nil

  defp scaled(value, scale) when is_integer(value), do: value / scale
  defp scaled(_value, _scale), do: nil

  defp sport(by_type) do
    session = by_type |> Map.get(@session, []) |> List.first(%{})
    sport = by_type |> Map.get(@sport, []) |> List.first(%{})

    %{
      sport: session[5] || sport[0],
      sub_sport: session[6] || sport[1],
      name: if(is_binary(sport[3]), do: String.trim(sport[3]))
    }
  end

  # Names follow OsmAnd's activity ids where one exists, so route matching
  # keeps a FIT and a GPX recording of the same kind of ride together.
  defp activity_type(%{sport: 2, sub_sport: 7}), do: "road_cycling"
  defp activity_type(%{sport: 2, sub_sport: 8}), do: "mountain_biking"
  defp activity_type(%{sport: 2, sub_sport: 11}), do: "cyclocross"
  defp activity_type(%{sport: 2, sub_sport: 6}), do: "indoor_cycling"
  defp activity_type(%{sport: 2}), do: "cycling"
  defp activity_type(%{sport: 1}), do: "running"
  defp activity_type(%{sport: 11}), do: "walking"
  defp activity_type(%{sport: 17}), do: "hiking"
  defp activity_type(_sport), do: nil

  @manufacturers %{
    1 => "Garmin",
    32 => "Wahoo",
    255 => "Development device",
    260 => "Zwift",
    265 => "Strava",
    289 => "Hammerhead",
    294 => "Coros"
  }

  defp creator(file_id) do
    case {file_id[1], file_id[2]} do
      {nil, _product} ->
        "FIT file"

      {manufacturer, _product} when is_map_key(@manufacturers, manufacturer) ->
        "FIT · #{@manufacturers[manufacturer]}"

      {manufacturer, nil} ->
        "FIT · manufacturer #{manufacturer}"

      {manufacturer, product} ->
        "FIT · manufacturer #{manufacturer}, product #{product}"
    end
  end
end
