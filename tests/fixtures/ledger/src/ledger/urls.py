from django.urls import path

from ledger import views


urlpatterns = (path("transfer", views.transfer),)
