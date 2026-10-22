defmodule TrackAnalyzer.FITFixture do
  @moduledoc """
  Builds small, valid FIT activity files for tests: file_id, session and 1 Hz
  records with position, altitude, speed, distance, cadence and heart rate.
  """

  import Bitwise

  @fit_epoch 631_065_600
  @crc_table {0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401, 0xA001, 0x6C00,
              0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400}

  @doc """
  Options: `:count` records (default 120), `:start` DateTime, `:cadence` fun of
  index (nil = invalid), `:speed_mps` (constant), `:heart_rate` fun or nil,
  `:compressed` to write records 2.. with compressed timestamps,
  `:big_endian` for the record definition, `:corrupt_crc`, `:truncate` bytes.
  """
  def binary(options \\ []) do
    count = Keyword.get(options, :count, 120)
    start = Keyword.get(options, :start, ~U[2026-05-01 07:00:00Z])
    speed = Keyword.get(options, :speed_mps, 6.0)

    cadence =
      Keyword.get(options, :cadence, fn index -> if rem(index, 10) < 8, do: 85, else: 0 end)

    heart_rate = Keyword.get(options, :heart_rate)
    endian = if Keyword.get(options, :big_endian), do: :big, else: :little
    start_ts = DateTime.to_unix(start) - @fit_epoch

    file_id =
      definition(0, 0, :little, [{0, 1, 0x00}, {1, 2, 0x84}, {2, 2, 0x84}, {4, 4, 0x86}]) <>
        data(0, [u8(4), u16(1, :little), u16(42, :little), u32(start_ts, :little)])

    record_fields = [
      {253, 4, 0x86},
      {0, 4, 0x85},
      {1, 4, 0x85},
      {2, 2, 0x84},
      {5, 4, 0x86},
      {6, 2, 0x84},
      {3, 1, 0x02},
      {4, 1, 0x02}
    ]

    compressed_fields = tl(record_fields)

    records =
      for index <- 0..(count - 1), into: <<>> do
        # About 55.6 m of latitude per 0.0005° keeps GPS distance ≈ 6 m/s × 10 s.
        latitude = 55.0 + index * speed / 111_195
        values = record_values(index, latitude, speed, cadence, heart_rate, endian)

        cond do
          index == 0 ->
            definition(1, 20, endian, record_fields) <>
              data(1, [u32(start_ts + index, endian) | values])

          Keyword.get(options, :compressed) ->
            maybe_def =
              if index == 1, do: definition(2, 20, endian, compressed_fields), else: <<>>

            offset = rem(start_ts + index, 32)
            maybe_def <> <<1::1, 2::2, offset::5>> <> IO.iodata_to_binary(values)

          true ->
            data(1, [u32(start_ts + index, endian) | values])
        end
      end

    session =
      definition(3, 18, :little, [{253, 4, 0x86}, {2, 4, 0x86}, {5, 1, 0x00}, {6, 1, 0x00}]) <>
        data(3, [u32(start_ts + count, :little), u32(start_ts, :little), u8(2), u8(7)])

    body = file_id <> records <> session
    header = header(byte_size(body))
    crc = crc(header <> body)
    crc = if Keyword.get(options, :corrupt_crc), do: bxor(crc, 0xFFFF), else: crc
    file = header <> body <> <<crc::little-16>>

    case Keyword.get(options, :truncate) do
      nil -> file
      bytes -> binary_part(file, 0, byte_size(file) - bytes)
    end
  end

  def write!(directory, name \\ "ride.fit", options \\ []) do
    path = Path.join(directory, name)
    File.write!(path, binary(options))
    path
  end

  @doc "Parses, analyzes and persists a synthetic FIT ride as a complete track."
  def insert_track!(options \\ []) do
    alias TrackAnalyzer.Tracks
    alias TrackAnalyzer.Tracks.{Analyzer, FIT, Track}

    id = System.unique_integer([:positive])
    directory = Path.join(System.tmp_dir!(), "fit-fixture-#{id}")
    File.mkdir_p!(directory)
    path = write!(directory, "ride-#{id}.fit", options)
    {:ok, parsed} = FIT.parse_file(path)

    track =
      %Track{}
      |> Track.changeset(%{
        sha256: "synthetic-fit-#{id}",
        original_path: path,
        source_filename: "ride-#{id}.fit",
        source_format: "fit",
        name: Keyword.get(options, :name, "Sensor ride #{id}")
      })
      |> TrackAnalyzer.Repo.insert!()

    {:ok, track} = Tracks.persist_analysis(track, Analyzer.analyze(parsed))
    File.rm_rf!(directory)
    track
  end

  defp record_values(index, latitude, speed, cadence, heart_rate, endian) do
    [
      s32(round(latitude / 180 * 2_147_483_648), endian),
      s32(round(12.0 / 180 * 2_147_483_648), endian),
      u16(round((20.0 + 500) * 5), endian),
      u32(round(index * speed * 1.02 * 100), endian),
      u16(round(speed * 1.02 * 1000), endian),
      u8((heart_rate && heart_rate.(index)) || 0xFF),
      u8(cadence.(index) || 0xFF)
    ]
  end

  defp header(data_size) do
    prefix = <<14, 0x20, 2132::little-16, data_size::little-32, ".FIT">>
    prefix <> <<crc(prefix)::little-16>>
  end

  defp definition(local, global, endian, fields) do
    architecture = if endian == :big, do: 1, else: 0
    global = if endian == :big, do: <<global::big-16>>, else: <<global::little-16>>
    field_bytes = for {number, size, base} <- fields, into: <<>>, do: <<number, size, base>>

    <<0::1, 1::1, 0::1, 0::1, local::4, 0, architecture>> <>
      global <> <<length(fields)>> <> field_bytes
  end

  defp data(local, values), do: <<0::4, local::4>> <> IO.iodata_to_binary(values)

  defp u8(v), do: <<v>>
  defp u16(v, :little), do: <<v::little-16>>
  defp u16(v, :big), do: <<v::big-16>>
  defp u32(v, :little), do: <<v::little-32>>
  defp u32(v, :big), do: <<v::big-32>>
  defp s32(v, :little), do: <<v::little-signed-32>>
  defp s32(v, :big), do: <<v::big-signed-32>>

  defp crc(binary) do
    for <<byte <- binary>>, reduce: 0 do
      crc ->
        crc = nibble(crc, byte &&& 0x0F)
        nibble(crc, byte >>> 4)
    end
  end

  defp nibble(crc, value) do
    tmp = elem(@crc_table, crc &&& 0x0F)
    crc = crc >>> 4 &&& 0x0FFF
    bxor(bxor(crc, tmp), elem(@crc_table, value))
  end
end
