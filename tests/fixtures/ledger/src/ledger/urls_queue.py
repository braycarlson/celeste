from django.urls import path

from ledger import queue_views


urlpatterns = (path("enqueue", queue_views.enqueue),)
