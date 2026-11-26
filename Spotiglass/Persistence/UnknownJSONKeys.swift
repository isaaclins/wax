import Foundation

/// The keys this build reads at one level of a JSON document, and the same for the objects
/// and arrays of rows nested under some of them.
struct JSONKeySchema {
    var known: Set<String>
    var objects: [String: JSONKeySchema] = [:]
    var rows: [String: JSONRowSchema] = [:]
}

/// The keys of each row in a JSON array. Rows with the same `idKey` value keep the unknown keys
/// of the previous row; without an `idKey` a row has no identity, so its unknown keys can't be put
/// back and are reported as dropped instead.
struct JSONRowSchema {
    var row: JSONKeySchema
    var idKey: String?
}

/// What a save keeps of the previous file: the bytes to write and the dotted names of the keys
/// that were written back (`carried`) or could not be (`dropped`).
struct UnknownJSONKeysResult {
    var data: Data
    var carried: [String] = []
    var dropped: [String] = []
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

    /// `encoded` with every key of `previous` that `schema` doesn't know put back. Returns
    /// `encoded` untouched when there is nothing to carry.
    func carry(
        from previous: Data?,
        into encoded: Data,
        schema: JSONKeySchema,
        encoder: JSONEncoder
    ) -> UnknownJSONKeysResult {
        guard case let .object(old)? = Self.parse(previous), case let .object(new)? = Self.parse(encoded) else {
            return UnknownJSONKeysResult(data: encoded)
        }
        var result = UnknownJSONKeysResult(data: encoded)
        let merged = Self.merge(old: old, into: new, schema: schema, path: "", result: &result)
        return finish(merged: .object(merged), result: result, encoder: encoder)
    }

    /// The same for a JSON array of rows: each row keeps the unknown keys of the previous row with
    /// the same `idKey` value. Names come back as `[<id>].<key>`.
    func carryRows(
        from previous: Data?,
        into encoded: Data,
        rowSchema: JSONKeySchema,
        idKey: String,
        encoder: JSONEncoder
    ) -> UnknownJSONKeysResult {
        guard case let .array(oldRows)? = Self.parse(previous), case let .array(newRows)? = Self.parse(encoded) else {
            return UnknownJSONKeysResult(data: encoded)
        }
        var result = UnknownJSONKeysResult(data: encoded)
        let merged = Self.mergeRows(
            old: oldRows, into: newRows, schema: JSONRowSchema(row: rowSchema, idKey: idKey), path: "", result: &result
        )
        return finish(merged: .array(merged), result: result, encoder: encoder)
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

    private func finish(merged: JSONValue, result: UnknownJSONKeysResult, encoder: JSONEncoder) -> UnknownJSONKeysResult {
        guard !result.carried.isEmpty else { return result }
        // try?: JSON that was just decoded always encodes; if it didn't, saving what this build knows still works.
        guard let data = try? encoder.encode(merged) else {
            return UnknownJSONKeysResult(data: result.data, dropped: result.dropped + result.carried)
        }
        return UnknownJSONKeysResult(data: data, carried: result.carried, dropped: result.dropped)
    }

    private static func merge(
        old: [String: JSONValue],
        into new: [String: JSONValue],
        schema: JSONKeySchema,
        path: String,
        result: inout UnknownJSONKeysResult
    ) -> [String: JSONValue] {
        var merged = new
        for (key, value) in old.sorted(by: { $0.key < $1.key }) {
            let name = path.isEmpty ? key : "\(path).\(key)"
            if !schema.known.contains(key) {
                guard merged[key] == nil else { continue }
                merged[key] = value
                result.carried.append(name)
            } else if let nested = schema.objects[key],
                      case let .object(oldObject) = value,
                      case let .object(newObject)? = merged[key] {
                merged[key] = .object(merge(old: oldObject, into: newObject, schema: nested, path: name, result: &result))
            } else if let rows = schema.rows[key],
                      case let .array(oldRows) = value,
                      case let .array(newRows)? = merged[key] {
                merged[key] = .array(mergeRows(old: oldRows, into: newRows, schema: rows, path: name, result: &result))
            }
        }
        return merged
    }

    private static func mergeRows(
        old: [JSONValue],
        into new: [JSONValue],
        schema: JSONRowSchema,
        path: String,
        result: inout UnknownJSONKeysResult
    ) -> [JSONValue] {
        guard let idKey = schema.idKey else {
            // No identity to match a row by: name the keys that can't be put back.
            var names: Set<String> = []
            for case let .object(row) in old {
                for key in row.keys where !schema.row.known.contains(key) { names.insert("\(path)[].\(key)") }
            }
            result.dropped.append(contentsOf: names.sorted())
            return new
        }
        var oldByID: [String: [String: JSONValue]] = [:]
        for case let .object(row) in old {
            if case let .string(id)? = row[idKey], oldByID[id] == nil { oldByID[id] = row }
        }
        return new.map { row -> JSONValue in
            guard case let .object(newRow) = row, case let .string(id)? = newRow[idKey], let oldRow = oldByID[id] else {
                return row
            }
            return .object(merge(old: oldRow, into: newRow, schema: schema.row, path: "\(path)[\(id)]", result: &result))
        }
    }
}
