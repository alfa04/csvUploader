from aws_lambda_powertools import Logger

logger = Logger(service="csv-uploader")


def bind_upload_id(upload_id: str) -> None:
    """Thread upload_id through every subsequent log line as a correlation id."""
    logger.append_keys(upload_id=upload_id)
