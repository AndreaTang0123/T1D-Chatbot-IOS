import Foundation
import CoreLocation
import Observation

@MainActor @Observable final class LocationService: NSObject, CLLocationManagerDelegate {
    struct NamedPlace: Codable, Identifiable {
        var id: String
        var latitude: Double
        var longitude: Double
        var radius: Double
    }
    struct VisitRecord: Codable {
        var category: String; var arrival: Date; var departure: Date?
    }
    private let manager = CLLocationManager()
    private(set) var category: String?
    private(set) var observedAt: Date?
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var message: String?
    private(set) var places: [NamedPlace] = []
    var collectionEnabled: Bool { UserDefaults.standard.bool(forKey: "locationEnabled") }
    var backgroundEnabled: Bool { UserDefaults.standard.bool(forKey: "backgroundLocationEnabled") }
    var hasAccess: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    private var latestLocation: CLLocation?
    override init() {
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 500; manager.pausesLocationUpdatesAutomatically = true
        if let data = UserDefaults.standard.data(forKey: "namedPlaces"), let places = try? JSONDecoder().decode([NamedPlace].self, from: data) { self.places = places }
    }
    func authorize() {
        guard authorization != .denied, authorization != .restricted else {
            message = "Location access is unavailable. Check Joe's location permission in iPhone Settings."; return
        }
        UserDefaults.standard.set(true, forKey: "locationEnabled")
        manager.requestWhenInUseAuthorization(); refresh()
    }
    func enableBackgroundVisits() {
        guard collectionEnabled, hasAccess else { return }
        UserDefaults.standard.set(true, forKey: "backgroundLocationEnabled")
        if authorization == .authorizedAlways { startBackgroundMonitoring() }
        else { message = "Background collection requires Always location access in iPhone Settings."; manager.requestAlwaysAuthorization() }
    }
    func disableBackgroundVisits() {
        UserDefaults.standard.set(false, forKey: "backgroundLocationEnabled")
        manager.stopMonitoringVisits(); manager.stopMonitoringSignificantLocationChanges()
        manager.monitoredRegions.forEach(manager.stopMonitoring(for:))
    }
    private func startBackgroundMonitoring() {
        guard collectionEnabled, backgroundEnabled, authorization == .authorizedAlways else { return }
        manager.startMonitoringVisits(); manager.startMonitoringSignificantLocationChanges(); monitorRegions()
    }
    func refresh() {
        guard UserDefaults.standard.bool(forKey: "locationEnabled") else { return }
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways { manager.requestLocation() }
    }
    func disable() {
        UserDefaults.standard.set(false, forKey: "locationEnabled")
        disableBackgroundVisits()
        category = nil; observedAt = nil; latestLocation = nil
    }
    func saveCurrentPlace(category: String) {
        guard let location = latestLocation, Date().timeIntervalSince(location.timestamp) < 900 else {
            message = "Get a recent location first"; return
        }
        places.removeAll { $0.id == category }
        places.append(NamedPlace(id: category, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, radius: 200))
        persistPlaces(); classify(location); monitorRegions()
    }
    func removePlace(_ id: String) { places.removeAll { $0.id == id }; persistPlaces(); monitorRegions(); category = nil }
    func forgetAll() {
        disable(); places = []; persistPlaces(); UserDefaults.standard.removeObject(forKey: "placeVisits")
    }
    func category(at time: Date) -> String? {
        guard let observedAt, observedAt <= time, time.timeIntervalSince(observedAt) <= 900 else { return nil }
        return category
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        guard UserDefaults.standard.bool(forKey: "locationEnabled") else { return }
        if authorization == .authorizedAlways { startBackgroundMonitoring() }
        else {
            manager.stopMonitoringVisits(); manager.stopMonitoringSignificantLocationChanges()
            manager.monitoredRegions.forEach(manager.stopMonitoring(for:))
        }
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways { refresh() }
        else { category = nil; observedAt = nil }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard UserDefaults.standard.bool(forKey: "locationEnabled"), let location = locations.last,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 1000,
              Date().timeIntervalSince(location.timestamp) < 900 else { return }
        latestLocation = location; classify(location)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Location unavailable" }
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        guard collectionEnabled, backgroundEnabled, authorization == .authorizedAlways else { return }
        let point = CLLocation(latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude)
        let place = classifyCategory(point)
        var history = (UserDefaults.standard.data(forKey: "placeVisits")).flatMap { try? JSONDecoder().decode([VisitRecord].self, from: $0) } ?? []
        history.append(VisitRecord(category: place, arrival: visit.arrivalDate,
                                   departure: visit.departureDate == .distantFuture ? nil : visit.departureDate))
        if let data = try? JSONEncoder().encode(Array(history.suffix(100))) { UserDefaults.standard.set(data, forKey: "placeVisits") }
        // Visits can be delayed; request a fresh coarse location rather than label a historical visit as current.
        refresh()
    }
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) { refresh() }
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) { refresh() }
    private func classify(_ location: CLLocation) { category = classifyCategory(location); observedAt = location.timestamp }
    private func classifyCategory(_ location: CLLocation) -> String {
        places.first { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius }?.id ?? "other"
    }
    private func persistPlaces() {
        if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: "namedPlaces") }
    }
    private func monitorRegions() {
        manager.monitoredRegions.forEach(manager.stopMonitoring(for:))
        guard collectionEnabled, backgroundEnabled, authorization == .authorizedAlways, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        for place in places.prefix(20) {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                         radius: min(place.radius, manager.maximumRegionMonitoringDistance), identifier: place.id)
            manager.startMonitoring(for: region)
        }
    }
}
