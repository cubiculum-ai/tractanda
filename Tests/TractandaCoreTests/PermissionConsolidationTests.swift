import XCTest

@testable import TractandaCore

final class PermissionConsolidationTests: XCTestCase {
    private final class Accounts: AccountDirectory {
        let offset: UInt32
        var memberships: [String: Set<UInt32>] = [:]
        init(offset: UInt32 = 0) { self.offset = offset }
        func user(forUID uid: UInt32) throws -> AccountIdentity {
            guard let index = (0..<4).first(where: { offset + UInt32($0) + 100 == uid }) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return try user(named: ["alice", "bob", "charlie", "dana"][index])
        }
        func user(named name: String) throws -> AccountIdentity {
            guard let index = ["alice", "bob", "charlie", "dana"].firstIndex(of: name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown user")
            }
            return AccountIdentity(
                uid: offset + UInt32(index) + 100, name: name, primaryGroupName: "staff",
                groupIDs: memberships[name] ?? [])
        }
        func groupID(named name: String) throws -> UInt32 {
            guard let index = ["staff", "readers", "writers"].firstIndex(of: name) else {
                throw TractandaError("unresolvedPrincipal", "Unknown group")
            }
            return offset + UInt32(index) + 200
        }
    }

    private func permissions(
        owner: String = "alice", group: String = "staff", mode: Int = 0o660,
        users: [String: Int]? = nil, groups: [String: Int]? = nil,
        owningGroup: Int = 0, mask: Int = 6
    ) -> ItemValue {
        var acl: [String: ItemValue] = [:]
        if users != nil || groups != nil {
            acl = ["mask": .integer(Int64(mask)), "owningGroup": .integer(Int64(owningGroup))]
            if let users { acl["users"] = .object(users.mapValues { .integer(Int64($0)) }) }
            if let groups { acl["groups"] = .object(groups.mapValues { .integer(Int64($0)) }) }
        }
        return .object([
            "profile": .text(ItemPermissions.profile), "owner": .text(owner), "group": .text(group),
            "mode": .integer(Int64(mode)), "acl": .object(acl),
        ])
    }

    private func configuration() throws -> AccessConfiguration {
        try AccessConfiguration(
            .object([
                "profile": .text(AccessConfiguration.profile),
                "userAliases": .object(["nickname": .text("bob"), "leader": .text("alice")]),
                "groupAliases": .object(["crew": .text("readers")]),
            ]))
    }

    /// Exhaust every membership subset for this small universe, without enumerating actual OS users.
    private func assertSound(
        _ values: [ItemValue], accounts: Accounts, configuration: AccessConfiguration? = nil,
        selectedOwnership: PermissionConsolidation.Ownership? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let plan = try PermissionConsolidation.plan(values, selectedOwnership: selectedOwnership)
        let result = try ItemPermissions(XCTUnwrap(plan.outcome.posixValue, file: file, line: line))
        let normalized = values.map { value -> ItemValue in
            guard let selectedOwnership else { return value }
            var fields = value.map!
            fields["owner"] = .text(selectedOwnership.owner)
            fields["group"] = .text(selectedOwnership.group)
            return .object(fields)
        }
        let normalizedPolicies = try normalized.map(ItemPermissions.init)
        for bits in 0..<8 {
            let groups = Set(
                (0..<3).compactMap { bits & (1 << $0) == 0 ? nil : accounts.offset + UInt32($0) + 200 })
            for name in ["alice", "bob", "charlie", "dana"] {
                accounts.memberships[name] = groups
                let account = try accounts.user(named: name)
                let resolver = PrincipalResolver(directory: accounts, configuration: configuration)
                for rights in [4, 2, 6] {
                    let expected = try normalizedPolicies.allSatisfy {
                        try $0.allows(rights, for: account, using: resolver)
                    }
                    XCTAssertEqual(
                        try plan.allowsInEveryNormalizedComponent(rights, for: account, using: resolver),
                        expected,
                        "Exact conjunction: \(name), groups \(bits), request \(rights)", file: file,
                        line: line)
                    let actual = try result.allows(rights, for: account, using: resolver)
                    XCTAssertFalse(actual && !expected, "Result overgrant", file: file, line: line)
                    if case .exactPOSIX = plan.outcome {
                        XCTAssertEqual(actual, expected, "Claimed exact result", file: file, line: line)
                    }
                }
            }
        }
    }

    func testOrdinaryAndNamedUserExactFamiliesAcrossDynamicMemberships() throws {
        let ordinary = [permissions(mode: 0o646), permissions(mode: 0o662)]
        let plan = try PermissionConsolidation.plan(ordinary)
        guard case .exactPOSIX(let value) = plan.outcome else {
            return XCTFail("Expected exact ordinary mode")
        }
        XCTAssertEqual(try ItemPermissions(value).mode, 0o642)
        let named = [
            permissions(mode: 0o646, users: ["bob": 6], owningGroup: 6, mask: 4),
            permissions(mode: 0o660, users: ["bob": 2], owningGroup: 2),
        ]
        let namedPlan = try PermissionConsolidation.plan(named)
        guard case .exactPOSIX(let namedValue) = namedPlan.outcome else {
            return XCTFail("Expected exact ACL")
        }
        let parsed = try ItemPermissions(namedValue)
        XCTAssertEqual(parsed.mask, 6)
        XCTAssertEqual(parsed.users["bob"], 0)
        XCTAssertEqual(parsed.owningGroupPermissions, 0)
        for offset: UInt32 in [0, 10_000] {
            try assertSound(ordinary, accounts: Accounts(offset: offset))
            try assertSound(named, accounts: Accounts(offset: offset))
        }
    }

    func testConservativeFallbackNeverOvergrantsNamedPrecedenceMaskOrOther() throws {
        let cases = [
            [permissions(mode: 0o666), permissions(mode: 0o666, users: ["bob": 0], owningGroup: 6)],
            [permissions(mode: 0o666, groups: ["readers": 0], owningGroup: 6), permissions(mode: 0o664)],
            [
                permissions(mode: 0o640, groups: ["readers": 6], mask: 4),
                permissions(mode: 0o660, groups: ["writers": 6]),
            ],
            [
                permissions(mode: 0o666, users: ["bob": 4], groups: ["readers": 2], owningGroup: 6),
                permissions(mode: 0o666, users: ["charlie": 2], groups: ["writers": 4], owningGroup: 0),
            ],
        ]
        for values in cases {
            let plan = try PermissionConsolidation.plan(values)
            guard case .conservativePOSIX(let value, .unsupportedPOSIXIntersection) = plan.outcome else {
                return XCTFail("Expected explicit conservative result")
            }
            XCTAssertEqual(try ItemPermissions(value).mode, 0o600)
            try assertSound(values, accounts: Accounts())
        }
    }

    func testGroupConjunctionLossIsExplicitAndMembershipChangesRemainDynamic() throws {
        let values = [
            permissions(groups: ["readers": 4]), permissions(groups: ["writers": 4]),
        ]
        let plan = try PermissionConsolidation.plan(values)
        let result = try ItemPermissions(XCTUnwrap(plan.outcome.posixValue))
        let accounts = Accounts()
        for membership in [[UInt32](), [201], [201, 202], [202], []] {
            accounts.memberships["bob"] = Set(membership)
            let bob = try accounts.user(named: "bob")
            let resolver = PrincipalResolver(directory: accounts, configuration: nil)
            XCTAssertEqual(
                try plan.allowsInEveryNormalizedComponent(4, for: bob, using: resolver),
                membership == [201, 202])
            XCTAssertFalse(try result.allows(4, for: bob, using: resolver))
        }
        try assertSound(values, accounts: accounts)
    }

    func testIdenticalExtendedACLRetainsSplitGroupRequestSemantics() throws {
        let value = permissions(mode: 0o666, groups: ["readers": 4, "writers": 2])
        let plan = try PermissionConsolidation.plan([value, value])
        XCTAssertEqual(plan.outcome, .exactPOSIX(value))
        XCTAssertEqual(plan.components, [value])
        let accounts = Accounts()
        accounts.memberships["bob"] = [201, 202]
        let bob = try accounts.user(named: "bob")
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        XCTAssertTrue(try plan.allowsInEveryNormalizedComponent(4, for: bob, using: resolver))
        XCTAssertTrue(try plan.allowsInEveryNormalizedComponent(2, for: bob, using: resolver))
        XCTAssertFalse(try plan.allowsInEveryNormalizedComponent(6, for: bob, using: resolver))
        try assertSound([value, value], accounts: accounts)
    }

    func testAliasesRemainNamesAndLocalNumericIdentitiesAreNotPersisted() throws {
        let values = [
            permissions(users: ["nickname": 0], groups: ["crew": 4]),
            permissions(users: ["bob": 6], groups: ["readers": 4]),
        ]
        let before = try PermissionConsolidation.plan(values)
        for offset: UInt32 in [0, 10_000] {
            try assertSound(values, accounts: Accounts(offset: offset), configuration: configuration())
        }
        XCTAssertEqual(try PermissionConsolidation.plan(values).components, before.components)
        XCTAssertEqual(try PermissionConsolidation.plan(Array(values.reversed())).outcome, before.outcome)
        let ownerAliases = try PermissionConsolidation.plan([permissions(), permissions(owner: "leader")])
        XCTAssertEqual(
            ownerAliases.outcome,
            .needsOwnershipSelection(.init(owners: ["alice", "leader"], groups: ["staff"])))
        let groupAliases = try PermissionConsolidation.plan([
            permissions(group: "crew"), permissions(group: "readers"),
        ])
        XCTAssertEqual(
            groupAliases.outcome,
            .needsOwnershipSelection(.init(owners: ["alice"], groups: ["crew", "readers"])))
    }

    func testIdentityForksNeedSelectionWithoutChoosingAnOwner() throws {
        let plan = try PermissionConsolidation.plan([
            permissions(owner: "bob", group: "writers"), permissions(owner: "alice", group: "staff"),
        ])
        XCTAssertEqual(
            plan.outcome,
            .needsOwnershipSelection(.init(owners: ["alice", "bob"], groups: ["staff", "writers"])))
        XCTAssertNil(plan.outcome.posixValue)
        let groupOnly = try PermissionConsolidation.plan([permissions(), permissions(group: "readers")])
        XCTAssertEqual(
            groupOnly.outcome,
            .needsOwnershipSelection(.init(owners: ["alice"], groups: ["readers", "staff"])))
        let accounts = Accounts()
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        XCTAssertThrowsError(
            try plan.allowsInEveryNormalizedComponent(4, for: accounts.user(named: "alice"), using: resolver))
    }

    func testExplicitSelectedRolesIntersectRoleRightsWithoutInventingOwnerWrite() throws {
        let selected = PermissionConsolidation.Ownership(owner: "bob", group: "readers")
        let exactInputs = [
            permissions(owner: "alice", group: "staff", mode: 0o440),
            permissions(owner: "charlie", group: "writers", mode: 0o660),
        ]
        let exact = try PermissionConsolidation.plan(exactInputs, selectedOwnership: selected)
        let exactResult = try ItemPermissions(XCTUnwrap(exact.outcome.posixValue))
        XCTAssertEqual(exactResult.owner, "bob")
        XCTAssertEqual(exactResult.group, "readers")
        XCTAssertEqual(exactResult.mode, 0o440)
        XCTAssertEqual(exact.components.count, 2)
        let accounts = Accounts()
        let bob = try accounts.user(named: "bob")
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        XCTAssertFalse(try ItemPermissions(exactInputs[0]).allows(4, for: bob, using: resolver))
        XCTAssertFalse(try exact.allowsInEveryOriginalComponent(4, for: bob, using: resolver))
        XCTAssertTrue(try exact.allowsInEveryNormalizedComponent(4, for: bob, using: resolver))
        XCTAssertFalse(try exact.ownerCanManageUnderExistingRules(bob, using: resolver))
        XCTAssertFalse(try exactResult.allows(6, for: bob, using: resolver))
        let conservativeInputs = [
            permissions(owner: "alice", mode: 0o460, users: ["bob": 0], groups: ["readers": 6]),
            permissions(owner: "charlie", group: "writers", groups: ["writers": 4]),
        ]
        let conservative = try PermissionConsolidation.plan(conservativeInputs, selectedOwnership: selected)
        guard case .conservativePOSIX(let value, _) = conservative.outcome else {
            return XCTFail("Expected selected-role conservative result")
        }
        XCTAssertEqual(try ItemPermissions(value).mode, 0o400)
        for offset: UInt32 in [0, 10_000] {
            try assertSound(exactInputs, accounts: Accounts(offset: offset), selectedOwnership: selected)
            try assertSound(
                conservativeInputs, accounts: Accounts(offset: offset), selectedOwnership: selected)
        }
    }

    func testCombiningOriginalsRequiresExplicitSelectionAfresh() throws {
        let a = permissions(owner: "alice")
        let b = permissions(owner: "bob")
        let selected = PermissionConsolidation.Ownership(owner: "charlie", group: "staff")
        let first = try PermissionConsolidation.plan([a, b], selectedOwnership: selected)
        let combined = try PermissionConsolidation.combine([first, first], selectedOwnership: selected)
        XCTAssertEqual(combined.components, first.components)
        XCTAssertEqual(combined.outcome, first.outcome)
        let noSelection = try PermissionConsolidation.combine([first])
        XCTAssertEqual(
            noSelection.outcome, .needsOwnershipSelection(.init(owners: ["alice", "bob"], groups: ["staff"])))
    }

    func testCommonOwnerManageConditionIsRetainedWithoutInflatingRestrictedOwner() throws {
        let accounts = Accounts()
        let alice = try accounts.user(named: "alice")
        let bob = try accounts.user(named: "bob")
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        for values in [
            [permissions(), permissions(mode: 0o640)],
            [permissions(groups: ["readers": 4]), permissions(groups: ["writers": 4])],
        ] {
            let plan = try PermissionConsolidation.plan(values)
            XCTAssertTrue(try plan.ownerCanManageUnderExistingRules(alice, using: resolver))
            XCTAssertFalse(try plan.ownerCanManageUnderExistingRules(bob, using: resolver))
            XCTAssertTrue(
                try ItemPermissions(XCTUnwrap(plan.outcome.posixValue)).allows(6, for: alice, using: resolver)
            )
        }
        let restricted = try PermissionConsolidation.plan([
            permissions(mode: 0o400), permissions(mode: 0o660, groups: ["readers": 6]),
        ])
        XCTAssertFalse(try restricted.ownerCanManageUnderExistingRules(alice, using: resolver))
        XCTAssertEqual(try ItemPermissions(XCTUnwrap(restricted.outcome.posixValue)).mode, 0o400)
        try assertSound(
            [permissions(mode: 0o400), permissions(mode: 0o660, groups: ["readers": 6])], accounts: accounts)
    }

    func testOriginalComponentCombinationIsIdempotentCommutativeAndThreeWayConvergent() throws {
        let a = permissions(groups: ["readers": 4])
        let b = permissions(groups: ["writers": 4])
        let c = permissions(mode: 0o664)
        let expected = try PermissionConsolidation.plan([a, b, c])
        for permutation in [[a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            let plan = try PermissionConsolidation.plan(permutation)
            XCTAssertEqual(plan.components, expected.components)
            XCTAssertEqual(plan.outcome, expected.outcome)
        }
        let pa = try PermissionConsolidation.plan([a])
        let pb = try PermissionConsolidation.plan([b])
        let pc = try PermissionConsolidation.plan([c])
        let left = try PermissionConsolidation.combine([PermissionConsolidation.combine([pa, pb]), pc])
        let right = try PermissionConsolidation.combine([pa, PermissionConsolidation.combine([pb, pc])])
        XCTAssertEqual(left.components, right.components)
        XCTAssertEqual(left.outcome, expected.outcome)
        XCTAssertEqual(try PermissionConsolidation.combine([pa, pa]).outcome, pa.outcome)
        // Feeding only a lossy descriptor back is explicitly a different component history.
        let lossyAB = try PermissionConsolidation.combine([pa, pb])
        let folded = try PermissionConsolidation.plan([XCTUnwrap(lossyAB.outcome.posixValue), c])
        XCTAssertNotEqual(folded.components, expected.components)
        let accounts = Accounts()
        accounts.memberships["bob"] = [201, 202]
        let bob = try accounts.user(named: "bob")
        let resolver = PrincipalResolver(directory: accounts, configuration: nil)
        XCTAssertTrue(try expected.allowsInEveryNormalizedComponent(4, for: bob, using: resolver))
        XCTAssertFalse(try folded.allowsInEveryNormalizedComponent(4, for: bob, using: resolver))
    }

    func testLimitsInvalidPoliciesAndInvalidRequestFailClosed() throws {
        let value = permissions()
        XCTAssertThrowsError(
            try PermissionConsolidation.plan(
                [value], selectedOwnership: .init(owner: "invalid name", group: "staff")))
        XCTAssertThrowsError(
            try PermissionConsolidation.plan(
                [value], selectedOwnership: .init(owner: "alice", group: "invalid name")))
        for values in [[], [ItemValue.text("missing")]] {
            XCTAssertThrowsError(try PermissionConsolidation.plan(values))
        }
        var limits = PermissionConsolidation.Limits()
        limits.maximumComponents = 1
        XCTAssertThrowsError(try PermissionConsolidation.plan([value, value], limits: limits))
        let plan = try PermissionConsolidation.plan([value])
        XCTAssertThrowsError(try PermissionConsolidation.combine([plan, plan], limits: limits))
        limits.maximumEncodedBytes = 1
        XCTAssertThrowsError(try PermissionConsolidation.plan([value], limits: limits))
        let accounts = Accounts()
        XCTAssertThrowsError(
            try plan.allowsInEveryNormalizedComponent(
                0, for: accounts.user(named: "alice"),
                using: PrincipalResolver(directory: accounts, configuration: nil)))
    }

    func testCandidateValidationCannotHideUnresolvedOrAmbiguousSourceNames() throws {
        let accounts = Accounts()
        let resolver = PrincipalResolver(directory: accounts, configuration: try configuration())
        for source in [
            permissions(users: ["missing": 0]),
            permissions(users: ["bob": 0, "nickname": 4]),
            permissions(groups: ["crew": 4, "readers": 6]),
        ] {
            let plan = try PermissionConsolidation.plan([source, permissions()])
            XCTAssertThrowsError(try plan.validatedPOSIXValue(using: resolver))
            XCTAssertThrowsError(
                try plan.allowsInEveryNormalizedComponent(
                    4, for: accounts.user(named: "alice"), using: resolver))
        }
        let valid = try PermissionConsolidation.plan([permissions(users: ["nickname": 0]), permissions()])
        XCTAssertNotNil(try valid.validatedPOSIXValue(using: resolver))
    }
}
