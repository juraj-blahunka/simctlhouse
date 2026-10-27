import Testing
@testable import SimctlHouseCore

@Suite struct CatalogTests {
    let backend = FakeBackend()
    var catalog: Catalog { Catalog(deviceTypes: backend.types, runtimes: backend.runtimeList) }

    @Test func defaultsToLatestRunnableIPhonePro() throws {
        let resolved = try catalog.resolve(DeviceSpec())
        #expect(resolved.deviceType.name == "iPhone 18 Pro")
        #expect(resolved.runtime.version == "27.0")
    }

    @Test func defaultIPadIsBaseMemoryLatestPro11() throws {
        let resolved = try catalog.resolve(DeviceSpec(family: .ipad))
        #expect(resolved.deviceType.name == "iPad Pro 11-inch (M5)")
    }

    @Test func picksLatestRuntimeSupportingTheModel() throws {
        let resolved = try catalog.resolve(DeviceSpec(model: "iphone 18 pro max"))
        #expect(resolved.runtime.version == "27.1")
    }

    @Test func osMatchesByVersionComponentNotStringPrefix() throws {
        let resolved = try catalog.resolve(DeviceSpec(model: "iPhone 17 Pro", os: "26"))
        #expect(resolved.runtime.version == "26.5")
        #expect(try catalog.resolve(DeviceSpec(model: "iPhone 17 Pro", os: "2")).runtime.version == "2.6")
    }

    @Test func modelAcceptsDeviceTypeIdentifier() throws {
        #expect(try catalog.resolve(DeviceSpec(model: "type.iPad-Pro-13-M5")).deviceType.name == "iPad Pro 13-inch (M5)")
    }

    @Test func rejectsUnknownAndNonIOSModels() {
        #expect(throws: SimctlHouseError.unknownModel("Pixel 9")) { try catalog.resolve(DeviceSpec(model: "Pixel 9")) }
        #expect(throws: SimctlHouseError.unsupportedModel("Apple Watch Ultra 3")) { try catalog.resolve(DeviceSpec(model: "Apple Watch Ultra 3")) }
    }

    @Test func rejectsModelFromTheWrongFamily() {
        #expect(throws: (any Error).self) { try catalog.resolve(DeviceSpec(family: .ipad, model: "iPhone 18 Pro")) }
    }

    @Test func reportsMissingRuntime() {
        #expect(throws: SimctlHouseError.noRuntime(model: "iPhone 18 Pro", os: "26.5")) {
            try catalog.resolve(DeviceSpec(model: "iPhone 18 Pro", os: "26.5"))
        }
    }

    @Test func namesAreTwoDistinctWords() {
        var taken: Set<String> = []
        for _ in 0..<2_000 {
            let name = NameGenerator.generate(avoiding: taken)
            #expect(name.wholeMatch(of: /[a-z]+-[a-z]+/) != nil)
            #expect(!taken.contains(name))
            taken.insert(name)
        }
        #expect(Set(NameGenerator.adjectives).count == NameGenerator.adjectives.count)
        #expect(Set(NameGenerator.nouns).count == NameGenerator.nouns.count)
    }
}
