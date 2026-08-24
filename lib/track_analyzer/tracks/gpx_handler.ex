defmodule TrackAnalyzer.Tracks.GPXHandler do
  @behaviour Saxy.Handler

  @max_points 500_000

  def initial_state do
    %{
      stack: [],
      text: "",
      creator: nil,
      name: nil,
      track_position: -1,
      segment_position: -1,
      current_point: nil,
      point_count: 0,
      points: [],
      segments: [],
      warnings: []
    }
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}
  def handle_event(:end_document, _data, state), do: {:ok, state}

  def handle_event(:start_element, {name, attributes}, state) do
    local_name = local_name(name)
    state = %{state | stack: [local_name | state.stack], text: ""}

    case local_name do
      "gpx" ->
        {:ok, %{state | creator: attribute(attributes, "creator")}}

      "trk" ->
        {:ok,
         %{
           state
           | track_position: state.track_position + 1,
             segment_position: -1
         }}

      "trkseg" ->
        segment_position = state.segment_position + 1

        segment = %{
          track_position: max(state.track_position, 0),
          position: segment_position
        }

        {:ok,
         %{
           state
           | segment_position: segment_position,
             segments: [segment | state.segments]
         }}

      "trkpt" ->
        point = %{
          track_position: max(state.track_position, 0),
          segment_position: max(state.segment_position, 0),
          latitude: attribute(attributes, "lat"),
          longitude: attribute(attributes, "lon"),
          elevation_m: nil,
          recorded_at: nil,
          hdop: nil,
          recorded_speed_mps: nil,
          extras: %{}
        }

        {:ok, %{state | current_point: point}}

      _other ->
        {:ok, state}
    end
  end

  def handle_event(:characters, chars, state), do: {:ok, %{state | text: state.text <> chars}}
  def handle_event(:cdata, chars, state), do: {:ok, %{state | text: state.text <> chars}}

  def handle_event(:end_element, name, state) do
    local_name = local_name(name)
    text = String.trim(state.text)
    state = capture_value(local_name, text, state)
    stack = drop_current(state.stack, local_name)
    state = %{state | stack: stack, text: ""}

    case local_name do
      "trkpt" when state.point_count >= @max_points ->
        {:stop, {:error, :too_many_points}}

      "trkpt" ->
        {:ok,
         %{
           state
           | points: [state.current_point | state.points],
             point_count: state.point_count + 1,
             current_point: nil
         }}

      _other ->
        {:ok, state}
    end
  end

  defp capture_value("name", text, state) do
    if state.name == nil and "metadata" in state.stack and text != "" do
      %{state | name: text}
    else
      state
    end
  end

  defp capture_value("ele", text, %{current_point: point} = state) when not is_nil(point) do
    %{state | current_point: Map.put(point, :elevation_m, parse_float(text))}
  end

  defp capture_value("time", text, %{current_point: point} = state) when not is_nil(point) do
    %{state | current_point: Map.put(point, :recorded_at, parse_datetime(text))}
  end

  defp capture_value("hdop", text, %{current_point: point} = state) when not is_nil(point) do
    %{state | current_point: Map.put(point, :hdop, parse_float(text))}
  end

  defp capture_value("speed", text, %{current_point: point} = state) when not is_nil(point) do
    %{state | current_point: Map.put(point, :recorded_speed_mps, parse_float(text))}
  end

  defp capture_value(local_name, text, %{current_point: point} = state)
       when not is_nil(point) and text != "" do
    if "extensions" in state.stack do
      extras = Map.put(point.extras, local_name, text)
      %{state | current_point: %{point | extras: extras}}
    else
      state
    end
  end

  defp capture_value(_local_name, _text, state), do: state

  defp attribute(attributes, wanted) do
    Enum.find_value(attributes, fn {name, value} ->
      if local_name(name) == wanted, do: value
    end)
  end

  defp local_name(name), do: name |> String.split(":") |> List.last()

  defp drop_current([name | rest], name), do: rest
  defp drop_current(stack, _name), do: stack

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime = DateTime.shift_zone!(datetime, "Etc/UTC")
        %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}

      _other ->
        nil
    end
  end
end
