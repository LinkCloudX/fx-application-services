/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Glean

public class Nimbus: NimbusApi {
    private let nimbusClient: NimbusClientProtocol

    private let resourceBundles: [Bundle]

    private let errorReporter: NimbusErrorReporter

    lazy var fetchQueue: OperationQueue = {
        var queue = OperationQueue()
        queue.name = "Nimbus fetch queue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    lazy var dbQueue: OperationQueue = {
        var queue = OperationQueue()
        queue.name = "Nimbus database queue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    internal init(nimbusClient: NimbusClientProtocol,
                  resourceBundles: [Bundle],
                  errorReporter: @escaping NimbusErrorReporter)
    {
        self.errorReporter = errorReporter
        self.nimbusClient = nimbusClient
        self.resourceBundles = resourceBundles
        NilVariables.instance.set(bundles: resourceBundles)
    }
}

private extension Nimbus {
    func catchAll<T>(_ thunk: () throws -> T?) -> T? {
        do {
            return try thunk()
        } catch NimbusError.DatabaseNotReady {
            return nil
        } catch {
            errorReporter(error)
            return nil
        }
    }

    func catchAll(_ queue: OperationQueue, thunk: @escaping () throws -> Void) {
        queue.addOperation {
            self.catchAll(thunk)
        }
    }
}

extension Nimbus: NimbusQueues {
    public func waitForFetchQueue() {
        fetchQueue.waitUntilAllOperationsAreFinished()
    }

    public func waitForDbQueue() {
        dbQueue.waitUntilAllOperationsAreFinished()
    }
}

extension Nimbus: NimbusEvents {
    public func recordEvent(_ eventId: String) {
        catchAll(dbQueue) {
            try self.nimbusClient.recordEvent(eventId: eventId)
        }
    }

    public func clearEvents() {
        catchAll(dbQueue) {
            try self.nimbusClient.clearEvents()
        }
    }
}

extension Nimbus: FeaturesInterface {
    public func recordExposureEvent(featureId: String) {
        // First we need a list of the active experiments that are enrolled.
        let activeExperiments = getActiveExperiments()

        // Next, we search for any experiment that has a matching featureId. This depends on the
        // fact that we can only be enrolled in a single experiment per feature, so there should
        // only ever be zero or one experiments for a given featureId.
        if let experiment = activeExperiments.first(where: { $0.featureIds.contains(featureId) }) {
            // Finally, if we do have an experiment for the given featureId, we will record the
            // exposure event in Glean. This is to protect against accidentally recording an event
            // for an experiment without an active enrollment.
            GleanMetrics.NimbusEvents.exposure.record(GleanMetrics.NimbusEvents.ExposureExtra(
                branch: experiment.branchSlug,
                experiment: experiment.slug
            ))
        }
    }

    internal func postEnrollmentCalculation(_ events: [EnrollmentChangeEvent]) {
        // We need to update the experiment enrollment annotations in Glean
        // regardless of whether we recieved any events. Calling the
        // `setExperimentActive` function multiple times with the same
        // experiment id is safe so nothing bad should happen in case we do.
        let experiments = getActiveExperiments()
        recordExperimentTelemetry(experiments)

        // Record enrollment change events, if any
        recordExperimentEvents(events)

        // Inform any listeners that we're done here.
        notifyOnExperimentsApplied(experiments)
    }

    internal func recordExperimentTelemetry(_ experiments: [EnrolledExperiment]) {
        for experiment in experiments {
            Glean.shared.setExperimentActive(
                experiment.slug,
                branch: experiment.branchSlug,
                extra: ["enrollmentId": experiment.enrollmentId]
            )
        }
    }

    internal func recordExperimentEvents(_ events: [EnrollmentChangeEvent]) {
        for event in events {
            switch event.change {
            case .enrollment:
                GleanMetrics.NimbusEvents.enrollment.record(GleanMetrics.NimbusEvents.EnrollmentExtra(
                    branch: event.branchSlug,
                    enrollmentId: event.enrollmentId,
                    experiment: event.experimentSlug
                ))
            case .disqualification:
                GleanMetrics.NimbusEvents.disqualification.record(GleanMetrics.NimbusEvents.DisqualificationExtra(
                    branch: event.branchSlug,
                    enrollmentId: event.enrollmentId,
                    experiment: event.experimentSlug
                ))
            case .unenrollment:
                GleanMetrics.NimbusEvents.unenrollment.record(GleanMetrics.NimbusEvents.UnenrollmentExtra(
                    branch: event.branchSlug,
                    enrollmentId: event.enrollmentId,
                    experiment: event.experimentSlug
                ))

            case .enrollFailed:
                GleanMetrics.NimbusEvents.enrollFailed.record(GleanMetrics.NimbusEvents.EnrollFailedExtra(
                    branch: event.branchSlug,
                    experiment: event.experimentSlug,
                    reason: event.reason
                ))
            case .unenrollFailed:
                GleanMetrics.NimbusEvents.unenrollFailed.record(GleanMetrics.NimbusEvents.UnenrollFailedExtra(
                    experiment: event.experimentSlug,
                    reason: event.reason
                ))
            }
        }
    }

    internal func getFeatureConfigVariablesJson(featureId: String) -> [String: Any]? {
        do {
            guard let string = try nimbusClient.getFeatureConfigVariables(featureId: featureId) else {
                return nil
            }
            return try Dictionary.parse(jsonString: string)
        } catch NimbusError.DatabaseNotReady {
            GleanMetrics.NimbusHealth.cacheNotReadyForFeature.record(
                GleanMetrics.NimbusHealth.CacheNotReadyForFeatureExtra(
                    featureId: featureId
                )
            )
            return nil
        } catch {
            errorReporter(error)
            return nil
        }
    }

    public func getVariables(featureId: String, sendExposureEvent: Bool) -> Variables {
        guard let json = getFeatureConfigVariablesJson(featureId: featureId) else {
            return NilVariables.instance
        }

        if sendExposureEvent {
            recordExposureEvent(featureId: featureId)
        }

        return JSONVariables(with: json, in: resourceBundles)
    }
}

private extension Nimbus {
    func notifyOnExperimentsFetched() {
        NotificationCenter.default.post(name: .nimbusExperimentsFetched, object: nil)
    }

    func notifyOnExperimentsApplied(_ experiments: [EnrolledExperiment]) {
        NotificationCenter.default.post(name: .nimbusExperimentsApplied, object: experiments)
    }
}

/*
 * Methods split out onto a separate internal extension for testing purposes.
 */
internal extension Nimbus {
    func setGlobalUserParticipationOnThisThread(_ value: Bool) throws {
        let changes = try nimbusClient.setGlobalUserParticipation(optIn: value)
        postEnrollmentCalculation(changes)
    }

    func initializeOnThisThread() throws {
        try nimbusClient.initialize()
    }

    func fetchExperimentsOnThisThread() throws {
        try nimbusClient.fetchExperiments()
        notifyOnExperimentsFetched()
    }

    func applyPendingExperimentsOnThisThread() throws {
        let changes = try nimbusClient.applyPendingExperiments()
        postEnrollmentCalculation(changes)
    }

    func setExperimentsLocallyOnThisThread(_ experimentsJson: String) throws {
        try nimbusClient.setExperimentsLocally(experimentsJson: experimentsJson)
    }

    func optOutOnThisThread(_ experimentId: String) throws {
        let changes = try nimbusClient.optOut(experimentSlug: experimentId)
        postEnrollmentCalculation(changes)
    }

    func optInOnThisThread(_ experimentId: String, branch: String) throws {
        let changes = try nimbusClient.optInWithBranch(experimentSlug: experimentId, branch: branch)
        postEnrollmentCalculation(changes)
    }

    func resetTelemetryIdentifiersOnThisThread(_ identifiers: AvailableRandomizationUnits) throws {
        let changes = try nimbusClient.resetTelemetryIdentifiers(newRandomizationUnits: identifiers)
        postEnrollmentCalculation(changes)
    }
}

extension Nimbus: NimbusUserConfiguration {
    public var globalUserParticipation: Bool {
        get {
            catchAll { try nimbusClient.getGlobalUserParticipation() } ?? false
        }
        set {
            catchAll(dbQueue) {
                try self.setGlobalUserParticipationOnThisThread(newValue)
            }
        }
    }

    public func getActiveExperiments() -> [EnrolledExperiment] {
        return catchAll {
            try nimbusClient.getActiveExperiments()
        } ?? []
    }

    public func getAvailableExperiments() -> [AvailableExperiment] {
        return catchAll {
            try nimbusClient.getAvailableExperiments()
        } ?? []
    }

    public func getExperimentBranches(_ experimentId: String) -> [Branch]? {
        return catchAll {
            try nimbusClient.getExperimentBranches(experimentSlug: experimentId)
        }
    }

    public func optOut(_ experimentId: String) {
        catchAll(dbQueue) {
            try self.optOutOnThisThread(experimentId)
        }
    }

    public func optIn(_ experimentId: String, branch: String) {
        catchAll(dbQueue) {
            try self.optInOnThisThread(experimentId, branch: branch)
        }
    }

    public func resetTelemetryIdentifiers() {
        catchAll(dbQueue) {
            // The "dummy" field here is required for obscure reasons when generating code on desktop,
            // so we just automatically set it to a dummy value.
            let aru = AvailableRandomizationUnits(clientId: nil, dummy: 0)
            try self.resetTelemetryIdentifiersOnThisThread(aru)
        }
    }
}

extension Nimbus: NimbusStartup {
    public func initialize() {
        catchAll(dbQueue) {
            try self.initializeOnThisThread()
        }
    }

    public func fetchExperiments() {
        catchAll(fetchQueue) {
            try self.fetchExperimentsOnThisThread()
        }
    }

    public func applyPendingExperiments() {
        catchAll(dbQueue) {
            try self.applyPendingExperimentsOnThisThread()
        }
    }

    public func setExperimentsLocally(_ fileURL: URL) {
        catchAll(dbQueue) {
            let json = try String(contentsOf: fileURL)
            try self.setExperimentsLocallyOnThisThread(json)
        }
    }

    public func setExperimentsLocally(_ experimentsJson: String) {
        catchAll(dbQueue) {
            try self.setExperimentsLocallyOnThisThread(experimentsJson)
        }
    }
}

extension Nimbus: NimbusBranchInterface {
    public func getExperimentBranch(experimentId: String) -> String? {
        return catchAll {
            try nimbusClient.getExperimentBranch(id: experimentId)
        }
    }
}

extension Nimbus: GleanPlumbProtocol {
    public func createMessageHelper() throws -> GleanPlumbMessageHelper {
        return try createMessageHelper(string: nil)
    }

    public func createMessageHelper(additionalContext: [String: Any]) throws -> GleanPlumbMessageHelper {
        let string = try additionalContext.stringify()
        return try createMessageHelper(string: string)
    }

    public func createMessageHelper<T: Encodable>(additionalContext: T) throws -> GleanPlumbMessageHelper {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let data = try encoder.encode(additionalContext)
        let string = String(data: data, encoding: .utf8)!
        return try createMessageHelper(string: string)
    }

    private func createMessageHelper(string: String?) throws -> GleanPlumbMessageHelper {
        let targetingHelper = try nimbusClient.createTargetingHelper(additionalContext: string)
        let stringHelper = try nimbusClient.createStringHelper(additionalContext: string)
        return GleanPlumbMessageHelper(targetingHelper: targetingHelper, stringHelper: stringHelper)
    }
}

public class NimbusDisabled: NimbusApi {
    public static let shared = NimbusDisabled()

    public var globalUserParticipation: Bool = false
}

public extension NimbusDisabled {
    func getActiveExperiments() -> [EnrolledExperiment] {
        return []
    }

    func getAvailableExperiments() -> [AvailableExperiment] {
        return []
    }

    func getExperimentBranch(experimentId _: String) -> String? {
        return nil
    }

    func getVariables(featureId _: String, sendExposureEvent _: Bool) -> Variables {
        return NilVariables.instance
    }

    func initialize() {}

    func fetchExperiments() {}

    func applyPendingExperiments() {}

    func setExperimentsLocally(_: URL) {}

    func setExperimentsLocally(_: String) {}

    func optOut(_: String) {}

    func optIn(_: String, branch _: String) {}

    func resetTelemetryIdentifiers() {}

    func recordExposureEvent(featureId _: String) {}

    func recordEvent(_: String) {}

    func clearEvents() {}

    func getExperimentBranches(_: String) -> [Branch]? {
        return nil
    }

    func waitForFetchQueue() {}

    func waitForDbQueue() {}
}

extension NimbusDisabled: GleanPlumbProtocol {
    public func createMessageHelper() throws -> GleanPlumbMessageHelper {
        GleanPlumbMessageHelper(
            targetingHelper: AlwaysFalseTargetingHelper(),
            stringHelper: NonStringHelper()
        )
    }

    public func createMessageHelper(additionalContext _: [String: Any]) throws -> GleanPlumbMessageHelper {
        try createMessageHelper()
    }

    public func createMessageHelper<T: Encodable>(additionalContext _: T) throws -> GleanPlumbMessageHelper {
        try createMessageHelper()
    }
}
