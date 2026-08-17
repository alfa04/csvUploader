from pathlib import Path

import pytest

from shared.constants import MAX_FILE_SIZE_BYTES, MAX_ROWS, MAX_STORED_ERRORS
from shared.validation import StructuralValidationError, validate_csv

FIXTURES_DIR = Path(__file__).parent.parent / "fixtures"


def _read_fixture(name: str) -> bytes:
    return (FIXTURES_DIR / name).read_bytes()


def test_valid_csv_all_rows_pass():
    result = validate_csv(_read_fixture("valid.csv"))
    assert result.row_count == 3
    assert result.invalid_row_count == 0
    assert len(result.valid_rows) == 3
    assert result.valid_rows[0].drug_name == "Aspirin"
    assert result.valid_rows[0].efficacy == 72.5


def test_missing_column_is_structural_error():
    with pytest.raises(StructuralValidationError, match="columns"):
        validate_csv(_read_fixture("missing_column.csv"))


def test_extra_column_is_structural_error():
    with pytest.raises(StructuralValidationError, match="columns"):
        validate_csv(_read_fixture("extra_column.csv"))


def test_header_only_is_structural_error():
    with pytest.raises(StructuralValidationError, match="no data rows"):
        validate_csv(_read_fixture("header_only.csv"))


def test_empty_file_is_structural_error():
    with pytest.raises(StructuralValidationError, match="empty"):
        validate_csv(_read_fixture("empty.csv"))


def test_messy_header_is_normalized():
    result = validate_csv(_read_fixture("messy_header.csv"))
    assert result.row_count == 1
    assert result.valid_rows[0].drug_name == "Aspirin"


def test_partial_ingest_reports_row_errors():
    result = validate_csv(_read_fixture("invalid_efficacy.csv"))
    assert result.row_count == 4
    assert len(result.valid_rows) == 1
    assert result.invalid_row_count == 3
    fields = {e.field for e in result.row_errors}
    assert "efficacy" in fields
    assert "drug_name" in fields


def test_non_utf8_is_structural_error():
    with pytest.raises(StructuralValidationError, match="UTF-8"):
        validate_csv(b"drug_name,target,efficacy\n\xff\xfe,COX-1,50\n")


def test_oversized_file_is_structural_error():
    header = b"drug_name,target,efficacy\n"
    row = b"Aspirin,COX-1,50\n"
    padding_rows_needed = (MAX_FILE_SIZE_BYTES // len(row)) + 10
    content = header + row * padding_rows_needed
    with pytest.raises(StructuralValidationError, match="size"):
        validate_csv(content)


def test_too_many_rows_is_structural_error():
    header = "drug_name,target,efficacy\n"
    rows = "".join(f"Drug{i},Target{i},50\n" for i in range(MAX_ROWS + 1))
    content = (header + rows).encode("utf-8")
    with pytest.raises(StructuralValidationError, match="rows"):
        validate_csv(content)


def test_efficacy_out_of_range_reported():
    content = b"drug_name,target,efficacy\nAspirin,COX-1,150\n"
    result = validate_csv(content)
    assert result.invalid_row_count == 1
    assert result.row_errors[0].field == "efficacy"


def test_row_errors_capped_at_max_stored():
    header = "drug_name,target,efficacy\n"
    rows = "".join(f"Drug{i},Target{i},not_a_number\n" for i in range(MAX_STORED_ERRORS + 20))
    content = (header + rows).encode("utf-8")
    result = validate_csv(content)
    assert result.invalid_row_count == MAX_STORED_ERRORS + 20
    assert len(result.row_errors) == MAX_STORED_ERRORS
