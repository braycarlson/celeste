import json
import uuid

from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_POST

from ledger.tasks import transfer_task


@csrf_exempt
@require_POST
def enqueue(request):
    body = json.loads(request.body)
    transfer_id = uuid.UUID(body["id"])

    transfer_task.delay(str(transfer_id), body["source"], body["target"], int(body["amount"]))

    return JsonResponse({"id": str(transfer_id), "status": "queued"}, status=202)
