from dataclasses import dataclass, field
from decimal import Decimal
from enum import StrEnum


class UploadStatus(StrEnum):
    PENDING = "pending"
    PROCESSING = "processing"
    SUCCEEDED = "succeeded"
    PARTIALLY_SUCCEEDED = "partially_succeeded"
    FAILED = "failed"


@dataclass(frozen=True)
class RowError:
    row: int
    field: str
    message: str

    def to_dict(self) -> dict:
        return {"row": self.row, "field": self.field, "message": self.message}

    @classmethod
    def from_dict(cls, data: dict) -> "RowError":
        return cls(row=int(data["row"]), field=data["field"], message=data["message"])


@dataclass
class UploadMetadata:
    upload_id: str
    status: UploadStatus
    original_filename: str
    uploaded_by: str
    s3_key: str
    created_at: str
    updated_at: str
    row_count: int = 0
    valid_row_count: int = 0
    invalid_row_count: int = 0
    errors: list[RowError] = field(default_factory=list)

    def to_item(self) -> dict:
        return {
            "upload_id": self.upload_id,
            "status": self.status.value,
            "original_filename": self.original_filename,
            "uploaded_by": self.uploaded_by,
            "s3_key": self.s3_key,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "row_count": self.row_count,
            "valid_row_count": self.valid_row_count,
            "invalid_row_count": self.invalid_row_count,
            "errors": [e.to_dict() for e in self.errors],
        }

    @classmethod
    def from_item(cls, item: dict) -> "UploadMetadata":
        return cls(
            upload_id=item["upload_id"],
            status=UploadStatus(item["status"]),
            original_filename=item["original_filename"],
            uploaded_by=item["uploaded_by"],
            s3_key=item["s3_key"],
            created_at=item["created_at"],
            updated_at=item["updated_at"],
            row_count=int(item.get("row_count", 0)),
            valid_row_count=int(item.get("valid_row_count", 0)),
            invalid_row_count=int(item.get("invalid_row_count", 0)),
            errors=[RowError.from_dict(e) for e in item.get("errors", [])],
        )

    def to_response_dict(self) -> dict:
        """JSON-serializable representation for API responses. Omits s3_key - internal detail."""
        return {
            "upload_id": self.upload_id,
            "status": self.status.value,
            "original_filename": self.original_filename,
            "uploaded_by": self.uploaded_by,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "row_count": self.row_count,
            "valid_row_count": self.valid_row_count,
            "invalid_row_count": self.invalid_row_count,
            "errors": [e.to_dict() for e in self.errors],
        }


@dataclass
class DataRecord:
    upload_id: str
    row_number: int
    drug_name: str
    target: str
    efficacy: float

    def to_item(self) -> dict:
        return {
            "upload_id": self.upload_id,
            "row_number": self.row_number,
            "drug_name": self.drug_name,
            "target": self.target,
            # DynamoDB's Number type requires Decimal via the boto3 resource API; str() avoids
            # the float -> Decimal binary rounding issues Decimal(float) would introduce.
            "efficacy": Decimal(str(self.efficacy)),
        }

    @classmethod
    def from_item(cls, item: dict) -> "DataRecord":
        return cls(
            upload_id=item["upload_id"],
            row_number=int(item["row_number"]),
            drug_name=item["drug_name"],
            target=item["target"],
            efficacy=float(item["efficacy"]),
        )

    def to_response_dict(self) -> dict:
        return {
            "row_number": self.row_number,
            "drug_name": self.drug_name,
            "target": self.target,
            "efficacy": self.efficacy,
        }
