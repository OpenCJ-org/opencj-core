"""SQL extraction tolerates GSC layout changes without inventing unbound values."""

import unittest

from query_sql import extract_sql_expression
from query_sql import gsc_expression


class QueryExtractionTests(unittest.TestCase):
    def test_comments_and_function_layout_do_not_select_decoys(self):
        source = (
            '// query = "SELECT wrong";\n'
            'build ( ) { /* return "SELECT wrong"; */\n'
            'query\n= "SELECT " + rowCount + "; literal"; return query; }'
        )
        expression = extract_sql_expression(source, "SELECT ")
        self.assertEqual(gsc_expression(expression, {"rowCount": 3}), "SELECT 3; literal")

    def test_returned_cte_and_assignment_queries_are_distinct(self):
        source = 'query = "SELECT 1"; return "WITH finished AS (SELECT 2)";'
        self.assertEqual(
            gsc_expression(extract_sql_expression(source, "WITH finished"), {}),
            "WITH finished AS (SELECT 2)",
        )

    def test_spacing_and_identifier_case_preserve_bindings(self):
        expression = '"SELECT " + self . currentBoard [ "page" ]'
        self.assertEqual(gsc_expression(expression, {'SELF.currentBoard["page"]': 2}), "SELECT 2")

    def test_nested_expression_is_one_explicit_binding(self):
        expression = '"LIMIT " + count(1 + 2)'
        self.assertEqual(gsc_expression(expression, {"count(1 + 2)": 3}), "LIMIT 3")

    def test_plus_and_escaped_quote_inside_a_string_are_literal(self):
        expression = r'"SELECT \"a+b\"; " + runID'
        self.assertEqual(gsc_expression(expression, {"runID": 7}), 'SELECT "a+b"; 7')

    def test_result_signature_distinguishes_queries_in_the_same_file(self):
        source = 'query = "SELECT * FROM runs"; query = "SELECT COUNT(*) FROM runs";'
        expression = extract_sql_expression(source, "SELECT COUNT(")
        self.assertEqual(gsc_expression(expression, {}), "SELECT COUNT(*) FROM runs")

    def test_rewrapped_literal_terms_preserve_query_selection(self):
        source = 'query = "SELECT " + "COUNT(*) FROM runs";'
        expression = extract_sql_expression(source, "SELECT COUNT(")
        self.assertEqual(gsc_expression(expression, {}), "SELECT COUNT(*) FROM runs")

    def test_unknown_expression_is_not_silently_omitted(self):
        with self.assertRaisesRegex(ValueError, "Missing fixture binding"):
            gsc_expression('"SELECT " + unknownValue', {})

    def test_missing_or_ambiguous_query_fails_clearly(self):
        for source in ("return 1;", 'query = "SELECT 1"; query = "SELECT 2";'):
            with self.subTest(source=source):
                with self.assertRaisesRegex(ValueError, "Expected one"):
                    extract_sql_expression(source, "SELECT ")

    def test_unterminated_query_fails_clearly(self):
        with self.assertRaisesRegex(ValueError, "Unterminated"):
            extract_sql_expression('query = "SELECT 1"', "SELECT ")


if __name__ == "__main__":
    unittest.main()
