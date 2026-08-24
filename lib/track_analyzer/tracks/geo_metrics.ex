defmodule TrackAnalyzer.Tracks.GeoMetrics do
  @moduledoc false

  @earth_radius_m 6_371_008.8

  def distance_m(%{latitude: lat1, longitude: lon1}, %{latitude: lat2, longitude: lon2}) do
    latitude_delta = radians(lat2 - lat1)
    longitude_delta = radians(lon2 - lon1)

    a =
      :math.sin(latitude_delta / 2) ** 2 +
        :math.cos(radians(lat1)) * :math.cos(radians(lat2)) *
          :math.sin(longitude_delta / 2) ** 2

    @earth_radius_m * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  def bearing_degrees(%{latitude: lat1, longitude: lon1}, %{latitude: lat2, longitude: lon2}) do
    longitude_delta = radians(lon2 - lon1)
    y = :math.sin(longitude_delta) * :math.cos(radians(lat2))

    x =
      :math.cos(radians(lat1)) * :math.sin(radians(lat2)) -
        :math.sin(radians(lat1)) * :math.cos(radians(lat2)) *
          :math.cos(longitude_delta)

    (:math.atan2(y, x) * 180 / :math.pi() + 360)
    |> :math.fmod(360)
  end

  defp radians(degrees), do: degrees * :math.pi() / 180
end
