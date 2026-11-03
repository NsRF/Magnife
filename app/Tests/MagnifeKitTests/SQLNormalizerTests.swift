import Testing
@testable import MagnifeKit

/// SQL statements to their shape (S-024, N+1). Statements that differ only
/// in their values must group; anything else must not.
@Suite("SQL normalizer")
struct SQLNormalizerTests {
    @Test("literals become ?", arguments: [
        ("SELECT * FROM order_items WHERE order_id = 1042", "SELECT * FROM order_items WHERE order_id = ?"),
        ("SELECT * FROM users WHERE name = 'Ann'", "SELECT * FROM users WHERE name = ?"),
        ("SELECT * FROM users WHERE name = 'O''Brien'", "SELECT * FROM users WHERE name = ?"),
        (#"SELECT * FROM users WHERE name = 'O\'Brien'"#, "SELECT * FROM users WHERE name = ?"),
        ("SELECT * FROM t WHERE price > 4.25", "SELECT * FROM t WHERE price > ?"),
        ("SELECT * FROM t WHERE ratio < .5", "SELECT * FROM t WHERE ratio < ?"),
        ("SELECT * FROM t WHERE x = 1e-5", "SELECT * FROM t WHERE x = ?"),
        ("SELECT * FROM t WHERE flags = 0x1F", "SELECT * FROM t WHERE flags = ?"),
        ("SELECT * FROM t WHERE delta = -5", "SELECT * FROM t WHERE delta = ?"),
        ("SELECT * FROM t WHERE name = N'Zoë'", "SELECT * FROM t WHERE name = ?"),
        ("SELECT * FROM t WHERE path = E'a\\nb'", "SELECT * FROM t WHERE path = ?"),
        ("SELECT $$it's a body$$ AS b", "SELECT ? AS b"),
        ("SELECT $fn$body$fn$ AS b", "SELECT ? AS b"),
        ("SELECT * FROM t LIMIT 10 OFFSET 20", "SELECT * FROM t LIMIT ? OFFSET ?"),
        ("UPDATE t SET n = n - 1 WHERE id = 7", "UPDATE t SET n = n - ? WHERE id = ?"),
    ])
    func literals(_ statement: String, _ shape: String) {
        #expect(SQLNormalizer.normalize(statement) == shape)
    }

    @Test("IN lists and VALUES tuples collapse", arguments: [
        ("SELECT * FROM t WHERE id IN (1, 2, 3)", "SELECT * FROM t WHERE id IN (?)"),
        ("SELECT * FROM t WHERE id IN (4)", "SELECT * FROM t WHERE id IN (?)"),
        ("SELECT * FROM t WHERE id in ('a','b')", "SELECT * FROM t WHERE id in (?)"),
        ("SELECT * FROM t WHERE id IN ($1, $2, $3)", "SELECT * FROM t WHERE id IN (?)"),
        ("SELECT * FROM t WHERE id IN (?, ?)", "SELECT * FROM t WHERE id IN (?)"),
        ("INSERT INTO t (a, b) VALUES (1, 'x'), (2, 'y'), (3, 'z')", "INSERT INTO t (a, b) VALUES (?, ?)"),
        ("INSERT INTO t (a, b) VALUES ($1, $2), ($3, $4)", "INSERT INTO t (a, b) VALUES ($1, $2)"),
        ("SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE k = 3)", "SELECT * FROM t WHERE id IN (SELECT id FROM u WHERE k = ?)"),
    ])
    func lists(_ statement: String, _ shape: String) {
        #expect(SQLNormalizer.normalize(statement) == shape)
    }

    @Test("comments and white space")
    func comments() {
        #expect(SQLNormalizer.normalize("SELECT *\n  FROM t\t WHERE id = 1  ") == "SELECT * FROM t WHERE id = ?")
        #expect(SQLNormalizer.normalize("SELECT * FROM t /*traceparent='00-4bf9-01'*/") == "SELECT * FROM t")
        #expect(SQLNormalizer.normalize("SELECT 1 -- why\nFROM t") == "SELECT ? FROM t")
        #expect(SQLNormalizer.normalize("") == "")
        #expect(SQLNormalizer.normalize("/* only a comment */") == "")
    }

    @Test("statements that differ only in values group",
          arguments: [
              ("SELECT * FROM order_items WHERE order_id = 1042", "SELECT * FROM order_items WHERE order_id = 1049"),
              ("SELECT * FROM t WHERE id IN (1, 2)", "SELECT * FROM t WHERE id IN (3, 4, 5, 6)"),
              ("SELECT * FROM t WHERE a = 'x' AND b = 2", "SELECT * FROM t WHERE a = 'a much longer value' AND b = 99999"),
              ("SELECT * FROM t /* req 1 */ WHERE id = 1", "SELECT * FROM t /* req 2 */ WHERE id = 2"),
              ("INSERT INTO t VALUES (1, 2)", "INSERT INTO t VALUES (3, 4), (5, 6)"),
              ("SELECT * FROM t WHERE d = -1", "SELECT * FROM t WHERE d = 12"),
          ])
    func groups(_ a: String, _ b: String) {
        #expect(SQLNormalizer.normalize(a) == SQLNormalizer.normalize(b))
    }

    /// 20+ negative rows: identifiers, placeholders and keywords are not
    /// values, so these never group.
    @Test("statements with a different shape never group", arguments: [
        ("SELECT * FROM orders WHERE id = 1", "SELECT * FROM order_items WHERE id = 1"),
        ("SELECT * FROM t1 WHERE id = 1", "SELECT * FROM t2 WHERE id = 1"),
        ("SELECT col_1 FROM t", "SELECT col_2 FROM t"),
        (#"SELECT "Id1" FROM t"#, #"SELECT "Id2" FROM t"#),
        ("SELECT `a1` FROM t", "SELECT `a2` FROM t"),
        ("SELECT * FROM t WHERE id = $1", "SELECT * FROM t WHERE id = $2"),
        ("SELECT * FROM t WHERE id = @p0", "SELECT * FROM t WHERE id = @p1"),
        ("SELECT * FROM t WHERE id = :id", "SELECT * FROM t WHERE id = :key"),
        ("SELECT * FROM t WHERE a = 1", "SELECT * FROM t WHERE b = 1"),
        ("SELECT * FROM t WHERE a = 1", "SELECT * FROM t WHERE a > 1"),
        ("SELECT * FROM t WHERE a = 1", "DELETE FROM t WHERE a = 1"),
        ("SELECT a FROM t", "SELECT a, b FROM t"),
        ("SELECT * FROM t WHERE a = 1 AND b = 2", "SELECT * FROM t WHERE a = 1 OR b = 2"),
        ("SELECT * FROM t WHERE a IN (1, 2)", "SELECT * FROM t WHERE a NOT IN (1, 2)"),
        ("SELECT * FROM t ORDER BY a", "SELECT * FROM t ORDER BY b"),
        ("SELECT * FROM t LIMIT 1", "SELECT * FROM t"),
        ("SELECT * FROM shop.orders", "SELECT * FROM archive.orders"),
        ("SELECT * FROM t WHERE x = TRUE", "SELECT * FROM t WHERE x = FALSE"),
        ("SELECT * FROM t WHERE x IS NULL", "SELECT * FROM t WHERE x IS NOT NULL"),
        ("SELECT * FROM v2_orders", "SELECT * FROM v3_orders"),
        ("SELECT a::int FROM t", "SELECT a::text FROM t"),
        ("SELECT * FROM t WHERE id = 1", "SELECT * FROM t WHERE id = '1' AND deleted = 0 OR x = 1"),
        ("INSERT INTO t (a) VALUES (1)", "INSERT INTO t (b) VALUES (1)"),
        ("SELECT * FROM #temp1", "SELECT * FROM #temp2"),
    ])
    func differs(_ a: String, _ b: String) {
        #expect(SQLNormalizer.normalize(a) != SQLNormalizer.normalize(b), "\(SQLNormalizer.normalize(a))")
    }

    @Test("a statement over 10,000 bytes is normalized from its start")
    func long() {
        let statement = "SELECT * FROM t WHERE id IN (" + (1...5_000).map(String.init).joined(separator: ", ") + ")"
        let shape = SQLNormalizer.normalize(statement)
        #expect(shape.hasSuffix(" …") && shape.utf8.count < 10_100)
        #expect(SQLNormalizer.normalize(statement + " AND x = 2") == shape)
    }

    @Test("an IN list cut at 10,000 bytes reads (? …, so long lists of any id width group",
          arguments: [1_000, 10_000])
    func longListsGroup(firstID: Int) {
        let statement = "SELECT id FROM t WHERE id IN ("
            + (firstID..<(firstID + 3_000)).map(String.init).joined(separator: ", ") + ")"
        #expect(statement.utf8.count > SQLNormalizer.maxBytes)
        #expect(SQLNormalizer.normalize(statement) == "SELECT id FROM t WHERE id IN (? …")
    }

    @Test("a cut that ends on a comma or inside a value still collapses the list; other cut statements keep their tokens")
    func cutEdges() {
        let head = "SELECT id FROM t WHERE id IN ("
        let values = String(repeating: "12345, ", count: 3_000)
        for extra in 0..<7 {
            // Shifts the cut through "12345, ": after a digit, the comma, the space.
            let statement = String(repeating: " ", count: extra) + head + values
            #expect(SQLNormalizer.normalize(statement) == "SELECT id FROM t WHERE id IN (? …", "\(extra)")
        }
        // Not a list of values: nothing collapses.
        let columns = head + String(repeating: "a, ", count: 4_000)
        #expect(SQLNormalizer.normalize(columns).hasPrefix(head + "a, a, a"))
        // A list that closes before the cut collapses as before.
        let closed = "SELECT * FROM t WHERE id IN (1, 2) AND note = '" + String(repeating: "x", count: 11_000) + "'"
        #expect(SQLNormalizer.normalize(closed) == "SELECT * FROM t WHERE id IN (?) AND note = ? …")
    }

    @Test("only a VALUES list or a list of tuples drops its further tuples", arguments: [
        ("SELECT f(1), (2)", "SELECT f(?), (?)"),
        ("SELECT (1), (2) FROM t", "SELECT (?), (?) FROM t"),
        ("SELECT * FROM t WHERE (a, b) IN ((1, 2), (3, 4))", "SELECT * FROM t WHERE (a, b) IN ((?, ?))"),
        ("INSERT INTO t VALUES ($1, $2), ($3, $4)", "INSERT INTO t VALUES ($1, $2)"),
        ("insert into t values (1),(2),(3)", "insert into t values (?)"),
    ])
    func tuples(_ statement: String, _ shape: String) {
        #expect(SQLNormalizer.normalize(statement) == shape)
    }

    @Test("the edge set's prices statements, IN lists of 1 to 5 with a sqlcommenter comment each, are one shape")
    func pricesGroup() {
        let skus = (1...5).map { n in (1...n).map { "'SKU-\($0)'" }.joined(separator: ", ") }
        let shapes = Set(skus.enumerated().map { index, list in
            SQLNormalizer.normalize("/*traceparent='00-8cb5882e0d71db79007aea27436f3254-000000000000000\(index + 1)-01'*/ "
                                    + "SELECT sku, price_cents FROM prices WHERE sku IN (\(list))")
        })
        #expect(shapes == ["SELECT sku, price_cents FROM prices WHERE sku IN (?)"])
    }

    @Test("an unclosed string, quote or comment never runs past the end")
    func unclosed() {
        #expect(SQLNormalizer.normalize("SELECT 'abc") == "SELECT ?")
        #expect(SQLNormalizer.normalize(#"SELECT "abc"#) == #"SELECT "abc"#)
        #expect(SQLNormalizer.normalize("SELECT 1 /* open") == "SELECT ?")
        #expect(SQLNormalizer.normalize("SELECT $tag$ open") == "SELECT $tag$ open")
    }
}
