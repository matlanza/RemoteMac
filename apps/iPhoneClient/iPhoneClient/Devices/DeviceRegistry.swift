import Foundation
import Combine
import RemoteProtocol

enum DeviceRegistryError:
    LocalizedError
{
    case missingPairingKey

    var errorDescription:
        String?
    {
        switch self {
        case .missingPairingKey:
            return
                "The paired device key was not received."
        }
    }
}

@MainActor
final class DeviceRegistry:
    ObservableObject
{
    @Published private(set)
    var devices:
        [RemoteDevice] = []

    @Published private(set)
    var selectedDeviceID:
        String?

    private let defaults =
        UserDefaults.standard

    private let registryKey =
        "RemoteMacDeviceRegistryV1"

    private let selectedDeviceKey =
        "RemoteMacSelectedDeviceV1"

    private var presenceProbeGeneration:
        [String: UUID] = [:]

    private var presenceEvidenceGeneration:
        [String: UUID] = [:]

    private var presenceConsecutiveFailures:
        [String: Int] = [:]

    private let presenceEvidenceLifetimeNanoseconds:
        UInt64 =
            6_000_000_000

    private let presenceWatchdogNanoseconds:
        UInt64 =
            3_000_000_000

    init() {
        let hadPersistedRegistry =
            defaults.data(
                forKey:
                    registryKey
            ) != nil

        load()
        resetRuntimePresence()

        if
            devices.isEmpty,
            !hadPersistedRegistry
        {
            migrateCurrentMac()
        }

        migrateLegacyPairingIfNeeded()

        migratePresenceV2IfNeeded()

        restoreSelection()
    }

    var selectedDevice:
        RemoteDevice?
    {
        guard
            let selectedDeviceID
        else {
            return devices.first
        }

        return devices.first {
            $0.id == selectedDeviceID
        }
    }

    func select(
        deviceID: String
    ) {
        guard
            devices.contains(
                where: {
                    $0.id == deviceID
                }
            )
        else {
            return
        }

        selectedDeviceID =
            deviceID

        defaults.set(
            deviceID,
            forKey:
                selectedDeviceKey
        )
    }

    func refreshLegacyDevice() {
        guard
            devices.count == 1
        else {
            return
        }

        guard
            var device =
                devices.first
        else {
            return
        }

        let legacyFingerprint =
            try? PairingStore
                .fingerprint()

        let isLegacyDevice =
            device.id ==
                "legacy-current-mac"
            || (
                legacyFingerprint != nil
                && device.id ==
                    "identity:\(legacyFingerprint!)"
            )

        guard isLegacyDevice else {
            return
        }

        let currentHost =
            defaults.string(
                forKey:
                    "RemoteMacHost"
            )?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        if let currentHost,
           !currentHost.isEmpty
        {
            device.automaticEndpoint =
                RemoteEndpoint(
                    host:
                        currentHost,
                    port:
                        RemoteProtocolInfo.port
                )
        }

        if
            let fingerprint =
                try? PairingStore
                    .fingerprint()
        {
            device.identityFingerprint =
                fingerprint

            if device.id ==
                "legacy-current-mac"
            {
                device =
                    RemoteDevice(
                        id:
                            "identity:\(fingerprint)",
                        name:
                            device.name,
                        platform:
                            device.platform,
                        identityFingerprint:
                            fingerprint,
                        automaticEndpoint:
                            device
                                .automaticEndpoint,
                        manualEndpointOverride:
                            device
                                .manualEndpointOverride,
                        capabilities:
                            device.capabilities,
                        presence:
                            device.presence,
                        lastSeen:
                            device.lastSeen
                    )
            }
        }

        devices = [
            device
        ]

        selectedDeviceID =
            device.id

        persist()
    }

    func refreshPresence()
        async
    {
        let snapshot =
            devices

        for device in snapshot {
            guard
                let endpoint =
                    device.resolvedEndpoint
            else {
                presenceEvidenceGeneration
                    .removeValue(
                        forKey:
                            device.id
                    )

                updatePresence(
                    deviceID:
                        device.id,
                    presence:
                        .unknown
                )

                continue
            }

            if
                presenceProbeGeneration[
                    device.id
                ] != nil
            {
                continue
            }

            let generation =
                UUID()

            presenceProbeGeneration[
                device.id
            ] =
                generation

            let hasFreshEvidence =
                presenceEvidenceGeneration[
                    device.id
                ] != nil

            if !hasFreshEvidence {
                updatePresence(
                    deviceID:
                        device.id,
                    presence:
                        .checking
                )
            }

            Task { [weak self] in
                let reachable =
                    await DevicePresenceProbe
                        .shared
                        .isReachable(
                            endpoint:
                                endpoint,
                            onTransportReady: {
                                [weak self] in

                                await self?
                                    .markPresenceTransportReady(
                                        deviceID:
                                            device.id,
                                        generation:
                                            generation
                                    )
                            }
                        )

                guard let self else {
                    return
                }

                guard
                    self.presenceProbeGeneration[
                        device.id
                    ] ==
                        generation
                else {
                    return
                }

                self.presenceProbeGeneration
                    .removeValue(
                        forKey:
                            device.id
                    )

                if reachable {
                    self.recordPresenceEvidence(
                        deviceID:
                            device.id,
                        presence:
                            .available,
                        lastSeen:
                            Date()
                    )
                } else {
                    self.recordPresenceFailure(
                        deviceID:
                            device.id
                    )
                }
            }

            Task { [weak self] in
                guard let self else {
                    return
                }

                var noPongWindow =
                    0

                while true {
                    do {
                        try await Task.sleep(
                            nanoseconds:
                                self
                                    .presenceWatchdogNanoseconds
                        )
                    } catch {
                        return
                    }

                    guard
                        self.presenceProbeGeneration[
                            device.id
                        ] ==
                            generation
                    else {
                        return
                    }

                    noPongWindow +=
                        1

                    print(
                        "REMOTEMAC_PRESENCE no-pong window=\(noPongWindow)"
                    )

                    self.recordPresenceFailure(
                        deviceID:
                            device.id
                    )
                }
            }
        }
    }

    func invalidatePresenceEvidence(
        deviceID: String?
    ) {
        guard
            let deviceID,
            let device =
                devices.first(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return
        }

        presenceEvidenceGeneration
            .removeValue(
                forKey:
                    deviceID
            )

        presenceConsecutiveFailures
            .removeValue(
                forKey:
                    deviceID
            )

        updatePresence(
            deviceID:
                deviceID,
            presence:
                device.resolvedEndpoint == nil
                ? .unknown
                : .checking
        )
    }

    func invalidateAllPresenceEvidence() {
        presenceEvidenceGeneration
            .removeAll()

        presenceConsecutiveFailures
            .removeAll()

        let snapshot =
            devices

        for device in snapshot {
            updatePresence(
                deviceID:
                    device.id,
                presence:
                    device.resolvedEndpoint == nil
                    ? .unknown
                    : .checking
            )
        }
    }

    private func markPresenceTransportReady(
        deviceID: String,
        generation: UUID
    ) {
        guard
            presenceProbeGeneration[
                deviceID
            ] ==
                generation
        else {
            return
        }

        guard
            let index =
                devices.firstIndex(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return
        }

        guard
            devices[index].presence ==
                .offline
        else {
            return
        }

        print(
            "REMOTEMAC_PRESENCE recovery transport ready; checking"
        )

        presenceEvidenceGeneration
            .removeValue(
                forKey:
                    deviceID
            )

        updatePresence(
            deviceID:
                deviceID,
            presence:
                .checking
        )
    }

    private func recordPresenceFailure(
        deviceID: String
    ) {
        let previousFailureCount =
            presenceConsecutiveFailures[
                deviceID
            ]
            ?? 0

        let failureCount =
            min(
                previousFailureCount + 1,
                2
            )

        presenceConsecutiveFailures[
            deviceID
        ] =
            failureCount

        if failureCount >= 2 {
            presenceEvidenceGeneration
                .removeValue(
                    forKey:
                        deviceID
                )

            if previousFailureCount < 2 {
                print(
                    "REMOTEMAC_PRESENCE offline confirmed misses=2"
                )
            }

            recordPresenceEvidence(
                deviceID:
                    deviceID,
                presence:
                    .offline
            )

            return
        }

        print(
            "REMOTEMAC_PRESENCE miss 1/2; confirming"
        )

        if
            presenceEvidenceGeneration[
                deviceID
            ] == nil
        {
            updatePresence(
                deviceID:
                    deviceID,
                presence:
                    .checking
            )
        }
    }

    private func recordPresenceEvidence(
        deviceID: String,
        presence: RemotePresence,
        lastSeen: Date? = nil
    ) {
        if presence == .available {
            presenceConsecutiveFailures
                .removeValue(
                    forKey:
                        deviceID
                )
        }

        let evidenceGeneration =
            UUID()

        presenceEvidenceGeneration[
            deviceID
        ] =
            evidenceGeneration

        updatePresence(
            deviceID:
                deviceID,
            presence:
                presence,
            lastSeen:
                lastSeen
        )

        Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(
                nanoseconds:
                    self
                        .presenceEvidenceLifetimeNanoseconds
            )

            guard
                self.presenceEvidenceGeneration[
                    deviceID
                ] ==
                    evidenceGeneration
            else {
                return
            }

            self.presenceEvidenceGeneration
                .removeValue(
                    forKey:
                        deviceID
                )

            guard
                let current =
                    self.devices.first(
                        where: {
                            $0.id ==
                                deviceID
                        }
                    ),
                current.presence ==
                    presence
            else {
                return
            }

            self.updatePresence(
                deviceID:
                    deviceID,
                presence:
                    .checking
            )
        }
    }

    private func updatePresence(
        deviceID: String,
        presence: RemotePresence,
        lastSeen: Date? = nil
    ) {
        guard
            let index =
                devices.firstIndex(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return
        }

        devices[index].presence =
            presence

        if let lastSeen {
            devices[index].lastSeen =
                lastSeen
        }
    }

    func finalizeDiscoveredPairing(
        provisionalDeviceID:
            String,
        name:
            String,
        endpoint:
            RemoteEndpoint
    ) throws
        -> RemoteDevice
    {
        guard
            let publicKey =
                try DevicePairingStore
                    .load(
                        for:
                            provisionalDeviceID
                    )
        else {
            throw DeviceRegistryError
                .missingPairingKey
        }

        let fingerprint =
            DeviceIdentity
                .fingerprint(
                    for:
                        publicKey
                )

        let finalDeviceID =
            "identity:\(fingerprint)"

        try DevicePairingStore
            .save(
                publicKeyData:
                    publicKey,
                for:
                    finalDeviceID
            )

        try DevicePairingStore
            .delete(
                for:
                    provisionalDeviceID
            )

        if
            let existing =
                devices.first(
                    where: {
                        $0.id ==
                            finalDeviceID
                    }
                )
        {
            select(
                deviceID:
                    existing.id
            )

            return existing
        }

        let cleanedName =
            name.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let device =
            RemoteDevice(
                id:
                    finalDeviceID,
                name:
                    cleanedName.isEmpty
                    ? "Mac"
                    : cleanedName,
                platform:
                    .macOS,
                identityFingerprint:
                    fingerprint,
                automaticEndpoint:
                    endpoint,
                manualEndpointOverride:
                    nil,
                capabilities: [
                    .screen,
                    .pointer,
                    .keyboard,
                    .notifications
                ],
                presence:
                    .unknown,
                lastSeen:
                    nil
            )

        devices.append(
            device
        )

        selectedDeviceID =
            device.id

        persist()

        return device
    }

    @discardableResult
    func removeDevice(
        deviceID: String
    ) throws
        -> RemoteDevice?
    {
        guard
            let index =
                devices.firstIndex(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return selectedDevice
        }

        let removed =
            devices[index]

        try DevicePairingStore
            .delete(
                for:
                    removed.id
            )

        if
            let legacyKey =
                try PairingStore
                    .load(),
            let removedFingerprint =
                removed
                    .identityFingerprint,
            DeviceIdentity
                .fingerprint(
                    for:
                        legacyKey
                ) ==
                removedFingerprint
        {
            try PairingStore
                .delete()
        }

        presenceProbeGeneration
            .removeValue(
                forKey:
                    removed.id
            )

        presenceEvidenceGeneration
            .removeValue(
                forKey:
                    removed.id
            )

        presenceConsecutiveFailures
            .removeValue(
                forKey:
                    removed.id
            )

        devices.remove(
            at:
                index
        )

        if
            selectedDeviceID ==
                removed.id
            || !devices.contains(
                where: {
                    $0.id ==
                        selectedDeviceID
                }
            )
        {
            selectedDeviceID =
                devices.first?
                    .id
        }

        persist()

        return selectedDevice
    }

    func rename(
        deviceID: String,
        name: String
    ) {
        guard
            let index =
                devices.firstIndex(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return
        }

        let cleaned =
            name.trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        guard !cleaned.isEmpty else {
            return
        }

        devices[index].name =
            cleaned

        persist()
    }

    func setManualEndpoint(
        deviceID: String,
        host: String?
    ) {
        guard
            let index =
                devices.firstIndex(
                    where: {
                        $0.id ==
                            deviceID
                    }
                )
        else {
            return
        }

        let cleaned =
            host?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        if
            let cleaned,
            !cleaned.isEmpty
        {
            devices[index]
                .manualEndpointOverride =
                RemoteEndpoint(
                    host:
                        cleaned,
                    port:
                        RemoteProtocolInfo.port
                )
        } else {
            devices[index]
                .manualEndpointOverride =
                nil
        }

        persist()
    }

    private func migrateCurrentMac() {
        let fingerprint =
            try? PairingStore
                .fingerprint()

        let resolvedFingerprint =
            fingerprint ?? nil

        let id: String

        if let resolvedFingerprint {
            id =
                "identity:\(resolvedFingerprint)"
        } else {
            id =
                "legacy-current-mac"
        }

        let host =
            defaults.string(
                forKey:
                    "RemoteMacHost"
            )?
            .trimmingCharacters(
                in:
                    .whitespacesAndNewlines
            )

        let endpoint:
            RemoteEndpoint?

        if let host,
           !host.isEmpty
        {
            endpoint =
                RemoteEndpoint(
                    host: host,
                    port:
                        RemoteProtocolInfo.port
                )
        } else {
            endpoint =
                nil
        }

        let device =
            RemoteDevice(
                id: id,
                name:
                    "My Mac",
                platform:
                    .macOS,
                identityFingerprint:
                    resolvedFingerprint,
                automaticEndpoint:
                    endpoint,
                manualEndpointOverride:
                    nil,
                capabilities: [
                    .screen,
                    .pointer,
                    .keyboard,
                    .notifications
                ],
                presence:
                    .unknown,
                lastSeen:
                    nil
            )

        devices = [
            device
        ]

        selectedDeviceID =
            device.id

        persist()
    }

    private func migratePresenceV2IfNeeded() {
        let key =
            "RemoteMacPresenceSemanticsV2"

        guard
            !defaults.bool(
                forKey:
                    key
            )
        else {
            return
        }

        for index in devices.indices {
            devices[index].presence =
                .unknown

            devices[index].lastSeen =
                nil
        }

        defaults.set(
            true,
            forKey:
                key
        )

        persist()

        print(
            "REMOTEMAC_PRESENCE upgraded to MacHost ping semantics"
        )
    }

    private func migrateLegacyPairingIfNeeded() {
        do {
            guard
                let legacyKey =
                    try PairingStore
                        .load()
            else {
                return
            }

            let fingerprint =
                DeviceIdentity
                    .fingerprint(
                        for: legacyKey
                    )

            let deviceID =
                "identity:\(fingerprint)"

            if
                try DevicePairingStore
                    .load(
                        for: deviceID
                    ) == nil
            {
                try DevicePairingStore
                    .save(
                        publicKeyData:
                            legacyKey,
                        for:
                            deviceID
                    )

                print(
                    "REMOTEMAC_PAIRING migrated legacy pairing to device-scoped store"
                )
            }

            guard
                let storedFingerprint =
                    try DevicePairingStore
                        .fingerprint(
                            for: deviceID
                        ),
                storedFingerprint ==
                    fingerprint
            else {
                print(
                    "REMOTEMAC_PAIRING device-scoped migration verification failed"
                )

                return
            }

            print(
                "REMOTEMAC_PAIRING device-scoped pairing ready"
            )

        } catch {
            print(
                "REMOTEMAC_PAIRING migration error: \(error.localizedDescription)"
            )
        }
    }

    private func restoreSelection() {
        guard
            !devices.isEmpty
        else {
            selectedDeviceID =
                nil

            return
        }

        if
            let stored =
                defaults.string(
                    forKey:
                        selectedDeviceKey
                ),
            devices.contains(
                where: {
                    $0.id == stored
                }
            )
        {
            selectedDeviceID =
                stored
        } else {
            selectedDeviceID =
                devices[0].id

            defaults.set(
                devices[0].id,
                forKey:
                    selectedDeviceKey
            )
        }
    }

    private func load() {
        guard
            let data =
                defaults.data(
                    forKey:
                        registryKey
                ),
            let decoded =
                try? JSONDecoder()
                    .decode(
                        [RemoteDevice].self,
                        from: data
                    )
        else {
            return
        }

        devices =
            decoded
    }

    private func resetRuntimePresence() {
        for index in devices.indices {
            devices[index].presence =
                .unknown

            devices[index].lastSeen =
                nil
        }

        presenceProbeGeneration
            .removeAll()

        presenceEvidenceGeneration
            .removeAll()

        presenceConsecutiveFailures
            .removeAll()
    }

    private func persist() {
        let persistedDevices =
            devices.map { device in
                var stored =
                    device

                stored.presence =
                    .unknown

                stored.lastSeen =
                    nil

                return stored
            }

        guard
            let data =
                try? JSONEncoder()
                    .encode(
                        persistedDevices
                    )
        else {
            return
        }

        defaults.set(
            data,
            forKey:
                registryKey
        )

        if let selectedDeviceID {
            defaults.set(
                selectedDeviceID,
                forKey:
                    selectedDeviceKey
            )
        } else {
            defaults.removeObject(
                forKey:
                    selectedDeviceKey
            )
        }
    }

}
