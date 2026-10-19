import Foundation

/// Exact receiver-side observations. None of these outcomes grants sender authority.
enum PeerNeedsTransfer {
    enum State: String { case knownComplete, missingOrIncomplete, deferred, repairRequired }
    struct Result {
        let descriptor: PeerPackage.Object
        let state: State
        let disposition: AuthorityStore.Disposition?
    }
    struct Page {
        let objects: [Result]
        let nextOffset: Int
        let complete: Bool
    }
    struct Limits {
        var maximumReadBytes: UInt64 = 32 * 1024 * 1024
    }
    static func compare(
        _ objects: [PeerPackage.Object], coordinator: PeerIntakeCoordinator,
        index: ItemIndex, after: Int = 0, limits: Limits = .init(), progress: @escaping () throws -> Void
    ) throws -> Page {
        guard objects.count <= 128, after >= 0, after <= objects.count,
            Set(objects.map(\.id)).count == objects.count,
            objects.allSatisfy({ $0.kind == .item || $0.kind == .authority })
        else {
            throw TractandaError("resourceLimit", "Compare at most128 distinct metadata descriptors.")
        }
        guard limits.maximumReadBytes > 0, limits.maximumReadBytes <= 32 * 1024 * 1024 else {
            throw TractandaError("resourceLimit", "Invalid descriptor comparison read window.")
        }
        let proof = PeerInventory.BootstrapProof()
        var work = 0
        let owningReadBudget = coordinator.admissionReadBudget()
        func check() throws {
            try progress()
            try index.checkCatalogueScanProgress()
            guard work < 4096 else {
                throw TractandaError("resourceLimit", "Descriptor proof work exhausted.")
            }
            work += 1
        }
        func charge(_ count: Int) throws {
            try check()
            try owningReadBudget(count)
        }
        func bytes(_ row: AuthorityStore.RetainedObject) throws -> Data {
            try check()
            // bytes() charges the same owning counter before reading; do not charge twice.
            return try coordinator.bytes(row)
        }
        func inspect(_ descriptor: PeerPackage.Object) throws -> Result {
            try check()
            try descriptor.validate()
            try coordinator.requireStorageIdentity(descriptor, index: index)
            guard let row = try index.retainedAuthorityObject(id: descriptor.id) else {
                return Result(descriptor: descriptor, state: .missingOrIncomplete, disposition: nil)
            }
            guard row.descriptor == descriptor else {
                throw TractandaError("peerObjectCollision", "Receiver metadata descriptor differs.")
            }
            let disposition = try index.authorityDisposition(id: descriptor.id)?.disposition
            let raw: Data
            do { raw = try bytes(row) } catch let error as TractandaError where error.osError != nil {
                return Result(descriptor: descriptor, state: .repairRequired, disposition: disposition)
            }
            let node = descriptor.kind == .item ? try AuthorityRevision(originalBytes: raw) : nil
            let origin =
                try node?.revision.provenance?.originReplicaID
                ?? (descriptor.kind == .authority
                    ? AuthorityRecordCodec.decode(raw).record.originReplicaID : nil)
            var permitted = false
            var cursor: String?
            var hadAdmittedReceipt = row.permittedOrigin
            if let origin {
                while !permitted {
                    try check()
                    let page = try index.authorityObjectReceiptPage(
                        objectID: descriptor.id,
                        afterPackageID: cursor, limit: 32)
                    if page.isEmpty { break }
                    for receipt in page {
                        try check()
                        cursor = receipt.packageID
                        hadAdmittedReceipt = hadAdmittedReceipt || receipt.permittedOrigin
                        guard receipt.descriptor == descriptor else {
                            throw TractandaError(
                                "peerObjectCollision", "Receiver receipt descriptor differs.")
                        }
                        do {
                            if try coordinator.receiptContextPermits(
                                receipt, origin: origin,
                                index: index, readBudget: charge)
                            {
                                permitted = true
                                break
                            }
                        } catch let error as TractandaError
                            where !["resourceLimit", "cancelled", "deadlineExceeded", "peerObjectCollision"]
                            .contains(error.code)
                        {
                            // Lost or corrupt admitted proof is not an invitation to create another seal.
                            return Result(
                                descriptor: descriptor, state: .repairRequired, disposition: disposition)
                        }
                    }
                }
            }
            if !permitted, let node {
                do {
                    if try node.revision.provenance == nil {
                        permitted = try PeerInventory.canonicalLegacyProof(
                            node, coordinator: coordinator,
                            index: index, proof: proof, read: bytes, charge: charge)
                    } else {
                        permitted =
                            try PeerInventory.canonicalInitialPin(
                                node, coordinator: coordinator,
                                index: index, proof: proof, read: bytes, charge: charge) != nil
                            && PeerInventory.initialLocalReceipt(
                                row, node: node, coordinator: coordinator, charge: charge)
                    }
                } catch let error as TractandaError
                    where !["resourceLimit", "cancelled", "deadlineExceeded", "peerObjectCollision"].contains(
                        error.code)
                {
                    return Result(descriptor: descriptor, state: .repairRequired, disposition: disposition)
                }
            }
            guard permitted else {
                return Result(
                    descriptor: descriptor,
                    state: hadAdmittedReceipt ? .repairRequired : .missingOrIncomplete,
                    disposition: disposition)
            }
            if let node {
                do {
                    for attachment in try AttachmentDescriptor.descriptors(in: node.revision.fields) {
                        try check()
                        guard
                            try coordinator.journal.originals?.payloads.resolvedPayloadPath(
                                attachment.attachmentID) != nil
                        else {
                            return Result(
                                descriptor: descriptor, state: .missingOrIncomplete, disposition: disposition)
                        }
                        if try !coordinator.verifiedCanonicalOriginal(attachment) {
                            return Result(descriptor: descriptor, state: .deferred, disposition: disposition)
                        }
                    }
                    for document in try AttachmentDocumentRepresentation.representations(
                        in: node.revision.fields)
                    {
                        try check()
                        if let content = document.content,
                            try coordinator.documentVerification?.contents.peerDirectory(content.contentID)
                                == nil
                        {
                            return Result(
                                descriptor: descriptor, state: .missingOrIncomplete, disposition: disposition)
                        }
                        if try !coordinator.verifiedCanonicalDocument(document, index: index) {
                            return Result(descriptor: descriptor, state: .deferred, disposition: disposition)
                        }
                    }
                } catch let error as TractandaError
                    where ["resourceLimit", "peerPayloadVerifying"].contains(error.code)
                {
                    return Result(descriptor: descriptor, state: .deferred, disposition: disposition)
                }
            }
            return Result(descriptor: descriptor, state: .knownComplete, disposition: disposition)
        }
        return try coordinator.withOperation(maximumReadBytes: limits.maximumReadBytes) {
            var results: [Result] = []
            var next = after
            while next < objects.count {
                do {
                    results.append(try inspect(objects[next]))
                    next += 1
                } catch let error as TractandaError
                    where ["resourceLimit", "peerPayloadVerifying", "peerVerificationBusy"].contains(
                        error.code)
                {
                    if results.isEmpty {
                        results.append(
                            .init(
                                descriptor: objects[next], state: .deferred,
                                disposition: try index.authorityDisposition(id: objects[next].id)?.disposition
                            ))
                        next += 1
                    }
                    break
                }
            }
            return Page(objects: results, nextOffset: next, complete: next == objects.count)
        }
    }
}
