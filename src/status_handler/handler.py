from shared import repository
from shared.auth import caller_sub
from shared.http import error_response, json_response
from shared.logging_config import bind_upload_id, logger


@logger.inject_lambda_context(log_event=True)
def handler(event, context):
    upload_id = (event.get("pathParameters") or {}).get("upload_id")
    if not upload_id:
        return error_response(400, "Missing path parameter 'upload_id'.")

    bind_upload_id(upload_id)
    upload = repository.get_upload(upload_id)
    if upload is None or upload.uploaded_by != caller_sub(event):
        return error_response(404, f"Upload '{upload_id}' not found.")

    return json_response(200, upload.to_response_dict())
