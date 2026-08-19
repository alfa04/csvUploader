def caller_sub(event: dict) -> str:
    """The authenticated caller's Cognito user id, as surfaced by API Gateway's
    COGNITO_USER_POOLS authorizer. Always present on an authenticated request - API Gateway
    rejects the request before Lambda runs otherwise, so no defensive handling here.
    """
    return event["requestContext"]["authorizer"]["claims"]["sub"]
