import csv
import io
from dataclasses import dataclass

from shared.constants import (
    EFFICACY_MAX,
    EFFICACY_MIN,
    MAX_FIELD_LENGTH,
    MAX_FILE_SIZE_BYTES,
    MAX_ROWS,
    MAX_STORED_ERRORS,
    REQUIRED_COLUMNS,
)
from shared.models import RowError


class StructuralValidationError(Exception):
    """The CSV fails whole-file validation - nothing gets stored, the whole upload fails."""


@dataclass
class ValidRow:
    row_number: int
    drug_name: str
    target: str
    efficacy: float


@dataclass
class CsvValidationResult:
    valid_rows: list[ValidRow]
    row_errors: list[RowError]  # capped at MAX_STORED_ERRORS for storage/display
    row_count: int
    invalid_row_count: int  # true count, may exceed len(row_errors) if capped


def _normalize_header(name: str) -> str:
    return name.strip().lower().replace(" ", "_")


def validate_csv(content: bytes) -> CsvValidationResult:
    if len(content) == 0:
        raise StructuralValidationError("File is empty.")
    if len(content) > MAX_FILE_SIZE_BYTES:
        raise StructuralValidationError(
            f"File exceeds the maximum size of {MAX_FILE_SIZE_BYTES} bytes."
        )

    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise StructuralValidationError(f"File is not valid UTF-8: {exc}") from None

    reader = csv.reader(io.StringIO(text))
    try:
        header = next(reader)
    except StopIteration:
        raise StructuralValidationError("File has no header row.") from None

    normalized_header = tuple(_normalize_header(h) for h in header)
    if normalized_header != REQUIRED_COLUMNS:
        raise StructuralValidationError(
            f"Header must contain exactly the columns {REQUIRED_COLUMNS} "
            f"(case/whitespace-insensitive), got {normalized_header}."
        )

    valid_rows: list[ValidRow] = []
    row_errors: list[RowError] = []
    row_count = 0
    invalid_row_count = 0

    for row_number, raw_row in enumerate(reader, start=1):
        row_count += 1
        if row_count > MAX_ROWS:
            raise StructuralValidationError(f"File exceeds the maximum of {MAX_ROWS} rows.")

        if len(raw_row) != len(REQUIRED_COLUMNS):
            row_errors.append(
                RowError(row=row_number, field="*", message="Row has the wrong number of columns.")
            )
            invalid_row_count += 1
            continue

        row = dict(zip(REQUIRED_COLUMNS, raw_row, strict=True))
        errors = _validate_row(row_number, row)
        if errors:
            row_errors.extend(errors)
            invalid_row_count += 1
            continue

        valid_rows.append(
            ValidRow(
                row_number=row_number,
                drug_name=row["drug_name"].strip(),
                target=row["target"].strip(),
                efficacy=float(row["efficacy"].strip()),
            )
        )

    if row_count == 0:
        raise StructuralValidationError("File has no data rows.")

    return CsvValidationResult(
        valid_rows=valid_rows,
        row_errors=row_errors[:MAX_STORED_ERRORS],
        row_count=row_count,
        invalid_row_count=invalid_row_count,
    )


def _validate_row(row_number: int, row: dict[str, str]) -> list[RowError]:
    errors: list[RowError] = []

    for field_name in ("drug_name", "target"):
        value = row[field_name].strip()
        if not value:
            errors.append(RowError(row=row_number, field=field_name, message="Value is required."))
        elif len(value) > MAX_FIELD_LENGTH:
            errors.append(
                RowError(
                    row=row_number,
                    field=field_name,
                    message=f"Value exceeds the maximum length of {MAX_FIELD_LENGTH} characters.",
                )
            )

    efficacy_raw = row["efficacy"].strip()
    if not efficacy_raw:
        errors.append(RowError(row=row_number, field="efficacy", message="Value is required."))
    else:
        try:
            efficacy = float(efficacy_raw)
        except ValueError:
            errors.append(
                RowError(row=row_number, field="efficacy", message="Value must be numeric.")
            )
        else:
            if not (EFFICACY_MIN <= efficacy <= EFFICACY_MAX):
                errors.append(
                    RowError(
                        row=row_number,
                        field="efficacy",
                        message=f"Value must be between {EFFICACY_MIN} and {EFFICACY_MAX}.",
                    )
                )

    return errors
