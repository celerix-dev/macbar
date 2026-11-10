import CoreLocation
import Combine
import Foundation

struct WeatherSnapshot {
    let temperature: Double?
    let weatherCode: Int?
    let error: String?

    static let loading = WeatherSnapshot(temperature: nil, weatherCode: nil, error: nil)
}

final class WeatherMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var snapshot = WeatherSnapshot.loading

    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?
    private var temperatureUnit = "celsius"
    private var isEnabled = false
    private var lastLocation: CLLocation?
    private var weatherRequest: URLSessionDataTask?
    private var requestID = UUID()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func configure(isEnabled: Bool, temperatureUnit: String) {
        let wasEnabled = self.isEnabled
        let unitChanged = self.temperatureUnit != temperatureUnit
        self.temperatureUnit = temperatureUnit
        self.isEnabled = isEnabled

        guard isEnabled else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            weatherRequest?.cancel()
            weatherRequest = nil
            requestID = UUID()
            return
        }

        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
                self?.requestWeather()
            }
        }

        guard !wasEnabled || unitChanged else { return }
        if unitChanged, let lastLocation {
            fetchWeather(for: lastLocation)
        } else {
            requestWeather()
        }
    }

    private func requestWeather() {
        guard isEnabled else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Allow location access to show your local weather."
            )
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            snapshot = .loading
            locationManager.requestLocation()
        case .denied, .restricted:
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Enable Location Services for CelerixMacBar in System Settings."
            )
        @unknown default:
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Location authorization is unavailable."
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isEnabled else { return }
        requestWeather()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isEnabled, let location = locations.last else { return }
        lastLocation = location
        fetchWeather(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isEnabled else { return }
        snapshot = WeatherSnapshot(
            temperature: nil,
            weatherCode: nil,
            error: "Could not determine your current location: \(error.localizedDescription)"
        )
    }

    private func fetchWeather(for location: CLLocation) {
        weatherRequest?.cancel()
        let currentRequestID = UUID()
        requestID = currentRequestID

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "temperature_unit", value: temperatureUnit == "fahrenheit" ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "timezone", value: "auto")
        ]

        guard let url = components?.url else {
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Could not create the weather request."
            )
            return
        }

        weatherRequest = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isEnabled, self.requestID == currentRequestID else { return }
                self.handleWeatherResponse(data: data, response: response, error: error)
            }
        }
        weatherRequest?.resume()
    }

    private func handleWeatherResponse(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Weather request failed: \(error.localizedDescription)"
            )
            return
        }

        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Weather service returned HTTP \(response.statusCode)."
            )
            return
        }

        guard let data else {
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "The weather service returned no data."
            )
            return
        }

        do {
            let response = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            snapshot = WeatherSnapshot(
                temperature: response.current.temperature,
                weatherCode: response.current.weatherCode,
                error: nil
            )
        } catch {
            snapshot = WeatherSnapshot(
                temperature: nil,
                weatherCode: nil,
                error: "Could not read the weather response: \(error.localizedDescription)"
            )
        }
    }

    deinit {
        refreshTimer?.invalidate()
        locationManager.stopUpdatingLocation()
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }

    let current: Current
}
