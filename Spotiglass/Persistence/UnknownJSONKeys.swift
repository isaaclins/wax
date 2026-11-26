import Foundation

/// The keys this build reads at one level of a JSON document, and the same for the objects
/// nested under some of them.
struct JSONKeySchema {
    var known: Set<String>
    var objects: [String: JSONKeySchema] = [:]
}

/// Keeps the keys a newer build wrote when this build saves the same file (#627).
///
/// Settings and pins decode only the keys this build knows, and saving encodes only those, so a
/// setting or pin field added by a newer build (after an update was rolled back, or a second Mac
/// sharing the file) was gone for good on the next save. Before a save the previous bytes are read
/// again and every key the schema doesn't know is written back unchanged.
final class UnknownJSONKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var loggedNames: Set<String> = []

    init() {}

    /// `encoded` with every key of `previous` that `schema` doesn't know put back, and the dotted
    /// names of those keys. Returns `encoded` untouched when there is nothing to carry.
    func carry(
        from previous: Data?,
        into encoded: Data,
        schema: JSONKeySchema,
        encoder: JSONEncoder
    ) -> (data: Data, carried: [String]) {
        guard case let .object(old)? = Self.parse(previous), case let .object(new)? = Self.parse(encoded) else {
            return (encoded, [])
        }
        var carried: [String] = []
        let merged = Self.merge(old: old, into: new, schema: schema, path: "", carried: &carried)
        return finish(merged: .object(merged), encoded: encoded, carried: carried, encoder: encoder)
    }

    /// The same for a JSON array of rows: each row keeps the unknown keys of the previous row with
    /// the same `idKey` value. Names come back as `[<id>].<key>`.
    func carryRows(
        from previous: Data?,
        into encoded: Data,
        rowSchema: JSONKeySchema,
        idKey: String,
        encoder: JSONEncoder
    ) -> (data: Data, carried: [String]) {
        guard case let .array(oldRows)? = Self.parse(previous), case let .array(newRows)? = Self.parse(encoded) else {
            return (encoded, [])
        }
        var oldByID: [String: [String: JSONValue]] = [:]
        for case let .object(row) in oldRows {
            if case let .string(id)? = row[idKey], oldByID[id] == nil { oldByID[id] = row }
        }
        var carried: [String] = []
        let merged = newRows.map { row -> JSONValue in
            guard case let .object(newRow) = row, case let .string(id)? = newRow[idKey], let oldRow = oldByID[id] else {
                return row
            }
            return .object(Self.merge(old: oldRow, into: newRow, schema: rowSchema, path: "[\(id)]", carried: &carried))
        }
        return finish(merged: .array(merged), encoded: encoded, carried: carried, encoder: encoder)
    }

    /// The names in `names` not logged before by this instance, so each key is logged once.
    func namesToLog(_ names: [String]) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let fresh = names.filter { !loggedNames.contains($0) }
        loggedNames.formUnion(fresh)
        return fresh
    }

    private static func parse(_ data: Data?) -> JSONValue? {
        guard let data else { return nil }
        // try?: a previous file that isn't JSON has no keys to keep; the store keeps a copy of it (#597).
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func finish(merged: JSONValue, encoded: Data, carried: [String], encoder: JSONEncoder) -> (data: Data, carried: [String]) {
        // try?: JSON that was just decoded always encodes; if it didn't, saving what this build knows still works.
        guard !carried.isEmpty, let data = try? encoder.encode(merged) else { return (encoded, []) }
        return (data, carried)
    }

    private static func merge(
        old: [String: JSONValue],
        into new: [String: JSONValue],
        schema: JSONKeySchema,
        path: String,
        carried: inout [String]
    ) -> [String: JSONValue] {
        var result = new
        for (key, value) in old.sorted(by: { $0.key < $1.key }) {
            let name = path.isEmpty ? key : "\(path).\(key)"
            if !schema.known.contains(key) {
                guard result[key] == nil else { continue }
                result[key] = value
                carried.append(name)
            } else if let nested = schema.objects[key],
                      case let .object(oldObject) = value,
                      case let .object(newObject)? = result[key] {
                result[key] = .object(merge(old: oldObject, into: newObject, schema: nested, path: name, carried: &carried))
            }
        }
        return result
    }
}
