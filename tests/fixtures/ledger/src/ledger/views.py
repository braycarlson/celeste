import json
import uuid

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST

from ledger.transfers import INSUFFICIENT, transfer_apply


@csrf_exempt
@require_POST
def transfer(request):
    body = json.loads(request.body)
    transfer_id = uuid.UUID(body["id"])
    status = transfer_apply(transfer_id, body["source"], body["target"], int(body["amount"]))

    if status == INSUFFICIENT:
        return JsonResponse({"error": "insufficient"}, status=409)

    return JsonResponse({"id": str(transfer_id), "status": status})
